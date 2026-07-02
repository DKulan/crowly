"""SQLite-backed store for the Crowly companion.

The store is split into two concerns that mirror docs/schema.md and
docs/architecture.md § Companion → Store:

  1. **The digest blob** — the entire JSON document as the emitter sent it,
     preserved VERBATIM. This is the hard invariant: a future field a v2 app
     understands has to survive a round-trip through this v1 companion, so the
     companion cannot pick the digest apart and reassemble it on serve. We
     store the raw bytes (well, the canonicalised JSON string) and hand them
     back unchanged. A few fields (`id`, `created_at`, `urgency`, `job_id`,
     `schema_version`) are *also* denormalised into columns — purely for
     idempotency keying, sort order, and cheap aggregates. The denorm columns
     are derived from the blob, never authoritative; the blob always wins.
  2. **Per-digest state** — `unread | read | archived`. State is NOT part of
     the digest contract (the schema is content-only, see docs/schema.md
     § What's deliberately not in the schema). It lives next to the digest
     because architecture.md § Companion → Store says so: "state lives here
     too, mirrored from the app via simple state-change writes". A separate
     column keeps the digest blob inviolable.

The single SQLite file (path from `CROWLY_DB_PATH`) survives container
restarts — that's the M1 persistence requirement. We use stdlib `sqlite3`
only; no SQLAlchemy or other deps (the package is dependency-free Python 3).
"""

from __future__ import annotations

import json
import sqlite3
import threading
from contextlib import contextmanager
from typing import Iterator, Optional

# State values mirror Shared/Models/Schema.swift's DigestState enum exactly.
# The app's the source of truth for the legal set; this list is replicated
# here only so the companion can reject unknown writes with a clear 422 rather
# than silently persist a state value the app can't decode.
VALID_STATES = ("unread", "read", "archived")


