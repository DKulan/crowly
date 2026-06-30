"""Entry point so `python3 -m relay` works (Docker CMD uses this)."""
from relay.server import main

if __name__ == "__main__":
    raise SystemExit(main())
