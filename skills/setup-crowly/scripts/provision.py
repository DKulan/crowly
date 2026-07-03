#!/usr/bin/env python3
"""provision.py — stand up the Crowly companion for the detected topology.

Runs the branch that detect_host.py picked. Three branches, matching the
topology matrix in docs/onboarding.md § "Where the companion can run":

  * docker           — containerized (docker-compose.local.yml + crowly-net),
                       the proven war-story path (docs/deployment-learnings.md).
  * bare-systemd     — bare `python3 -m companion` behind a systemd unit, for a
                       no-Docker VPS or an always-on desktop.
  * bare-foreground  — the raw command for a personal computer / ad-hoc run.

SAFETY MODEL (this is a pinned, reviewable skill — docs/onboarding.md security
rule). The script is **plan-first**: by default it PRINTS the numbered plan and
does nothing. It only mutates the host when called with `--apply`, and even then
it runs *only* the deterministic, idempotent steps (create a docker network if
absent, write a systemd unit, bring the service up). It NEVER runs the
human-in-the-loop steps — `tailscale up` (an auth click) and the pairing scan
are printed as instructions for the operator, never executed. That keeps the
irreducibly-human security boundary intact (docs/deployment-learnings.md
§ "The irreducibly-human steps").

This script deliberately does NOT touch the pairing token. Token generation and
the pairing QR live in render_pairing.py, so the one secret has one owner and
provision.py has no reason to read, log, or echo it.

Stdlib only. Every shelled-out step is echoed before it runs.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys


# The companion's internal (co-located) address — never the public Funnel URL,
# which fails TLS from inside the tailnet (docs/deployment-learnings.md snag #4).
# The phone uses the external Funnel URL; the emitter and any co-located agent
# use one of these.
INTERNAL_URL_DOCKER = "http://crowly-companion:8787"
INTERNAL_URL_BARE = "http://127.0.0.1:8787"

CROWLY_NET = "crowly-net"
SYSTEMD_UNIT_PATH = "/etc/systemd/system/crowly-companion.service"


# --------------------------------------------------------------------------
# Plan model — a step is (human description, argv-or-None). argv None means
# "this is a manual/human step, print it but never run it".
# --------------------------------------------------------------------------

class Step:
    def __init__(self, desc: str, argv: list[str] | None = None, *,
                 manual: bool = False, note: str | None = None):
        self.desc = desc
        self.argv = argv
        self.manual = manual  # human-in-the-loop; printed, never executed
        self.note = note


def _repo_root(explicit: str | None) -> str:
    """The monorepo root — the parent of companion/ and emitter/. The Docker
    build context and the bare-process PYTHONPATH both need both dirs as
    siblings (docs/deployment-learnings.md snag #1). Default: two levels up
    from this script (setup-crowly/scripts/ → repo root)."""
    if explicit:
        return os.path.abspath(explicit)
    # scripts/ -> setup-crowly/ -> hermes-skill/ -> emitter/ -> repo root
    here = os.path.abspath(__file__)
    return os.path.abspath(os.path.join(os.path.dirname(here), "..", "..", "..", ".."))


# --------------------------------------------------------------------------
# Branch: docker
# --------------------------------------------------------------------------

def plan_docker(args) -> list[Step]:
    root = _repo_root(args.repo_root)
    compose_dir = os.path.join(root, "companion")
    steps: list[Step] = []

    # 1. Shared external network (idempotent — the actual apply checks first).
    steps.append(Step(
        f"Create the shared Docker network '{CROWLY_NET}' if it doesn't exist "
        f"(lets a co-located Hermes container reach the companion by name).",
        ["docker", "network", "create", CROWLY_NET],
        note="Skipped automatically if the network already exists.",
    ))

    # 2. Bring the companion up via the Funnel/loopback variant.
    steps.append(Step(
        "Build + start the companion (binds 127.0.0.1:8787, joins "
        f"'{CROWLY_NET}') via docker-compose.local.yml. Reads the token and "
        "public URL from companion/.env.",
        ["docker", "compose", "-f", "docker-compose.local.yml", "up", "-d", "--build"],
    ))

    # 3. Attach the Hermes container — via an override, never by editing a
    #    managed compose, and preserving the default network (snag #5).
    if args.hermes_compose_dir:
        override_path = os.path.join(args.hermes_compose_dir, "docker-compose.override.yml")
        steps.append(Step(
            f"Write {override_path} attaching the Hermes service "
            f"'{args.hermes_service or '<service>'}' to '{CROWLY_NET}' while "
            "preserving its 'default' network (dropping default breaks Traefik "
            "routing). Then the operator restarts Hermes.",
            note="Writes a file next to the Hermes compose — does NOT edit the "
                 "managed compose itself.",
        ))
    else:
        steps.append(Step(
            "MANUAL: attach your Hermes/agent container to the "
            f"'{CROWLY_NET}' network so it can emit to "
            f"'{INTERNAL_URL_DOCKER}'. Re-run with --hermes-compose-dir "
            "(and --hermes-service) to have this script write the override, "
            "or add the network to your agent's compose by hand (preserve the "
            "'default' network).",
            manual=True,
        ))

    return steps


def _docker_network_exists() -> bool:
    if shutil.which("docker") is None:
        return False
    proc = subprocess.run(
        ["docker", "network", "inspect", CROWLY_NET],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    return proc.returncode == 0


def apply_docker(args) -> int:
    root = _repo_root(args.repo_root)
    compose_dir = os.path.join(root, "companion")

    if not _docker_network_exists():
        if _run_step(["docker", "network", "create", CROWLY_NET]) != 0:
            return 1
    else:
        print(f"  · network '{CROWLY_NET}' already exists — skipping create.", flush=True)

    rc = _run_step(
        ["docker", "compose", "-f", "docker-compose.local.yml", "up", "-d", "--build"],
        cwd=compose_dir,
    )
    if rc != 0:
        return 1

    if args.hermes_compose_dir:
        if not args.hermes_service:
            print("  ! --hermes-service is required to write the override; "
                  "skipping. Attach Hermes to the network manually.", flush=True)
        else:
            _write_hermes_override(args.hermes_compose_dir, args.hermes_service)
    return 0


def _write_hermes_override(compose_dir: str, service: str) -> None:
    """Write a docker-compose.override.yml that joins the Hermes service to
    crowly-net AND preserves the default network. Never edits the managed
    compose (docs/deployment-learnings.md snag #5)."""
    override_path = os.path.join(compose_dir, "docker-compose.override.yml")
    content = (
        "# Written by setup-crowly (provision.py). Attaches this agent to the\n"
        "# shared 'crowly-net' so it can emit to http://crowly-companion:8787.\n"
        "# 'default' is kept — dropping it breaks the managed proxy's routing.\n"
        "services:\n"
        f"  {service}:\n"
        "    networks:\n"
        "      - default\n"
        f"      - {CROWLY_NET}\n"
        "networks:\n"
        f"  {CROWLY_NET}:\n"
        "    external: true\n"
    )
    if os.path.exists(override_path):
        print(f"  ! {override_path} already exists — not overwriting. "
              "Merge the crowly-net stanza by hand.", flush=True)
        return
    with open(override_path, "w", encoding="utf-8") as f:
        f.write(content)
    print(f"  · wrote {override_path}. Restart Hermes to pick up the network "
          f"(e.g. `docker compose -f <hermes-compose> up -d`).", flush=True)


# --------------------------------------------------------------------------
# Branch: bare-systemd
# --------------------------------------------------------------------------

def _systemd_unit(root: str, env_file: str, user: str) -> str:
    """A systemd unit that runs the bare process, reads secrets from the env
    file, and puts both packages on PYTHONPATH. Restarts on failure and at
    boot — the 'always-on' the VPS branch promises."""
    return (
        "# Written by setup-crowly (provision.py).\n"
        "[Unit]\n"
        "Description=Crowly companion (ingest + store + serve)\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n"
        "\n"
        "[Service]\n"
        "Type=simple\n"
        f"User={user}\n"
        f"WorkingDirectory={root}\n"
        f"EnvironmentFile={env_file}\n"
        f"Environment=PYTHONPATH={root}:{os.path.join(root, 'emitter')}\n"
        "ExecStart=/usr/bin/env python3 -m companion\n"
        "Restart=on-failure\n"
        "RestartSec=3\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )


def plan_bare_systemd(args) -> list[Step]:
    root = _repo_root(args.repo_root)
    env_file = args.env_file or os.path.join(root, "companion", ".env")
    user = args.service_user or os.environ.get("USER", "root")
    steps = [
        Step(
            f"Write a systemd unit to {SYSTEMD_UNIT_PATH} that runs "
            f"`python3 -m companion` from {root}, reads secrets from "
            f"{env_file}, and restarts on failure + at boot (needs root).",
            note="Requires write access to /etc/systemd/system (sudo).",
        ),
        Step("Reload systemd so it sees the new unit.",
             ["systemctl", "daemon-reload"]),
        Step("Enable + start the companion now (and on every boot).",
             ["systemctl", "enable", "--now", "crowly-companion.service"]),
    ]
    _ = user  # surfaced in apply; referenced here only for the plan text
    return steps


def apply_bare_systemd(args) -> int:
    root = _repo_root(args.repo_root)
    env_file = args.env_file or os.path.join(root, "companion", ".env")
    user = args.service_user or os.environ.get("USER", "root")

    if not os.path.exists(env_file):
        print(f"  ! env file {env_file} not found. Run render_pairing.py "
              "--ensure-token first so the companion has a token to read.",
              flush=True)
        return 1

    unit = _systemd_unit(root, env_file, user)
    try:
        with open(SYSTEMD_UNIT_PATH, "w", encoding="utf-8") as f:
            f.write(unit)
    except PermissionError:
        print(f"  ! cannot write {SYSTEMD_UNIT_PATH} — re-run with sudo.", flush=True)
        return 1
    print(f"  · wrote {SYSTEMD_UNIT_PATH}", flush=True)

    if _run_step(["systemctl", "daemon-reload"]) != 0:
        return 1
    return _run_step(["systemctl", "enable", "--now", "crowly-companion.service"])


# --------------------------------------------------------------------------
# Branch: bare-foreground
# --------------------------------------------------------------------------

def plan_bare_foreground(args) -> list[Step]:
    root = _repo_root(args.repo_root)
    env_file = args.env_file or os.path.join(root, "companion", ".env")
    # `set -a; . <envfile>; set +a` sources the vars into the shell without
    # putting the token on any argv — unlike `env $(… | xargs)`, which would
    # expose CROWLY_PAIRING_TOKEN in `ps`/`/proc/<pid>/cmdline` and shell
    # history. This matches the confidentiality the systemd branch's
    # EnvironmentFile= already gives.
    cmd = (
        f"cd {root} && set -a && . {env_file} && set +a && "
        f"PYTHONPATH={root}:{os.path.join(root, 'emitter')} "
        "python3 -m companion"
    )
    return [
        Step(
            "Run the companion in the foreground (personal computer / ad-hoc). "
            "This does not survive logout or sleep — for an always-on setup use "
            "the bare-systemd branch instead.",
            note=cmd,
            manual=True,
        ),
        Step(
            "ALWAYS-ON CAVEAT: Crowly is pull-only. A companion on a computer "
            "that sleeps can't be pulled — the app and widget show the last "
            "snapshot until the machine wakes. This is unavoidable for a "
            "sometimes-off host (push is not the fix; see docs/roadmap.md "
            "Phase 4). Surface this to the user before finishing.",
            manual=True,
        ),
    ]


# --------------------------------------------------------------------------
# Plan printing + execution
# --------------------------------------------------------------------------

def _run_step(argv: list[str], cwd: str | None = None) -> int:
    print(f"  $ {' '.join(argv)}" + (f"   (in {cwd})" if cwd else ""), flush=True)
    try:
        return subprocess.run(argv, cwd=cwd, check=False).returncode
    except OSError as e:
        print(f"  ! failed to run {argv[0]}: {e}", flush=True)
        return 1


def print_plan(mode: str, steps: list[Step], internal_url: str) -> None:
    bar = "=" * 68
    print(bar, flush=True)
    print(f"setup-crowly · provision plan · mode = {mode}", flush=True)
    print(bar, flush=True)
    for i, s in enumerate(steps, 1):
        tag = " [MANUAL]" if s.manual else ""
        print(f"{i}. {s.desc}{tag}", flush=True)
        if s.argv:
            print(f"     $ {' '.join(s.argv)}", flush=True)
        if s.note:
            print(f"     ↪ {s.note}", flush=True)
    print(bar, flush=True)
    print(f"Emitter/agent must POST to the INTERNAL address: {internal_url}", flush=True)
    print("The PHONE uses the EXTERNAL Funnel URL (set as CROWLY_PUBLIC_URL "
          "and shown in the pairing QR) — never the internal address.", flush=True)
    print(bar, flush=True)


PLANNERS = {
    "docker": (plan_docker, apply_docker, INTERNAL_URL_DOCKER),
    "bare-systemd": (plan_bare_systemd, apply_bare_systemd, INTERNAL_URL_BARE),
    "bare-foreground": (plan_bare_foreground, None, INTERNAL_URL_BARE),
}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Provision the Crowly companion for the detected topology. "
                    "Plan-first: prints the plan and does nothing unless --apply "
                    "is given. Never runs human-in-the-loop steps.",
    )
    parser.add_argument(
        "--mode", required=True, choices=sorted(PLANNERS),
        help="branch to run (from detect_host.py's recommendation.run_mode: "
             "'docker' → docker; 'bare' → bare-systemd for a VPS, "
             "bare-foreground for a laptop).",
    )
    parser.add_argument("--repo-root", help="monorepo root (parent of companion/ "
                        "+ emitter/). Default: inferred from this script's path.")
    parser.add_argument("--env-file", help="companion env file (bare branches). "
                        "Default: <repo>/companion/.env")
    parser.add_argument("--service-user", help="user the systemd unit runs as "
                        "(bare-systemd). Default: $USER.")
    parser.add_argument("--hermes-compose-dir", help="dir holding the Hermes "
                        "compose (docker branch) — where the override is written.")
    parser.add_argument("--hermes-service", help="Hermes service name to attach "
                        "to crowly-net (docker branch, with --hermes-compose-dir).")
    parser.add_argument("--apply", action="store_true",
                        help="actually execute the deterministic steps. Without "
                             "this, only the plan is printed.")
    args = parser.parse_args(argv)

    planner, applier, internal_url = PLANNERS[args.mode]
    steps = planner(args)
    print_plan(args.mode, steps, internal_url)

    if not args.apply:
        print("\n(plan only — re-run with --apply to execute the non-manual "
              "steps. Manual steps are never executed.)", flush=True)
        return 0

    if applier is None:
        print("\n(bare-foreground has no automatable steps — run the command "
              "above yourself.)", flush=True)
        return 0

    print("\n--apply: executing the deterministic steps…", flush=True)
    rc = applier(args)
    if rc == 0:
        print("\n✓ provision steps complete. Next: set up TLS (tailscale up + "
              "funnel), then render the pairing QR (render_pairing.py).", flush=True)
    else:
        print("\n✗ a provision step failed — see the output above. Nothing "
              "destructive was attempted; safe to fix and re-run.", flush=True)
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
