#!/usr/bin/env python3
"""detect_host.py — probe the host and print a JSON verdict for setup-crowly.

The `setup-crowly` skill runs this FIRST. It answers the exact questions
docs/deployment-learnings.md § "What the setup-crowly skill must do" enumerates,
so the agent (and provision.py) can pick the right branch instead of assuming a
topology. It only *reads* the host — it never installs, writes, or mutates
anything, so it's safe to run without approval.

Output: a single JSON object on stdout, e.g.

    {
      "docker": {"present": true, "daemon_reachable": true},
      "reverse_proxy": {"ports_in_use": [80, 443], "known_proxies": ["traefik"]},
      "tailscale": {"present": true, "logged_in": false, "funnel_capable": null},
      "python": {"version": "3.12.4", "sqlite3": true},
      "host_class": {"guess": "laptop", "reasons": ["has battery (pmset)"]},
      "recommendation": {
        "run_mode": "docker",          # docker | bare
        "tls": "funnel",               # funnel | existing-proxy | bundled-caddy
        "always_on_caveat": true       # surface the laptop-sleep warning
      }
    }

Stdlib only (subprocess/shutil/socket/platform) — the whole point of the
companion being dependency-free is that a Hermes agent can install it
unattended; this probe holds to the same bar. Every external command is
wrapped so a missing binary or a hang degrades to a "don't know" (null), never
a crash.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import socket
import subprocess
import sys


# A short timeout on every shelled-out probe. `tailscale status` in particular
# can block when the daemon is wedged; we never want detection to hang the
# agent. 4s is generous for a local status call and still bounded.
_CMD_TIMEOUT = 4


def _run(cmd: list[str]) -> tuple[int | None, str]:
    """Run a command, return (returncode, combined_output).

    Returns (None, "") if the binary is missing or the call times out — the
    caller treats that as "couldn't determine", never as a hard failure.
    """
    if shutil.which(cmd[0]) is None:
        return None, ""
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=_CMD_TIMEOUT,
            text=True,
            check=False,
        )
        return proc.returncode, proc.stdout or ""
    except (subprocess.TimeoutExpired, OSError):
        return None, ""


# --------------------------------------------------------------------------
# Docker
# --------------------------------------------------------------------------

def probe_docker() -> dict:
    """Docker present on PATH, and is its daemon actually reachable?

    Presence of the binary isn't enough — `docker info` fails when the daemon
    isn't running or the user can't reach the socket. provision.py needs the
    daemon reachable to use the containerized branch, so we check both.
    """
    present = shutil.which("docker") is not None
    if not present:
        return {"present": False, "daemon_reachable": False}
    # `docker info` hits the daemon; returncode 0 == reachable.
    code, _ = _run(["docker", "info"])
    return {"present": True, "daemon_reachable": code == 0}


# --------------------------------------------------------------------------
# Reverse proxy / port contention
# --------------------------------------------------------------------------

def _port_in_use(port: int) -> bool:
    """Best-effort: can we bind :port on localhost? If bind fails with
    EADDRINUSE, something already owns it. We bind to 127.0.0.1 (not 0.0.0.0)
    so we don't need privileges for the check itself and immediately close."""
    for family, addr in ((socket.AF_INET, ("127.0.0.1", port)),):
        s = socket.socket(family, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind(addr)
        except OSError:
            return True
        finally:
            s.close()
    return False


def probe_reverse_proxy() -> dict:
    """Is :80/:443 already taken, and can we name the proxy?

    Snag #2 in the war story: a bundled Caddy that binds :80/:443 collides with
    an existing Traefik/nginx. If either port is busy, provision.py must NOT use
    bundled Caddy — route via the existing proxy or (default) a tunnel instead.
    Naming the proxy is best-effort (helps the operator log); the port check is
    the load-bearing signal.
    """
    ports_in_use = [p for p in (80, 443) if _port_in_use(p)]
    known: list[str] = []
    for name in ("traefik", "nginx", "caddy", "haproxy"):
        if shutil.which(name) is not None:
            known.append(name)
    # Also look for them as running docker containers (the common self-host
    # shape) — only if the docker daemon is reachable.
    code, out = _run(["docker", "ps", "--format", "{{.Image}} {{.Names}}"])
    if code == 0:
        low = out.lower()
        for name in ("traefik", "nginx", "caddy", "haproxy"):
            if name in low and name not in known:
                known.append(name)
    return {"ports_in_use": ports_in_use, "known_proxies": known}


# --------------------------------------------------------------------------
# Tailscale
# --------------------------------------------------------------------------

def probe_tailscale() -> dict:
    """Is tailscale installed, and is this node logged in?

    Funnel is the default TLS strategy (snag #3). If tailscale is present and
    logged in, the one human auth click is already done. `tailscale status
    --json` gives us BackendState == "Running" when logged in; "NeedsLogin"
    otherwise. We keep funnel_capable null (can't cheaply prove Funnel is
    enabled for the tailnet without a mutating call).
    """
    present = shutil.which("tailscale") is not None
    if not present:
        return {"present": False, "logged_in": None, "funnel_capable": None}
    code, out = _run(["tailscale", "status", "--json"])
    logged_in: bool | None = None
    if code is not None and out.strip():
        try:
            state = json.loads(out).get("BackendState")
            logged_in = state == "Running"
        except (json.JSONDecodeError, AttributeError):
            logged_in = None
    return {"present": True, "logged_in": logged_in, "funnel_capable": None}


# --------------------------------------------------------------------------
# Python / sqlite3 (bare-process prerequisites)
# --------------------------------------------------------------------------

def probe_python() -> dict:
    """The bare-process branch runs `python3 -m companion`, which needs a
    working Python 3 with the sqlite3 stdlib module. We're already running
    under Python 3, so report our own version and whether sqlite3 imports."""
    try:
        import sqlite3  # noqa: F401
        has_sqlite = True
    except ImportError:
        has_sqlite = False
    return {"version": platform.python_version(), "sqlite3": has_sqlite}


# --------------------------------------------------------------------------
# Host class: VPS vs. laptop (drives the always-on caveat)
# --------------------------------------------------------------------------

def probe_host_class() -> dict:
    """Best-effort guess: is this an always-on server or a personal computer
    that sleeps? Drives the always-on caveat (a sleeping companion can't be
    pulled — docs/onboarding.md § Where the companion can run).

    This is a heuristic, not a certainty. When we can't tell, we guess
    "unknown" and provision.py surfaces the caveat as a *question* to the
    operator rather than silently assuming always-on.
    """
    reasons: list[str] = []
    system = platform.system()  # "Darwin", "Linux", ...

    is_laptop = False

    if system == "Darwin":
        # A Mac with a battery is a laptop; `pmset -g batt` reports "Battery"
        # on portables and "AC Power" / no battery on desktops. macOS hosts are
        # almost always personal computers anyway.
        code, out = _run(["pmset", "-g", "batt"])
        if code == 0 and "Battery" in out:
            is_laptop = True
            reasons.append("macOS host with a battery (pmset)")
        else:
            # A Mac at all is overwhelmingly a personal machine, not a VPS.
            is_laptop = True
            reasons.append("macOS host (personal computer by default)")
    elif system == "Linux":
        # /sys/class/power_supply/BAT* exists on laptops. Its absence is the
        # common VPS case. This is the strongest cheap signal on Linux.
        power_supply = "/sys/class/power_supply"
        try:
            entries = os.listdir(power_supply)
        except OSError:
            entries = []
        if any(e.startswith("BAT") for e in entries):
            is_laptop = True
            reasons.append("Linux host with a battery (/sys/class/power_supply/BAT*)")
        else:
            reasons.append("no battery detected — likely an always-on server")

    guess = "laptop" if is_laptop else ("server" if reasons else "unknown")
    return {"guess": guess, "reasons": reasons}


# --------------------------------------------------------------------------
# Recommendation — fold the probes into a branch pick
# --------------------------------------------------------------------------

def recommend(docker: dict, proxy: dict, host_class: dict) -> dict:
    """Fold the raw probes into the branch provision.py should take.

    - run_mode: docker when the daemon is reachable, else bare process.
    - tls: default 'funnel' (the cross-topology unifier). Only prefer
      'existing-proxy' when a proxy already owns :80/:443 AND the operator
      would rather route through it — we still default to funnel because it's
      the one path that needs no domain and the agent can drive it. We surface
      existing-proxy as the note, not the default.
    - always_on_caveat: true when the host looks like a laptop OR we can't tell
      (fail toward warning, never silently ship an unreachable-half-the-day box).
    """
    run_mode = "docker" if docker.get("daemon_reachable") else "bare"

    # Funnel is always the default (see docs/deployment-learnings.md snag #3).
    # The proxy signal is advisory: it tells the operator that bundled Caddy
    # would collide, so if they opt out of Funnel, existing-proxy is the path —
    # not bundled-caddy.
    tls = "funnel"

    always_on_caveat = host_class.get("guess") in ("laptop", "unknown")

    return {
        "run_mode": run_mode,
        "tls": tls,
        "always_on_caveat": always_on_caveat,
    }


def main() -> int:
    docker = probe_docker()
    proxy = probe_reverse_proxy()
    tailscale = probe_tailscale()
    python_info = probe_python()
    host_class = probe_host_class()

    verdict = {
        "docker": docker,
        "reverse_proxy": proxy,
        "tailscale": tailscale,
        "python": python_info,
        "host_class": host_class,
        "recommendation": recommend(docker, proxy, host_class),
    }
    json.dump(verdict, sys.stdout, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
