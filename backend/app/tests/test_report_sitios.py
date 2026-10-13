"""
problema_napud 2.2: a report can name several sitios, all of its own
barangay. disaster_reports.sitio_id keeps the first one, so code that only
knows one sitio keeps working.
"""
from models.report import Barangay, Sitio


def _sitios(db_session):
    db_session.add_all([
        Sitio(sitio_id=2, barangay_id=1, sitio_name="Sitio Two"),
        Sitio(sitio_id=3, barangay_id=1, sitio_name="Sitio Three"),
        Barangay(barangay_id=2, barangay_name="Other Barangay", city_id=1),
    ])
    db_session.flush()
    db_session.add(Sitio(sitio_id=9, barangay_id=2, sitio_name="Elsewhere"))
    db_session.commit()


def _payload(seed, **extra):
    return {
        "disaster_type_id": seed["disaster_type_id"],
        "barangay_id": seed["barangay_id"],
        "description": "Flooding along the main road.",
        "affected_families": 12,
        "assistance_needed": "Rice: 10 sacks",
        **extra,
    }


def test_report_with_several_sitios(reporter_client, seed, db_session):
    _sitios(db_session)
    r = reporter_client.post("/reports/", json=_payload(seed, sitio_ids=[3, 1, 3]))
    assert r.status_code == 201, r.text
    body = r.json()
    assert body["sitio_ids"] == [1, 3]          # duplicates dropped
    assert body["sitio_id"] == 1                # the first one, for older code
    assert body["sitio_names"] == ["Sitio Test", "Sitio Three"]


def test_one_sitio_the_old_way_still_works(reporter_client, seed):
    r = reporter_client.post("/reports/", json=_payload(seed, sitio_id=seed["sitio_id"]))
    assert r.status_code == 201, r.text
    assert r.json()["sitio_ids"] == [seed["sitio_id"]]
    assert r.json()["sitio_names"] == ["Sitio Test"]


def test_sitio_of_another_barangay_is_refused(reporter_client, seed, db_session):
    _sitios(db_session)
    r = reporter_client.post("/reports/", json=_payload(seed, sitio_ids=[1, 9]))
    assert r.status_code == 422
    assert "barangay" in r.json()["detail"]
    r = reporter_client.post("/reports/", json=_payload(seed, sitio_ids=[404]))
    assert r.status_code == 422


def test_edit_changes_the_sitios(reporter_client, seed, db_session):
    _sitios(db_session)
    rid = reporter_client.post("/reports/", json=_payload(seed, sitio_ids=[1])).json()["report_id"]
    r = reporter_client.put(f"/reports/{rid}/mine", json=_payload(seed, sitio_ids=[2, 3]))
    assert r.status_code == 200, r.text
    assert r.json()["sitio_ids"] == [2, 3] and r.json()["sitio_id"] == 2
    r = reporter_client.put(f"/reports/{rid}/mine", json=_payload(seed, sitio_ids=[]))
    assert r.json()["sitio_ids"] == [] and r.json()["sitio_id"] is None


def test_sms_report_with_several_sitios(unit_client, seed, db_session):
    _sitios(db_session)
    r = unit_client.post("/reports/sms", json={
        **_payload(seed, sitio_ids=[2, 3]),
        "contact_number": "09171234567",
        "raw_message": "NEXAAID REPORT\nSITIO: Sitio Two, Sitio Three",
    })
    assert r.status_code == 201, r.text
    assert r.json()["report"]["sitio_ids"] == [2, 3]


def test_public_and_lookup_lists_show_every_sitio(reporter_client, admin_client, seed, db_session):
    _sitios(db_session)
    rid = reporter_client.post("/reports/", json=_payload(seed, sitio_ids=[2, 3])).json()["report_id"]
    r = admin_client.post(f"/reports/{rid}/validate", json={})
    assert r.status_code == 200, r.text
    rows = reporter_client.get("/public/reports").json()
    row = next(x for x in rows if x.get("report_id", x.get("id")) == rid)
    assert row["sitios"] == ["Sitio Two", "Sitio Three"]
    assert row["sitio"] == "Sitio Two, Sitio Three"
