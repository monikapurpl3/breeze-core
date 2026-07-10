"""
breeze-core — PyInstaller entry point for the self-contained bundles.

The real CLI lives in meow_ac.cli.main (single source of truth, also
reachable as `python -m meow_ac.cli` on any install); this shim exists only
so the bundle has a stable, package-external entry script.
"""
import sys

from meow_ac.cli.main import main

if __name__ == "__main__":
    sys.exit(main())
