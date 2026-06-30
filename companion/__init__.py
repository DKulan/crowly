"""Crowly companion service — the per-user, self-hosted core of Crowly.

This package is the M1 production companion (vs. emitter/companion_stub.py,
which is a throwaway in-memory test double the docs reference). It's the
data-owning piece: ingest digests from emitters, store them on the user's own
VPS, serve them to the user's iOS app. Nothing more — no callbacks, no agent
integration, no external calls with digest content.

The hard invariants (from CLAUDE.md and docs/architecture.md §2):
  - **Ingest + store + serve, nothing more.**
  - **Unknown fields preserved verbatim** — store the WHOLE digest blob so a
    field a newer app understands survives a round-trip through this older
    companion. This must ship from the first stored digest; stripping
    unknowns can't be undone later without a data migration.
  - **Additive-only schema.** Never remove/repurpose fields.
  - **Content stays on the user's VPS.** No external calls with content.

Module map:
  store.py   — SQLite-backed persistence (digests + per-digest state).
  server.py  — HTTP handlers + main() entrypoint.
  __main__.py — `python3 -m companion` runs the service.
"""
