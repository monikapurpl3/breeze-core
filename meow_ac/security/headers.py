"""
SecurityHeadersMiddleware — response hardening headers.

Applied when Settings.security_headers is on (the default). If your
reverse proxy already sets these, turn it off (AC_SECURITY_HEADERS=0) to
avoid duplicate headers.

The CSP is strict — `default-src 'self'` — which the UI satisfies because
it loads only its own same-origin CSS/JS modules and carries no inline
`<style>`/`style=""` or inline scripts. (Styles applied at runtime via
`element.style` in JS are not restricted by CSP.) Keep it that way: an
inline handler or inline style attribute would need loosening the CSP.
"""
from __future__ import annotations

from starlette.middleware.base import BaseHTTPMiddleware

_HEADERS = {
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Content-Security-Policy": (
        "default-src 'self'; base-uri 'none'; frame-ancestors 'none'; "
        "object-src 'none'; form-action 'self'"
    ),
    # Ignored by browsers over plain HTTP; takes effect once served via
    # HTTPS (e.g. behind the nginx + Let's Encrypt reverse proxy).
    "Strict-Transport-Security": "max-age=63072000; includeSubDomains",
}


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request, call_next):
        response = await call_next(request)
        for name, value in _HEADERS.items():
            response.headers.setdefault(name, value)
        return response
