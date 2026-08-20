#!/bin/sh
# Service launcher for the rc script.
#
# The environment is set HERE, not in the rc script, and that is load-bearing:
# daemon(8) invoked with -u calls setusercontext(), which RESETS the environment.
# Anything exported from start_precmd never reaches uvicorn, which then dies with
# ModuleNotFoundError -- and because daemon runs with -f, the traceback goes to
# /dev/null and all the admin sees is "breeze_core is not running".
#
# PYTHONPATH rather than a cd, because daemon -c chdirs to / regardless.
# static/ needs no help: the app resolves it relative to its own package.
P=/usr/local/lib/breeze-core
export PYTHONPATH="$P"
export AC_CONFIG="${AC_CONFIG:-/usr/local/etc/breeze-core/config.json}"
exec "$P/venv/bin/python3.11" -m uvicorn meow_ac.app:app \
    --host "${1:-127.0.0.1}" --port "${2:-8420}"
