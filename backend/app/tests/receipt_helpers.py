"""J1 / NF-009 test helpers: request bodies for the barangay's count at
receipt (POST /deliveries/{id}/confirm-receipt and
POST /trips/{id}/confirm-receipt)."""

# Well-formed bodies for tests that expect the request to be refused before
# the counts are looked at (wrong role, wrong barangay, not arrived yet).
ANY_COUNTS = {"items": [{"delivery_item_id": 0, "received_quantity": 0}]}
ANY_TRIP_COUNTS = {"deliveries": [{"delivery_id": 0, "items": ANY_COUNTS["items"]}]}


def _as_sent(items) -> list:
    """Every line counted exactly as CSWS sent it."""
    return [{"delivery_item_id": i["delivery_item_id"], "received_quantity": i["quantity"]}
            for i in items]


def full_counts(client, delivery_id, headers=None, remarks=None) -> dict:
    """Body for POST /deliveries/{id}/confirm-receipt with every line counted
    as sent. headers: anyone who can read the delivery (the rep, CSWS Main
    Office, the Administrator). Leave it out for the conftest clients
    (admin_client and the like), which carry their own user."""
    r = client.get(f"/deliveries/{delivery_id}", headers=headers)
    assert r.status_code == 200, r.text
    body = {"items": _as_sent(r.json()["items"])}
    if remarks is not None:
        body["remarks"] = remarks
    return body


def trip_counts(client, trip_id, headers, remarks=None) -> dict:
    """Body for POST /trips/{id}/confirm-receipt: every delivery of the trip
    that arrived at the rep's barangay, each line counted as sent. headers:
    the rep's own (the delivery list only shows their barangay)."""
    r = client.get("/deliveries/", headers=headers,
                   params={"trip_id": trip_id, "status": "Delivered"})
    assert r.status_code == 200, r.text
    body = {"deliveries": [{"delivery_id": d["delivery_id"], "items": _as_sent(d["items"])}
                           for d in r.json()]}
    if remarks is not None:
        body["remarks"] = remarks
    return body
