"""Entry point so `python3 -m companion` works (Docker CMD uses this)."""
from companion.server import main

if __name__ == "__main__":
    raise SystemExit(main())
