from api.v1.drrmo_router import priority_sort_key


def test_drrmo_queue_orders_by_priority_then_oldest():
    rows = [
        {"request_id": 1, "priority_level": "Low"},
        {"request_id": 2, "priority_level": None},        # unscored -> last
        {"request_id": 3, "priority_level": "Critical"},
        {"request_id": 4, "priority_level": "High"},
        {"request_id": 5, "priority_level": "Critical"},  # same level -> older first
    ]
    ordered = [r["request_id"] for r in sorted(rows, key=priority_sort_key)]
    assert ordered == [3, 5, 4, 1, 2]