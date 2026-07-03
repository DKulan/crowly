#!/usr/bin/env python3
"""render_pairing.py — mint the pairing token and present the pairing QR.

This is the ONE owner of the pairing secret. It:

  1. Ensures the companion's env file has a strong CROWLY_PAIRING_TOKEN
     (generates one only if absent — idempotent, so re-running never rotates a
     working token out from under a paired app).
  2. Belt-and-braces asserts CROWLY_PAIR_ENABLED stays OFF (see below).
  3. Builds the pairing payload the iOS app expects — the same shape the
     companion's own /pair would return: {companion_url, pairing_token}
     (docs/architecture.md § Pairing) — and renders it as a QR the operator
     shows to the phone, with a plain URL+token manual-entry fallback.

WHY THIS IS SAFER THAN THE MANUAL RUNBOOK. The old flow flipped the network
/pair endpoint ON to hand the phone its token, then relied on the operator to
flip it back OFF. The companion's public Funnel hostname is discoverable in
Certificate Transparency logs, so any window where /pair is open leaks full
read+ingest access to anyone who finds the URL — this was the P0 on the first
deploy (docs/deployment-learnings.md § Pre-deploy gate). Rendering the QR
locally on the host means the secret moves host → phone via the QR the operator
scans, and the network /pair endpoint NEVER has to be opened. This script
therefore refuses to touch CROWLY_PAIR_ENABLED except to force it off.

The token is printed to the operator's local stdout on purpose — that's a local
channel (same as the companion's own startup banner), and the operator needs to
see it to scan/type it. It is never sent anywhere over the network by this
script.

Stdlib only, plus an optional `qrencode` binary for the pretty terminal QR.
"""

from __future__ import annotations

import argparse
import os
import re
import secrets
import shutil
import subprocess
import sys


TOKEN_KEY = "CROWLY_PAIRING_TOKEN"
PUBLIC_URL_KEY = "CROWLY_PUBLIC_URL"
PAIR_ENABLED_KEY = "CROWLY_PAIR_ENABLED"


# --------------------------------------------------------------------------
# .env read / write — minimal KEY=value handling that preserves the file's
# comments and untouched lines. Not a full dotenv parser; the companion's env
# file is plain KEY=value (see companion/.env.example).
# --------------------------------------------------------------------------

_LINE_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$")


def read_env(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    if not os.path.exists(path):
        return values
    with open(path, encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            m = _LINE_RE.match(line)
            if m:
                values[m.group(1)] = m.group(2).strip()
    return values


def set_env_key(path: str, key: str, value: str) -> None:
    """Set key=value in the env file, replacing an existing assignment in place
    or appending if absent. Preserves every other line (comments included).

    The env file holds the bearer token, so when we CREATE it we lock it to
    0o600 (owner-only) — on a shared VPS the default umask (0o644) would leave
    the token world-readable to any local user. We only tighten a file we just
    created; a pre-existing file keeps whatever perms the operator chose (never
    loosen, never surprise-clobber)."""
    pre_existing = os.path.exists(path)
    lines: list[str] = []
    if pre_existing:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()

    replaced = False
    for i, line in enumerate(lines):
        m = _LINE_RE.match(line)
        if m and m.group(1) == key:
            lines[i] = f"{key}={value}\n"
            replaced = True
            break
    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{key}={value}\n")

    # Make sure the directory exists (bare branch may point at a fresh path).
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)

    if not pre_existing:
        # Create owner-only, before any secret hits the disk. O_CREAT|O_EXCL
        # with mode 0o600 sets perms atomically at creation (umask still
        # applies subtractively, but 0o600 & ~umask is 0o600 for any sane
        # umask). If a racing writer created it first, fall back to a plain
        # open — we won't tighten someone else's file.
        try:
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.writelines(lines)
            return
        except FileExistsError:
            pass
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)


# --------------------------------------------------------------------------
# Token
# --------------------------------------------------------------------------

def ensure_token(env_path: str) -> tuple[str, bool]:
    """Return (token, generated?). Generates + persists a token only if the env
    file doesn't already have a non-placeholder one — so re-running is safe and
    never rotates a live token. Uses the same generator the repo documents
    (secrets.token_urlsafe(32); companion/.env.example)."""
    existing = read_env(env_path).get(TOKEN_KEY, "").strip()
    placeholder = existing in ("", "replace-me-with-a-long-random-token")
    if not placeholder:
        return existing, False
    token = secrets.token_urlsafe(32)
    set_env_key(env_path, TOKEN_KEY, token)
    return token, True


def force_pair_disabled(env_path: str) -> None:
    """Force CROWLY_PAIR_ENABLED=0. We render the QR locally, so the network
    /pair endpoint must stay closed (see module docstring). This is the one
    place the script touches that key, and only ever to turn it OFF."""
    current = read_env(env_path).get(PAIR_ENABLED_KEY, "").strip().lower()
    if current in ("1", "true", "yes"):
        set_env_key(env_path, PAIR_ENABLED_KEY, "0")
        print(f"  · forced {PAIR_ENABLED_KEY}=0 (it was on — the network /pair "
              "endpoint would leak the token; we render the QR locally instead).",
              flush=True)


