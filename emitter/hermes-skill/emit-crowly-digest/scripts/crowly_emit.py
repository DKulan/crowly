#!/usr/bin/env python3
"""crowly_emit.py — Crowly emitter helper (stdlib only, no dependencies).

Crowly is a reader: a cron/agent writes the *content* of a digest, this helper
guarantees the *envelope* and POSTs it to the user's companion service. The
LLM is good at prose and bad at stable ids / timestamps / required-field
discipline, so the split is deliberate:

    LLM fills        -> title, bottom_line, summary, sections, sources, urgency
    helper guarantees -> schema_version, id, created_at, validation, transport

Contract source of truth: ../docs/schema.md (payload) and
../docs/emitter.md (the POST /ingest wire contract). The required-field set
here mirrors the app's decoder in Shared/Models/Schema.swift exactly — if the
app can't decode it, this helper rejects it before it ever leaves the box.

Usage
-----
As a CLI, reading a "content" JSON object from --content-file (or stdin):

    python3 crowly_emit.py --content-file digest.json --dry-run

    python3 crowly_emit.py --content-file digest.json \
        --url https://inbox.example.com

The companion URL comes from --url or CROWLY_COMPANION_URL. The token comes
from the CROWLY_TOKEN env var ONLY — there is deliberately no --token flag,
so the secret never appears on an argv (visible in `ps`/shell history).

As a library (the Hermes skill imports this):

    from crowly_emit import build_digest, validate, post_digest
    digest = build_digest(content)         # stamps envelope, validates
    post_digest(digest, url, token)        # POSTs, raises EmitError on 4xx/5xx

Exit codes: 0 ok, 2 validation error (bad content), 3 transport error
(network / non-2xx from companion). These let a cron distinguish "I built a
bad payload" (fix the prompt) from "the companion rejected/was unreachable".
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request

# The schema version this emitter speaks. Additive-only: bump only when the
# payload gains fields, never when one is removed/repurposed (docs/schema.md).
# v2 adds the optional top-level `content` field — an ordered array of typed
# blocks (paragraph/heading/list/callout/metrics/divider). v1 remains valid:
# `summary`/`sections` are still accepted as the fallback for simple digests,
# and unknown *block* types are passed through unchanged (forward-compat, so a
# future v3 block survives a round-trip through this v2 emitter/companion).
SCHEMA_VERSION = 2

# Default source string when the caller doesn't set one. Informational only;
# not used for routing (docs/schema.md field notes).
DEFAULT_SOURCE = "hermes-cron"

VALID_URGENCY = ("low", "normal", "high", "urgent")

# Fields the app's decoder *requires* (Shared/Models/Schema.swift). `source`
# and `schema_version`/`id`/`created_at` are required by the app too but are
# stamped by the helper, so they're not part of the caller-supplied set.
REQUIRED_FROM_CALLER = ("job_id", "title", "bottom_line", "urgency")

# Everything the v1 payload knows about. Anything else the caller passes is
# preserved verbatim (additive-only / unknown-field passthrough) rather than
# dropped — a v2 field survives a round-trip through this v1 emitter.
KNOWN_KEYS = {
    "schema_version", "id", "job_id", "source", "title", "created_at",
    "urgency", "bottom_line", "summary", "sections", "sources", "content",
}

# Block `type` discriminators this emitter knows how to shape-check. A block
# whose type is NOT in here is accepted and passed through unchanged (only
# required to be a JSON object) — a future v3 block type must survive a
# round-trip through this v2 emitter/companion (docs/schema.md forward-compat).
KNOWN_BLOCK_TYPES = frozenset(
    {"paragraph", "heading", "list", "callout", "metrics", "divider"}
)
VALID_LIST_STYLES = ("bullet", "ordered")
VALID_CALLOUT_VARIANTS = ("info", "warning", "success", "critical")


class EmitError(Exception):
    """Validation or transport failure. `kind` is 'validation' or 'transport'."""

    def __init__(self, message: str, kind: str = "validation"):
        super().__init__(message)
        self.kind = kind


# --------------------------------------------------------------------------
# Envelope building
# --------------------------------------------------------------------------

def _slugify(text: str) -> str:
    """job_id -> a short stable slug for the id. Lowercase, dashes, trimmed."""
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug[:40] or "digest"


def _now() -> _dt.datetime:
    """Current aware UTC time. Isolated so tests can monkeypatch it."""
    return _dt.datetime.now(_dt.timezone.utc)


def make_id(job_id: str, created_at: _dt.datetime, content: dict) -> str:
    """Build a stable, unique digest id: dgst_<date>_<job-slug>_<hash>.

    The id is the companion's idempotency key (re-POSTing the same id updates,
    not duplicates — docs/schema.md). We want it stable for "the same digest"
    but distinct across runs of the same job, so we mix the date, the job
    slug, and a short content hash. A job that emits twice in a day with
    different content gets two ids; an exact re-emit (retry) collapses to one.
    """
    date = created_at.astimezone(_dt.timezone.utc).strftime("%Y-%m-%d")
    digest_material = json.dumps(content, sort_keys=True, ensure_ascii=False)
    short = hashlib.sha256(digest_material.encode("utf-8")).hexdigest()[:8]
    return f"dgst_{date}_{_slugify(job_id)}_{short}"


def build_digest(content: dict, *, source: str | None = None) -> dict:
    """Take caller content, stamp the envelope, validate, return the payload.

    The caller supplies content fields (job_id, title, bottom_line, urgency,
    and optionally summary/sections/sources + any extras). This stamps
    schema_version, created_at, and a stable id — fields the LLM must NOT
    invent — then validates the whole thing.

    Raises EmitError(kind='validation') on bad/missing fields.
    """
    if not isinstance(content, dict):
        raise EmitError("content must be a JSON object")

    digest = dict(content)  # don't mutate the caller's dict

    # Envelope: helper-owned. We overwrite id/created_at/schema_version even if
    # the caller (or LLM) tried to set them — those are not the model's job.
    created = _now()
    digest["schema_version"] = SCHEMA_VERSION
    digest["source"] = source or content.get("source") or DEFAULT_SOURCE
    digest["created_at"] = _iso(created)
    # id derives from the *content* (sans envelope) so retries are idempotent.
    content_only = {k: v for k, v in content.items() if k not in
                    ("id", "schema_version", "created_at")}
    digest["id"] = content.get("id") or make_id(
        str(content.get("job_id", "")), created, content_only
    )

    validate(digest)
    return digest


def _iso(dt: _dt.datetime) -> str:
    """ISO-8601 with offset, matching CrowlyISO8601 in the app (e.g.
    2026-06-29T19:00:00+00:00). The app parses both Z and numeric offsets."""
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=_dt.timezone.utc)
    return dt.isoformat(timespec="seconds")


# --------------------------------------------------------------------------
# Validation — mirrors the app's decoder so a digest that passes here decodes
# cleanly there.
# --------------------------------------------------------------------------

def validate(digest: dict) -> None:
    """Raise EmitError(kind='validation') if `digest` wouldn't decode in-app."""
    errs: list[str] = []

    for key in REQUIRED_FROM_CALLER:
        val = digest.get(key)
        if val is None or (isinstance(val, str) and not val.strip()):
            errs.append(f"missing or empty required field: {key!r}")

    sv = digest.get("schema_version")
    if not isinstance(sv, int) or isinstance(sv, bool):
        errs.append("schema_version must be an integer")

    urg = digest.get("urgency")
    if urg is not None and urg not in VALID_URGENCY:
        errs.append(
            f"urgency must be one of {VALID_URGENCY}, got {urg!r}"
        )

    created = digest.get("created_at")
    if not isinstance(created, str) or not _parse_iso(created):
        errs.append(f"created_at must be an ISO-8601 timestamp, got {created!r}")

    # sections: optional, but if present must be [{heading, body}].
    sections = digest.get("sections")
    if sections is not None:
        if not isinstance(sections, list):
            errs.append("sections must be an array")
        else:
            for i, sec in enumerate(sections):
                if not isinstance(sec, dict) or "heading" not in sec or "body" not in sec:
                    errs.append(f"sections[{i}] must have 'heading' and 'body'")

    # sources: optional, but if present must be [{title, url}].
    sources = digest.get("sources")
    if sources is not None:
        if not isinstance(sources, list):
            errs.append("sources must be an array")
        else:
            for i, src in enumerate(sources):
                if not isinstance(src, dict) or "title" not in src or "url" not in src:
                    errs.append(f"sources[{i}] must have 'title' and 'url'")

    # content: optional (v2). If present, an ordered array of typed blocks.
    # Only KNOWN block types get their shape validated; an unknown type is
    # accepted so long as the block is a JSON object (forward-compat — a
    # future v3 block must round-trip through this v2 validator unchanged).
    content = digest.get("content")
    if content is not None:
        if not isinstance(content, list):
            errs.append("content must be an array")
        else:
            for i, block in enumerate(content):
                errs.extend(_validate_block(i, block))

    if errs:
        raise EmitError("invalid digest:\n  - " + "\n  - ".join(errs))


