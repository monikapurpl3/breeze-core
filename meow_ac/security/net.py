"""
Client-IP resolution and the "is this request from the LAN?" check.

Enrollment *approval* is admin-only from the trusted network, so we need
the real client IP. Behind a reverse proxy the socket peer is the proxy
(often 127.0.0.1), and the true client is in `X-Forwarded-For`. We only
trust that header when the deployment says it's behind a proxy
(Settings.behind_proxy) — otherwise a client could spoof it. When behind
a proxy, uvicorn must also run with `--forwarded-allow-ips` (or the proxy
must be trusted) for `request.client` to be sane; the XFF parse here is
the app-level counterpart.
"""
from __future__ import annotations

import ipaddress
from typing import Optional


def client_ip(request, behind_proxy: bool) -> Optional[str]:
    """Best-effort real client IP for `request`."""
    if behind_proxy:
        xff = request.headers.get("x-forwarded-for")
        if xff:
            # left-most entry is the original client
            return xff.split(",")[0].strip()
    return request.client.host if request.client else None


def is_private_ip(ip: Optional[str]) -> bool:
    """True for loopback / RFC1918 / link-local / unique-local addresses
    — i.e. 'on my LAN or the box itself', not the public internet."""
    if not ip:
        return False
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return (
        addr.is_private
        or addr.is_loopback
        or addr.is_link_local
    )
