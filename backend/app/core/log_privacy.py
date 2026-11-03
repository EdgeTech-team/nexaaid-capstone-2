"""F-22: keep personal data out of the server logs.

- mask_email(): failure logs name the recipient as j***@gmail.com, enough to
  tell accounts apart, without the address.
- Access log: uvicorn logs every request line, and the query string can hold
  searched names, emails or home addresses (address suggestions, user
  search). Only the path is kept.
"""
import logging
import re

QUERY_HIDDEN = "?[hidden]"


def mask_email(address: str) -> str:
    local, at, domain = (address or "").partition("@")
    if not at:
        return "***"
    return f"{local[:1]}***@{domain}"


def without_email(text, address: str) -> str:
    """text with every copy of address (any letter case) masked."""
    text = str(text or "")
    if not address:
        return text
    return re.sub(re.escape(address), mask_email(address), text, flags=re.IGNORECASE)


class HideQueryStrings(logging.Filter):
    """uvicorn.access records carry (client, method, path?query, version, status)."""

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if isinstance(args, tuple) and len(args) == 5 and isinstance(args[2], str) and "?" in args[2]:
            path = args[2].split("?", 1)[0] + QUERY_HIDDEN
            record.args = (args[0], args[1], path, args[3], args[4])
        return True


class HideWebSocketQuery(logging.Filter):
    """uvicorn logs WebSocket handshakes on uvicorn.error as
    '%s - "WebSocket %s" ...' with (client, path?query). GET /ws carries the
    login token in the query string, so only the path is kept."""

    def filter(self, record: logging.LogRecord) -> bool:
        args = record.args
        if ('"WebSocket %s"' in str(record.msg) and isinstance(args, tuple) and len(args) >= 2
                and isinstance(args[1], str) and "?" in args[1]):
            record.args = (args[0], args[1].split("?", 1)[0] + QUERY_HIDDEN) + args[2:]
        return True


def hide_query_strings_in_access_log() -> None:
    access = logging.getLogger("uvicorn.access")
    if not any(isinstance(f, HideQueryStrings) for f in access.filters):
        access.addFilter(HideQueryStrings())
    errors = logging.getLogger("uvicorn.error")
    if not any(isinstance(f, HideWebSocketQuery) for f in errors.filters):
        errors.addFilter(HideWebSocketQuery())