class Store:
    """A thin SQLite wrapper. One file, one connection per thread (via a small
    pool keyed off `threading.local`).

    Why connection-per-thread: Python's `sqlite3` connections are not safe to
    share across threads by default (the check_same_thread guard). The HTTP
    server runs handlers on multiple threads (ThreadingHTTPServer), so each
    thread grabs its own connection lazily; SQLite serialises writes at the
    file level anyway, so this is plenty for a single-user companion.
    """

    def __init__(self, db_path: str):
        self.db_path = db_path
        self._local = threading.local()
        # Initialise schema on the main thread once. Idempotent — re-running
        # is harmless because every DDL statement uses `IF NOT EXISTS`.
        with self._connection() as conn:
            self._init_schema(conn)

    # -- connection management ------------------------------------------------

    def _connection(self) -> sqlite3.Connection:
        """Per-thread connection, opened lazily. Returns the same connection
        for repeated calls from the same thread so transactions compose."""
        conn = getattr(self._local, "conn", None)
        if conn is None:
            # `isolation_level=None` puts us in autocommit-ish mode; we
            # explicitly manage transactions via BEGIN/COMMIT in `transaction`.
            # WAL gives us concurrent readers + a single writer without
            # blocking the GET endpoints behind an in-flight POST /ingest.
            conn = sqlite3.connect(
                self.db_path,
                isolation_level=None,
                check_same_thread=True,
            )
            conn.row_factory = sqlite3.Row
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA foreign_keys=ON")
            self._local.conn = conn
        return conn

    @contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        """A short BEGIN IMMEDIATE / COMMIT envelope. Ingest's upsert needs
        the read-then-write to be atomic so two concurrent POSTs with the
        same id don't race to "is this a new row?" and both report 201."""
        conn = self._connection()
        conn.execute("BEGIN IMMEDIATE")
        try:
            yield conn
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise

    def _init_schema(self, conn: sqlite3.Connection) -> None:
        # `digests.blob` holds the whole JSON document the emitter sent,
        # serialised with sort_keys=True so the round-trip is stable and
        # diffable. The other columns are derived from the blob on insert and
        # exist only to make /list (ORDER BY created_at) and /summary
        # (WHERE state='unread') cheap. If we ever want to re-derive them
        # after a schema bump, we can — the blob is the source of truth.
        conn.execute("""
            CREATE TABLE IF NOT EXISTS digests (
                id             TEXT PRIMARY KEY,
                created_at     TEXT NOT NULL,
                urgency        TEXT NOT NULL,
                job_id         TEXT NOT NULL,
                schema_version INTEGER NOT NULL,
                blob           TEXT NOT NULL,
                state          TEXT NOT NULL DEFAULT 'unread',
                received_at    TEXT NOT NULL,
                updated_at     TEXT NOT NULL
            )
        """)
        # /list and /summary both sort by created_at DESC; this is the only
        # interesting query pattern for M1 so a single index is enough.
        conn.execute("""
            CREATE INDEX IF NOT EXISTS digests_created_at_idx
                ON digests (created_at DESC)
        """)
        # /summary filters on state='unread'; cheap second index.
        conn.execute("""
            CREATE INDEX IF NOT EXISTS digests_state_idx
                ON digests (state)
        """)

    # -- digest operations ----------------------------------------------------

    def upsert_digest(self, digest: dict, *, received_at: str) -> tuple[dict, bool]:
        """Insert or update a digest. Returns (stored_digest, was_update).

        Idempotency: re-POSTing the same `id` updates the row, never creates a
        duplicate. The emitter generates ids deterministically (sha256 of
        sorted content keys), so retries collapse to one row even on the
        client side; this is the server's belt-and-braces guarantee.

        Note: we re-serialise the dict with sort_keys=True so the on-disk
        bytes are stable across emitter Python versions. We do NOT strip any
        keys — the dict passed in includes the full validated payload PLUS
        any unknown future fields the validator left alone (KNOWN_KEYS in
        crowly_emit.py is informational; validate() doesn't reject unknowns).
        """
        digest_id = digest["id"]
        blob = json.dumps(digest, sort_keys=True, ensure_ascii=False)

        with self.transaction() as conn:
            existing = conn.execute(
                "SELECT state FROM digests WHERE id = ?", (digest_id,)
            ).fetchone()
            is_update = existing is not None

            if is_update:
                # Preserve the existing state on re-POST. The schema is
                # content-only, so an emitter re-emitting a digest must not
                # be able to flip the user's "read" state back to "unread" —
                # state is the *app's* business, mirrored separately via
                # POST /state.
                conn.execute("""
                    UPDATE digests
                       SET created_at=?, urgency=?, job_id=?, schema_version=?,
                           blob=?, updated_at=?
                     WHERE id=?
                """, (
                    digest["created_at"], digest["urgency"], digest["job_id"],
                    digest["schema_version"], blob, received_at, digest_id,
                ))
            else:
                conn.execute("""
                    INSERT INTO digests
                        (id, created_at, urgency, job_id, schema_version,
                         blob, state, received_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, 'unread', ?, ?)
                """, (
                    digest_id, digest["created_at"], digest["urgency"],
                    digest["job_id"], digest["schema_version"], blob,
                    received_at, received_at,
                ))

        return digest, is_update

    def list_digests(self) -> list[dict]:
        """All digests, newest-first by created_at. Each carries its state.

        Wire shape: `[{"digest": <verbatim contract blob>, "state": "…"}, …]`.

        The wrapper exists so the served digest object stays *pure* — bytes
        the emitter sent, byte-for-byte. State is a UI/companion concern and
        explicitly NOT part of the digest schema (docs/schema.md: "schema
        describes content shape only"). Earlier versions of this code
        injected `_state` into the digest dict, which made the inbox
        ergonomic to render in one round-trip but risked a re-POSTed
        served digest persisting `_state` as a "future field" — polluting
        the additive-only passthrough invariant. The wrapper structurally
        prevents that round-trip class of bug.
        """
        conn = self._connection()
        rows = conn.execute("""
            SELECT blob, state FROM digests ORDER BY created_at DESC, id DESC
        """).fetchall()
        return [self._row_to_payload(row) for row in rows]

    def summary(self, latest_n: int = 5) -> dict:
        """Cheap widget endpoint: unread count + the latest N non-archived
        digests + the total non-archived count.

        `latest_n` is 5 so the `.systemLarge` widget can fill its 4–5 rows
        (medium/small render fewer from the same payload). Latest is by
        `created_at`, not by arrival — a back-dated digest from a late-firing
        cron doesn't jump to the top of the widget.

        Archived digests are EXCLUDED from `latest` and `total`: archive is the
        inbox's triage move, so a triaged digest must not resurface on the home
        screen. This matches the app-side snapshot writer
        (`DigestStore.publishWidgetSnapshot`, which filters `!= .archived`) so
        the widget's two data sources — this live fetch and the App Group
        snapshot — agree. `total` backs the large widget's "View all N →"
        footer and counts what the inbox shows (non-archived).
        """
        conn = self._connection()
        unread = conn.execute(
            "SELECT COUNT(*) AS n FROM digests WHERE state = 'unread'"
        ).fetchone()["n"]
        total = conn.execute(
            "SELECT COUNT(*) AS n FROM digests WHERE state != 'archived'"
        ).fetchone()["n"]
        latest_rows = conn.execute("""
            SELECT blob, state FROM digests
             WHERE state != 'archived'
             ORDER BY created_at DESC, id DESC
             LIMIT ?
        """, (latest_n,)).fetchall()
        return {
            "unread_count": unread,
            "total": total,
            "latest": [self._row_to_payload(r) for r in latest_rows],
        }

    def set_state(self, digest_id: str, state: str, *, updated_at: str) -> bool:
        """Mirror an app-side state change. Returns True if the row existed.

        Timestamp is passed in (rather than computed via `datetime('now')` in
        SQL) so every write to `updated_at` uses the same ISO-8601-with-offset
        format `upsert_digest` does. Earlier versions used SQLite's
        `datetime('now')` here, which produced "YYYY-MM-DD HH:MM:SS" (space
        separator, no timezone) — different shape, same column, hard to
        diff. Keeping timekeeping in the server layer keeps the store dumb.
        """
        if state not in VALID_STATES:
            raise ValueError(f"invalid state {state!r}; expected one of {VALID_STATES}")
        conn = self._connection()
        cur = conn.execute("""
            UPDATE digests SET state=?, updated_at=? WHERE id=?
        """, (state, updated_at, digest_id))
        return cur.rowcount > 0

    def get_digest(self, digest_id: str) -> Optional[dict]:
        """Used by tests; not exposed over HTTP in M1."""
        conn = self._connection()
        row = conn.execute(
            "SELECT blob, state FROM digests WHERE id = ?", (digest_id,)
        ).fetchone()
        return self._row_to_payload(row) if row else None

    def count(self) -> int:
        """Total digests; used by /health."""
        conn = self._connection()
        return conn.execute("SELECT COUNT(*) AS n FROM digests").fetchone()["n"]

    # -- helpers --------------------------------------------------------------

    @staticmethod
    def _row_to_payload(row: sqlite3.Row) -> dict:
        """Decode a stored blob and return a `{digest, state}` wrapper.

        We decode the verbatim JSON every read (vs. caching a parsed copy)
        because the blob is the source of truth and the read path is cheap —
        SQLite's already in WAL, the JSON is small, and any caching would be
        another place for the "passthrough must be exact" invariant to leak.

        The wrapper keeps the digest object pure: state is a sibling key,
        never a member of the digest dict. A consumer that re-POSTs
        `result["digest"]` verbatim cannot accidentally promote `state`
        to a contract field — it's structurally outside.
        """
        return {
            "digest": json.loads(row["blob"]),
            "state": row["state"],
        }
