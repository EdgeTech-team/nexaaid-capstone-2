"""F-22: masked addresses, and no query strings in the access log."""
import logging

from uvicorn.logging import AccessFormatter

import main  # noqa: F401  (installs the access-log filter)
from core.log_privacy import HideQueryStrings, mask_email


def test_mask_email():
    assert mask_email("juan.delacruz@gmail.com") == "j***@gmail.com"
    assert mask_email("no-at-sign") == "***"
    assert mask_email("") == "***"


def _access(path):
    return logging.LogRecord("uvicorn.access", logging.INFO, __file__, 1,
                             '%s - "%s %s HTTP/%s" %d',
                             ("203.0.113.7:0", "GET", path, "1.1", 200), None)


def test_access_log_hides_query_strings():
    record = _access("/admin/users?q=juan.delacruz%40gmail.com")
    assert HideQueryStrings().filter(record) is True
    line = AccessFormatter('%(client_addr)s - "%(request_line)s" %(status_code)s',
                           use_colors=False).format(record)
    assert "juan" not in line and "/admin/users?[hidden]" in line and "200" in line
    plain = _access("/public/reports")
    HideQueryStrings().filter(plain)
    assert plain.getMessage().endswith('"GET /public/reports HTTP/1.1" 200')


def test_the_app_installs_the_filter():
    filters = logging.getLogger("uvicorn.access").filters
    assert any(isinstance(f, HideQueryStrings) for f in filters)
