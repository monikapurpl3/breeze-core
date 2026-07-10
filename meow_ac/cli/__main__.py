"""`python -m meow_ac.cli` — the breeze-core CLI (serve / pair / diag /
approve / devices / revoke / version) for source and Windows installs."""
import sys

from .main import main

if __name__ == "__main__":
    sys.exit(main())
