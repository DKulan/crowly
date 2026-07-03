#!/usr/bin/env python3
"""fetch_companion.py — get the Crowly companion source onto the host.

When setup-crowly is installed from the Hermes Skills Hub, the user receives
only this skill folder (SKILL.md + scripts/) — NOT the companion service it
exists to stand up. This script fetches the rest: it clones the Crowly repo (at
a PINNED ref) into a destination directory, which becomes the `$CROWLY_REPO`
that provision.py builds from.

Why a git clone and not a curl-pipe-to-shell: cloning a **pinned ref** of a
named, reviewable repo is not "fetch and run instructions from a live URL." The
code that lands is a specific, auditable commit the user can inspect before
provision.py runs anything — the same trust model as `hermes skills install` of
a trusted repo. We clone over HTTPS (read-only, no SSH key needed on a stranger's
host) and verify the checkout really is the Crowly repo before returning.

Stdlib only. Idempotent: re-running against an existing checkout updates it in
place rather than clobbering.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys


# The public, read-only clone URL. HTTPS so it works on any host without an SSH
# key configured. Override with --repo-url for a fork or a local mirror.
REPO_URL = "https://github.com/DKulan/crowly.git"

# The ref to check out. Pinned to the current release tag so a stranger's agent
# builds a known commit, not whatever HEAD happens to be — the whole point of
# "pinned + reviewable". Bump this in lockstep with each new release tag (and the
# --ref in SKILL.md Step 0); see docs/publishing-skills.md § Step 4.
DEFAULT_REF = "v1.0.0"

# Files that must exist after checkout for this to be a usable Crowly repo. If
# they're missing, we cloned the wrong thing (or a partial tree) — fail loud
# rather than hand provision.py a directory it can't build from.
_SENTINELS = ("companion/server.py", "emitter/crowly_emit.py")


def _run(argv: list[str], **kw) -> subprocess.CompletedProcess:
    print(f"  $ {' '.join(argv)}", flush=True)
    return subprocess.run(argv, check=False, **kw)


def _is_git_checkout(path: str) -> bool:
    return os.path.isdir(os.path.join(path, ".git"))


def _verify_repo(dest: str) -> bool:
    missing = [s for s in _SENTINELS if not os.path.exists(os.path.join(dest, s))]
    if missing:
        print(f"  ! {dest} is missing {missing} — this doesn't look like the "
              "Crowly repo. Aborting rather than building from it.", flush=True)
        return False
    return True


def _resolved_commit(dest: str) -> str:
    p = subprocess.run(["git", "-C", dest, "rev-parse", "HEAD"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return p.stdout.strip() if p.returncode == 0 else "(unknown)"


def fetch(dest: str, ref: str, repo_url: str) -> int:
    if shutil.which("git") is None:
        print("  ! git is not installed. Install git, or clone the Crowly repo "
              "by hand and pass its path as --repo-root to provision.py.", flush=True)
        return 1

    dest = os.path.abspath(dest)

    if _is_git_checkout(dest):
        # Already have it — update in place (non-destructive: we fetch + check
        # out the ref, but never reset/discard local changes).
        print(f"· {dest} is already a git checkout — fetching + checking out "
              f"{ref!r} (won't discard local changes).", flush=True)
        if _run(["git", "-C", dest, "fetch", "--tags", "origin"]).returncode != 0:
            print("  ! fetch failed — check network / the repo URL.", flush=True)
            return 1
        if _run(["git", "-C", dest, "checkout", ref]).returncode != 0:
            print(f"  ! could not check out {ref!r}. If it's a branch you want "
                  "latest on, run `git pull` in the checkout yourself.", flush=True)
            return 1
    elif os.path.exists(dest) and os.listdir(dest):
        print(f"  ! {dest} exists and is not empty (and not a git checkout). "
              "Refusing to clone into it — pick an empty --dest or remove it.",
              flush=True)
        return 1
    else:
        # Fresh clone at the pinned ref. --depth 1 keeps it light; a stranger
        # doesn't need the history to run the service.
        if _run(["git", "clone", "--depth", "1", "--branch", ref, repo_url, dest]).returncode != 0:
            print(f"  ! clone failed. Is {repo_url} reachable and is {ref!r} a "
                  "valid tag/branch? (A private repo needs credentials.)", flush=True)
            return 1

    if not _verify_repo(dest):
        return 1

    print(f"\n✓ Crowly repo ready at {dest}", flush=True)
    print(f"  ref={ref}  commit={_resolved_commit(dest)}", flush=True)
    print(f"  → pass this as --repo-root to provision.py:  CROWLY_REPO={dest}", flush=True)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Clone the Crowly repo (pinned ref) so provision.py can build "
                    "the companion from it. Idempotent; verifies the checkout.",
    )
    parser.add_argument("--dest", required=True,
                        help="where to put the checkout, e.g. ~/crowly. Becomes "
                             "$CROWLY_REPO.")
    parser.add_argument("--ref", default=DEFAULT_REF,
                        help=f"tag/branch to check out (default {DEFAULT_REF!r}). "
                             "Pass a release tag, e.g. v1.0.0, for a pinned install.")
    parser.add_argument("--repo-url", default=REPO_URL,
                        help=f"clone URL (default {REPO_URL}).")
    args = parser.parse_args(argv)

    dest = os.path.expanduser(args.dest)
    return fetch(dest, args.ref, args.repo_url)


if __name__ == "__main__":
    raise SystemExit(main())