def _validate_block(i: int, block) -> list[str]:
    """Shape-check one content block; return a (possibly empty) list of errors.

    Every block must be a JSON object. If its `type` is one of the six known
    types, its required shape is enforced (per docs/schema.md). If `type` is
    unknown, the block passes with no shape check — a future v3 block type must
    survive a round-trip through this v2 emitter unchanged, so an older
    companion can never reject newer content.
    """
    if not isinstance(block, dict):
        return [f"content[{i}] must be an object"]

    btype = block.get("type")
    # Unknown (or missing) type → passthrough. We don't gate on unknown types;
    # only the six known ones get shape-checked.
    if btype not in KNOWN_BLOCK_TYPES:
        return []

    errs: list[str] = []
    if btype in ("paragraph", "heading"):
        if not isinstance(block.get("text"), str):
            errs.append(f"content[{i}] ({btype}) must have a string 'text'")

    elif btype == "list":
        items = block.get("items")
        if not isinstance(items, list):
            errs.append(f"content[{i}] (list) must have an array 'items'")
        else:
            for j, item in enumerate(items):
                if not isinstance(item, str):
                    errs.append(f"content[{i}].items[{j}] (list) must be a string")
        style = block.get("style")
        if style is not None and style not in VALID_LIST_STYLES:
            errs.append(
                f"content[{i}] (list) 'style' must be one of "
                f"{VALID_LIST_STYLES}, got {style!r}"
            )

    elif btype == "callout":
        if not isinstance(block.get("text"), str):
            errs.append(f"content[{i}] (callout) must have a string 'text'")
        variant = block.get("variant")
        if variant is not None and variant not in VALID_CALLOUT_VARIANTS:
            errs.append(
                f"content[{i}] (callout) 'variant' must be one of "
                f"{VALID_CALLOUT_VARIANTS}, got {variant!r}"
            )
        title = block.get("title")
        if title is not None and not isinstance(title, str):
            errs.append(f"content[{i}] (callout) 'title' must be a string")

    elif btype == "metrics":
        items = block.get("items")
        if not isinstance(items, list):
            errs.append(f"content[{i}] (metrics) must have an array 'items'")
        else:
            for j, item in enumerate(items):
                if (not isinstance(item, dict)
                        or not isinstance(item.get("label"), str)
                        or not isinstance(item.get("value"), str)):
                    errs.append(
                        f"content[{i}].items[{j}] (metrics) must have string "
                        f"'label' and 'value'"
                    )

    # divider: no other fields required.
    return errs


