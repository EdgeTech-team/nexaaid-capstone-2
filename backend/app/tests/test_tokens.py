"""F-22: tokens are made and checked by PyJWT (replacing python-jose):
creation, expiry, signature and algorithm checks on the real auth stack.
F-10 revocation after a password change or reset is covered by
tests/test_password_change_tokens.py, which now runs on PyJWT too."""
import base64
import json
from datetime import datetime, timedelta, timezone

import jwt

from core.config import settings
from tests.test_password_change_tokens import STALE, _login
from tests.test_role_flows import ACCOUNTS, PASSWORD, api, ok  # noqa: F401  (fixture)

DONOR = ACCOUNTS["donor"][0]


def _b64(data: dict) -> str:
    return base64.urlsafe_b64encode(json.dumps(data).encode()).rstrip(b"=").decode()


def _status(client, token):
    r = client.get("/auth/me", headers={"Authorization": f"Bearer {token}"})
    return r.status_code, r.json().get("detail")


def test_login_token_is_hs256_with_the_usual_claims_and_a_60_minute_expiry(api):
    client, _ = api
    res = _login(client, DONOR, PASSWORD)
    token = res["access_token"]
    assert jwt.get_unverified_header(token)["alg"] == "HS256"
    claims = jwt.decode(token, settings.SECRET_KEY, algorithms=["HS256"])
    assert set(claims) == {"sub", "uid", "role", "pwd", "exp"}
    assert claims["sub"] == DONOR
    left = claims["exp"] - datetime.now(timezone.utc).timestamp()
    assert 59 * 60 < left <= 60 * 60
    assert res["expires_in"] == 60 * 60
    me = ok(client.get("/auth/me", headers={"Authorization": f"Bearer {token}"}))
    assert me["email"] == DONOR


def test_expired_wrongly_signed_and_tampered_tokens_are_refused(api):
    client, _ = api
    token = _login(client, DONOR, PASSWORD)["access_token"]
    claims = jwt.decode(token, settings.SECRET_KEY, algorithms=["HS256"])
    header, payload, signature = token.split(".")

    expired = jwt.encode({**claims, "exp": datetime.now(timezone.utc) - timedelta(seconds=1)},
                         settings.SECRET_KEY, algorithm="HS256")
    wrong_key = jwt.encode(claims, "not-the-server-key", algorithm="HS256")
    other_alg = jwt.encode(claims, settings.SECRET_KEY, algorithm="HS512")
    alg_none = f"{_b64({'alg': 'none', 'typ': 'JWT'})}.{payload}."
    tampered = f"{header}.{_b64({**claims, 'uid': claims['uid'] + 1})}.{signature}"

    for name, bad in {"expired": expired, "wrong key": wrong_key, "HS512": other_alg,
                      "alg none": alg_none, "tampered": tampered,
                      "not a token": "not-a-token"}.items():
        assert _status(client, bad) == (401, STALE), name
