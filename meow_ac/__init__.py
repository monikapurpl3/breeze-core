"""
meow-ac — LAN-only control for multiple Midea air conditioners.

This package is the *only* stateful component of the project. It is a
standalone REST API built from small, decoupled layers:

    settings   runtime configuration (env-driven)
    config     the on-disk config.json as a typed, mutable store
    security   request authentication (currently an API key)
    devices    device connection lifecycle + state (de)serialization
    api        HTTP routers, assembled by the app factory

The web UI (static/) and the diagnostic CLI (tools/ac-diag.zsh) are
clients of the API, not part of this package.

Entry point for uvicorn is `meow_ac.app:app` (see meow_ac/app.py).
"""

__version__ = "2.6.0"