def _parse_iso(text: str) -> bool:
    """True if `text` is a parseable ISO-8601 *datetime* (date + time).

    Tightened from the original "any fromisoformat-parseable string" because
    Python's `datetime.fromisoformat("2026-06-29")` cheerfully succeeds on a
    date-only string (returning midnight) — but the iOS decoder's
    `CrowlyISO8601.parse` uses `Date.ISO8601FormatStyle` strategies that all
    include a `.time(...)` component, so a date-only `created_at` would
    pass this validator and then crash the app's `Digest` decode. We
    explicitly require a time separator (`T` or `t`, per ISO 8601) to
    keep this validator's "what it accepts" aligned with the app's
    "what it can decode". `Z` for UTC is still accepted because the iOS
    parser also takes it.
    """
    if not isinstance(text, str):
        return False
    # ISO 8601 requires `T` between date and time (the standard separator);
    # the standard also permits a space, but the app's encoder/decoder both
    # use `T` so we hold the line there.
    if "T" not in text and "t" not in text:
        return False
    try:
        _dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
        return True
    except (ValueError, AttributeError):
        return False


# --------------------------------------------------------------------------
# Transport
# --------------------------------------------------------------------------

def post_digest(digest: dict, url: str, token: str, *, timeout: float = 15.0) -> dict:
    """POST a built digest to <url>/ingest with bearer auth.

    Returns the parsed JSON response on 2xx. Raises EmitError(kind='transport')
    on a non-2xx status or a network failure — the companion validates again
    and returns a 4xx with a clear body on a malformed payload (defense in
    depth), which we surface to the caller's logs.
    """
    if not url:
        raise EmitError("no companion url (pass --url or set CROWLY_COMPANION_URL)",
                        kind="transport")
    endpoint = url.rstrip("/") + "/ingest"
    body = json.dumps(digest, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(endpoint, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")

    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8") or "{}"
            return json.loads(raw)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise EmitError(
            f"companion returned {e.code}: {detail}", kind="transport"
        ) from e
    except urllib.error.URLError as e:
        raise EmitError(f"could not reach companion at {endpoint}: {e.reason}",
                        kind="transport") from e


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def _load_content(args) -> dict:
    if args.content_file:
        with open(args.content_file, "r", encoding="utf-8") as fh:
            return json.load(fh)
    data = sys.stdin.read()
    if not data.strip():
        raise EmitError("no content on stdin and no --content-file given")
    return json.loads(data)


def main(argv: list[str] | None = None) -> int:
    import os

    parser = argparse.ArgumentParser(
        description="Build a Crowly digest envelope from content and POST it "
                    "to the companion (or --dry-run to just print it)."
    )
    parser.add_argument("--content-file", help="JSON file of digest content "
                        "(default: read from stdin)")
    parser.add_argument("--url", default=os.environ.get("CROWLY_COMPANION_URL", ""),
                        help="companion base URL (env: CROWLY_COMPANION_URL)")
    parser.add_argument("--source", help="override the 'source' field")
    parser.add_argument("--dry-run", action="store_true",
                        help="build + validate + print the payload; do not POST")
    args = parser.parse_args(argv)

    try:
        content = _load_content(args)
        digest = build_digest(content, source=args.source)
    except (EmitError, json.JSONDecodeError, OSError) as e:
        print(f"crowly-emit: validation error: {e}", file=sys.stderr)
        return 2

    if args.dry_run:
        print(json.dumps(digest, indent=2, ensure_ascii=False))
        print(f"\ncrowly-emit: OK (dry run) — id={digest['id']}", file=sys.stderr)
        return 0

    # The token is env-only by design — no --token flag, so the secret never
    # lands on an argv (visible in `ps` and shell history).
    try:
        resp = post_digest(digest, args.url, os.environ.get("CROWLY_TOKEN", ""))
    except EmitError as e:
        print(f"crowly-emit: transport error: {e}", file=sys.stderr)
        return 3

    print(json.dumps(resp, ensure_ascii=False))
    print(f"crowly-emit: OK — posted id={digest['id']}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
