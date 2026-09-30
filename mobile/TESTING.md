# NexaAid test app — how to test every role

A small Flutter app for testing the backend end to end. It is not the final UI.

## Run it

1. Backend, from `backend/app` with the venv active:
   ```
   pip install -r ../requirements.txt
   uvicorn main:app --reload
   ```
2. App, from `mobile/`:
   ```
   flutter pub get
   flutter run -d chrome
   ```
   On an Android emulator the base URL defaults to `http://10.0.2.2:8000`.

## The three tabs

- **Account**: tap a role chip to fill in that test account, then tap **Login**. All test
  accounts use `testpass123`. This tab can also register a donor or an organization.
- **Modules**: lists the screens for your role first. The other roles' screens stay
  tappable, so you can confirm they return 403.
- **Checks**: calls 15 GET endpoints and compares each status with what your role should
  get (200 allowed, 403 blocked, 401 guest). You should see **15 / 15 as expected** for
  every role.

## Full walk-through (one pass tests every role)

| # | Log in as | Module | Action | Expect |
|---|-----------|--------|--------|--------|
| 1 | Barangay Receiving Rep | Disaster reports | Submit a report | 201, status Pending |
| 2 | Administrator | Disaster reports | Validate the report id | 200, priority_level set |
| 3 | Individual Donor (or guest) | Donate & QR code | Submit donation | 200 + QR image |
| 4 | CSWS Main Office | Receiving & inventory | Receive (donation_id, quantity), then Inventory | 200 |
| 5 | CMO Representative | CMO donation confirmation | Confirm the donation | 201 |
| 6 | CSWS Main Office | Logistics requests | Submit logistics request | 201 |
| 7 | DRRMO Logistics Support | Logistics requests | Accept request_id | 200, Accepted |
| 8 | CSWS Main Office | Deliveries & receipt | Create delivery, Advance twice | Preparing → In Transit → Delivered |
| 9 | Barangay Receiving Rep | Deliveries & receipt | Confirm receipt | 201, fulfillment % updated |
| 10 | CSWS Disaster Unit | Needs monitoring | Load | 200, shows fulfillment % |
| 11 | Admin / CSWS / Barangay | Dashboard | Load all four | 200 |

The same chain is automated on the backend in `backend/app/tests/test_role_flows.py`
(`pytest` from `backend/app`).

## Before the real demo

- Remove the test-account chips and the prefilled password in `lib/account_tab.dart`.
- Tighten `allow_origins` in `backend/app/main.py` (it is `*` for development).
