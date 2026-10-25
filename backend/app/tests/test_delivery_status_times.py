"""Delivery timestamps (Oct 2026): when each step was reached, from the
status history, sent with every delivery in the list."""
from tests.test_logistics_needs import _delivery
from tests.test_role_flows import api, ok  # noqa: F401  (fixture)


def _times(client, t, did):
    rows = ok(client.get("/deliveries/", headers=t["csws"]))
    return next(d for d in rows if d["delivery_id"] == did)["status_times"]


def test_each_step_has_its_time_and_a_returned_truck_starts_over(api):
    client, t = api
    did = _delivery(client, t)["delivery_id"]
    assert list(_times(client, t, did)) == ["Preparing"]

    ok(client.post(f"/deliveries/{did}/advance", headers=t["csws"]))
    times = _times(client, t, did)
    assert list(times) == ["Preparing", "In Transit"]
    assert times["In Transit"] >= times["Preparing"]

    # The truck came back: Preparing again, the In Transit time no longer applies.
    ok(client.post(f"/deliveries/{did}/return-to-office", headers=t["csws"],
                   json={"reason": "The truck broke down"}))
    assert list(_times(client, t, did)) == ["Preparing"]