# --------------------------------------------------------------------------
# QR rendering
# --------------------------------------------------------------------------

def render_qr(payload_json: str) -> bool:
    """Render the payload as a terminal QR via `qrencode` if available. Returns
    True if a QR was drawn, False if the binary is missing (caller then falls
    back to the plain URL+token manual-entry path)."""
    if shutil.which("qrencode") is None:
        return False
    try:
        # -t ANSIUTF8 draws a compact, scannable block QR in the terminal;
        # -o - writes it to stdout. The payload (which contains the token) is
        # fed on STDIN, never as an argv element — so it can't leak via `ps`.
        proc = subprocess.run(
            ["qrencode", "-t", "ANSIUTF8", "-o", "-"],
            input=payload_json.encode("utf-8"),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if proc.returncode == 0 and proc.stdout:
            sys.stdout.buffer.write(proc.stdout)
            sys.stdout.flush()
            return True
    except OSError:
        pass
    return False


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def _build_payload_json(companion_url: str, token: str) -> str:
    """Exactly the shape QRPairScannerView / PairCompanionView parse
    (docs/architecture.md § Pairing). Built by hand (not json.dumps) so the key
    order matches the companion's own /pair payload for readability; both fields
    are simple strings with no escaping concerns."""
    import json
    return json.dumps({"companion_url": companion_url, "pairing_token": token},
                      ensure_ascii=False)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Mint the pairing token (if absent) and present the pairing "
                    "QR locally. Never opens the network /pair endpoint.",
    )
    parser.add_argument("--env-file", required=True,
                        help="companion env file to read/write the token in "
                             "(e.g. companion/.env or /opt/data/.env).")
    parser.add_argument("--public-url",
                        help="the EXTERNAL URL the phone dials (the Funnel "
                             "hostname). Default: CROWLY_PUBLIC_URL from the env "
                             "file. This is the app-facing address — never the "
                             "internal http://crowly-companion:8787.")
    parser.add_argument("--ensure-token", action="store_true",
                        help="generate + persist a token if the env file lacks "
                             "one. Without this flag, an absent token is an error "
                             "(so you don't accidentally pair against no token).")
    args = parser.parse_args(argv)

    env_path = os.path.abspath(args.env_file)

    # Token.
    if args.ensure_token:
        token, generated = ensure_token(env_path)
    else:
        token = read_env(env_path).get(TOKEN_KEY, "").strip()
        generated = False
        if not token or token == "replace-me-with-a-long-random-token":
            print(f"✗ no {TOKEN_KEY} in {env_path}. Re-run with --ensure-token "
                  "to generate one.", file=sys.stderr)
            return 2

    # Public URL (app-facing / external).
    public_url = (args.public_url or read_env(env_path).get(PUBLIC_URL_KEY, "")).strip().rstrip("/")
    if not public_url:
        print(f"✗ no public URL. Pass --public-url <funnel-url> or set "
              f"{PUBLIC_URL_KEY} in {env_path} first (it's the address the "
              "phone dials — the Funnel hostname, not the internal one).",
              file=sys.stderr)
        return 2
    if not public_url.startswith("https://"):
        # The app refuses plain http:// for a non-loopback host (ATS). A funnel
        # URL is always https; warn loudly rather than hand out a URL the phone
        # will reject.
        print(f"  ! WARNING: public URL {public_url!r} is not https://. The app "
              "refuses non-HTTPS for a remote host (App Transport Security). "
              "Use the Funnel/proxy HTTPS URL.", flush=True)

    # Persist the public URL so the companion's own banner + payload agree, and
    # force the pairing endpoint off.
    set_env_key(env_path, PUBLIC_URL_KEY, public_url)
    force_pair_disabled(env_path)

    payload_json = _build_payload_json(public_url, token)

    bar = "=" * 68
    print(bar, flush=True)
    print("setup-crowly · pair your phone", flush=True)
    print(bar, flush=True)
    if generated:
        print(f"· generated a new pairing token and wrote it to {env_path}", flush=True)
        print("  (restart the companion so it picks up the token before scanning)", flush=True)
    print(f"· companion URL (what the phone dials): {public_url}", flush=True)
    print(bar, flush=True)

    drew = render_qr(payload_json)
    if drew:
        print(bar, flush=True)
        print("Scan the QR above in the Crowly app (Pair → Scan QR).", flush=True)
    else:
        print("qrencode not installed — use the app's MANUAL entry instead:", flush=True)
        print(f"    Companion URL : {public_url}", flush=True)
        print(f"    Pairing token : {token}", flush=True)
        print("(Install `qrencode` for a scannable code, or type these two "
              "fields into the app's manual pairing screen.)", flush=True)
    print(bar, flush=True)
    print("Note: the network /pair endpoint stays OFF — this token was shown "
          "locally, never served over HTTP. That's deliberate (a public /pair "
          "leaks the token via CT logs).", flush=True)
    print(bar, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
