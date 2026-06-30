"""SQLite-backed store for the Crowly push relay.

The schema is **deliberately minimal** because the privacy invariant
(`docs/architecture.md` § Privacy & data, CLAUDE.md § Invariants) is that the
relay holds ONLY `routing_token → device_token`. No digests, no titles, no
URLs — not by policy, but **structurally**: the table below literally has no
column that could hold a body. A reviewer can check the schema and know.

There are exactly two operations the relay needs:

  * `upsert(device_token, routing_token=None) -> routing_token`
    The app registers (idempotent on device_token: re-register updates the
    mapping rather than minting a second routing_token for the same device).
    If `routing_token` is None, mint a new opaque one.

  * `device_token_for(routing_token) -> str | None`
    The relay's `/push` handler resolves the routing_token to a device_token
    just long enough to hand it to APNs, then forgets it.

  * `delete_by_routing_token(routing_token) -> bool`
    The privacy-purge path. Returns True if a row was deleted.

  * `delete_by_device_token(device_token) -> int`
    APNs "unregistered" feedback path — when Apple tells us a device token is
    no longer valid (e.g. app uninstalled), we purge anything routing to it.

Why connection-per-thread: same reason as companion/store.py — stdlib
`sqlite3` connections aren't safe to share across threads, and the relay's
HTTP server is a ThreadingHTTPServer.
"""

from __future__ import annotations

import secrets
import sqlite3
import threading
from contextlib import contextmanager
from typing import Iterator, Optional


class Store:
    """A two-column SQLite table. That's it.

    The whole point of this class is that there is nowhere to put a digest
    title, URL, body, or pointer text. If a future "feature" needs to add a
    column here, that's a design change — re-read docs/architecture.md
    § Privacy & data before doing it.
    """

    def __init__(self, db_path: str):
        self.db_path = db_path
        self._local = threading.local()
        with self._connection() as conn:
            self._init_schema(conn)

    # -- connection management ------------------------------------------------

    def _connection(self) -> sqlite3.Connection:
        conn = getattr(self._local, "conn", None)
        if conn is None:
            conn = sqlite3.connect(
                self.db_path,
                isolation_level=None,  # we manage transactions explicitly
                check_same_thread=True,
            )
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            self._local.conn = conn
        return conn

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        conn = self._connection()
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise

    def _init_schema(self, conn: sqlite3.Connection) -> None:
        # The whole schema. Two strings. No body, no title, no URL field —
        # by design. The relay literally cannot store digest content.
        #
        # `device_token` is unique because re-registering the same device
        # must NOT create a parallel routing_token (we'd leak pushes to a
        # ghost mapping forever). The app can re-register safely; the
        # routing_token we hand back stays stable for that device.
        #
        # `created_at` exists only so an operator can age out stale rows
        # manually if APNs feedback ever fails. It's NOT request metadata
        # ("which routing_token got pushed at when") — that would violate
        # the fan-out-and-forget rule.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS routes (
                routing_token TEXT PRIMARY KEY,
                device_token  TEXT NOT NULL UNIQUE,
                created_at    TEXT NOT NULL DEFAULT (datetime('now'))
            )
        """)
        conn.execute("""
            CREATE INDEX IF NOT EXISTS routes_device_idx
                ON routes (device_token)
        """)

    # -- operations -----------------------------------------------------------

    def upsert(
        self,
        device_token: str,
        routing_token: Optional[str] = None,
    ) -> str:
        """Register a device. Returns the routing_token (newly minted, or the
        existing one for this device).

        Idempotent on device_token: a re-register from the same device returns
        the same routing_token it got the first time. This is what lets the
        app safely call /register on every cold start without leaking ghost
        rows; it also means an attacker who somehow learns a device_token
        cannot mint a fresh routing_token to redirect pushes — they'd just
        get the existing one (which they already need the device for to
        receive pushes anyway).
        """
        if not device_token or not isinstance(device_token, str):
            raise ValueError("device_token must be a non-empty string")
        if routing_token is not None and not isinstance(routing_token, str):
            raise ValueError("routing_token must be a string if provided")

        with self.transaction() as conn:
            existing = conn.execute(
                "SELECT routing_token FROM routes WHERE device_token = ?",
                (device_token,),
            ).fetchone()
            if existing is not None:
                # Re-register from the same device; keep the existing token.
                # The caller's supplied routing_token (if any) is ignored on
                # purpose — a device can't pick its own opaque id.
                return existing["routing_token"]

            # New device. Mint a routing_token if the caller didn't supply
            # one. We always prefer minting server-side; the parameter exists
            # for tests and for a future "import a routing_token from another
            # relay" path that doesn't ship in M1.
            rt = routing_token or _mint_routing_token()
            conn.execute(
                "INSERT INTO routes (routing_token, device_token) VALUES (?, ?)",
                (rt, device_token),
            )
            return rt

    def device_token_for(self, routing_token: str) -> Optional[str]:
        """Resolve a routing_token to a device_token. Returns None if unknown.

        Called from the /push hot path. The caller MUST NOT log the result —
        device tokens are personal data per docs/architecture.md § Privacy.
        """
        if not routing_token or not isinstance(routing_token, str):
            return None
        conn = self._connection()
        row = conn.execute(
            "SELECT device_token FROM routes WHERE routing_token = ?",
            (routing_token,),
        ).fetchone()
        return row["device_token"] if row else None

    def delete_by_routing_token(self, routing_token: str) -> bool:
        """Purge by routing_token. The in-app "disconnect" path."""
        if not routing_token or not isinstance(routing_token, str):
            return False
        conn = self._connection()
        cur = conn.execute(
            "DELETE FROM routes WHERE routing_token = ?", (routing_token,)
        )
        return cur.rowcount > 0

    def delete_by_device_token(self, device_token: str) -> int:
        """Purge by device_token. Used when APNs reports the device is gone.

        Returns the number of rows deleted (0 if the device wasn't registered).
        """
        if not device_token or not isinstance(device_token, str):
            return 0
        conn = self._connection()
        cur = conn.execute(
            "DELETE FROM routes WHERE device_token = ?", (device_token,)
        )
        return cur.rowcount

    def count(self) -> int:
        """Total registered devices. /health uses this; no per-token detail."""
        conn = self._connection()
        return conn.execute("SELECT COUNT(*) AS n FROM routes").fetchone()["n"]

    # -- introspection (tests only) -------------------------------------------

    def column_names(self) -> list[str]:
        """List the columns of the routes table. Used by the test that asserts
        the schema literally cannot hold a title/url — if a future commit adds
        a `pointer_text` column, that test fails immediately."""
        conn = self._connection()
        rows = conn.execute("PRAGMA table_info(routes)").fetchall()
        return [r["name"] for r in rows]


def _mint_routing_token() -> str:
    """Opaque, URL-safe, ~256 bits of entropy. The `rt_` prefix is purely a
    debugging affordance (so a stray token in a log line is immediately
    recognisable as a routing token, not a pairing token or anything else)."""
    return "rt_" + secrets.token_urlsafe(32)
