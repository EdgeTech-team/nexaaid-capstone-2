"""F-21: the client's real address behind Render's proxy (and Cloudflare).

Each proxy in front of the app adds the address that connected to it at
the right end of X-Forwarded-For; a client can write anything at the left
end. So the client is the entry TRUSTED_PROXY_HOPS places from the right.

Too many hops trusts an entry the client wrote (forgeable). Too few gives
a proxy's address (wrong, but never forgeable). So it starts at 1 and is
raised only if the post-deploy check shows a proxy's address, by setting
TRUSTED_PROXY_HOPS on Render (no code change).

Only in production: locally there is no proxy, so the header is ignored.
"""
import ipaddress
import os

from core.config import settings

TRUSTED_PROXY_HOPS = int(os.getenv("TRUSTED_PROXY_HOPS", "1"))


def client_from_forwarded(header: str, hops: int | None = None) -> str | None:
    """The trusted client address in an X-Forwarded-For value, or None."""
    hops = TRUSTED_PROXY_HOPS if hops is None else hops
    entries = [e.strip() for e in header.split(",") if e.strip()]
    if hops < 1 or len(entries) < hops:
        return None             # fewer entries than our proxies add: keep the direct peer
    try:
        return str(ipaddress.ip_address(entries[-hops].strip("[]")))
    except ValueError:
        return None


class ClientIPMiddleware:
    """Sets the request's client address (and http/https) from the proxy
    headers, before any route or the audit log reads request.client."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and settings.APP_ENV == "production":
            headers = scope["headers"]
            forwarded = ", ".join(v.decode("latin-1") for k, v in headers if k == b"x-forwarded-for")
            host = client_from_forwarded(forwarded)
            if host:
                port = scope["client"][1] if scope.get("client") else 0
                scope = {**scope, "client": (host, port)}
            protos = [v.decode("latin-1") for k, v in headers if k == b"x-forwarded-proto"]
            proto = protos[-1].split(",")[-1].strip() if protos else ""
            if proto in ("http", "https"):
                scope = {**scope, "scheme": proto}
        await self.app(scope, receive, send)
