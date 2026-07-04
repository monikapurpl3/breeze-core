"""Request authentication for the API.

The shipped scheme is device-pairing: a shared enrollment key (api_key)
lets a client begin enrollment; an admin on the LAN approves a short
one-time code; the client receives a per-device token; and full API
access then requires both the API key and that token
(`CompositeAuthenticator`). See `enrollment.py` for the handshake and
`base.py` for how to add further factors.
"""

from meow_ac.security.api_key import ApiKeyAuthenticator
from meow_ac.security.base import Authenticator
from meow_ac.security.composite import CompositeAuthenticator
from meow_ac.security.device_token import DeviceTokenAuthenticator
from meow_ac.security.enrollment import EnrollmentService
from meow_ac.security.token_store import TokenStore

__all__ = [
    "Authenticator",
    "ApiKeyAuthenticator",
    "DeviceTokenAuthenticator",
    "CompositeAuthenticator",
    "EnrollmentService",
    "TokenStore",
]
