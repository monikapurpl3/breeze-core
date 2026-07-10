"""
meow_ac.cli — the diagnostic and approval tools as Python, for the
single-binary distribution (`breeze-core diag` / `approve` / `devices` /
`revoke`) and for `python -m meow_ac.cli` anywhere the package is installed.

These are straight ports of `tools/ac-diag.zsh` and `tools/ac-approve.zsh`
(which remain the zero-dependency option for source installs). Like the zsh
originals they are **pure HTTP clients**: they read `config.json` for the API
key and talk to the running server exactly like the web UI does — nothing in
here imports the server's internals, so the API contract stays the only
coupling.
"""
