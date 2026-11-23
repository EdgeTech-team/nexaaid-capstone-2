"""Landing page report cards show how a report came in ("via Mobile"):
GET /public/reports includes the report's source, still without anything
about who reported it."""
from tests.m4_donation_management.test_donation_batch import _report
from tests.m1_user_management.test_role_flows import api, ok  # noqa: F401  (fixture)


def test_public_reports_include_source_but_not_the_reporter(api):
    client, t = api
    rid = _report(client, t)
    rows = ok(client.get("/public/reports"))  # no login needed
    row = next(r for r in rows if r["report_id"] == rid)
    assert row["source"] in ("Web", "Mobile", "SMS")
    assert not {"user_id", "validated_by", "reporter", "email"} & set(row)
