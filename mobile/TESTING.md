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

## Full walk-through (follows the manuscript use cases)

Every id is picked from a dropdown (disaster type, barangay, report, donation, delivery,
request), so you never type an id.

| # | Log in as | Module | Action | Expect |
|---|-----------|--------|--------|--------|
| 1 | CSWS Disaster Unit | Submit post-disaster report (UC-CD1) | Fill in and submit | 201, Pending |
| 2 | Administrator | Process reports (UC-A3) | Validate the report | 200, priority set |
| 3 | Individual Donor or guest | Support a report (UC-D2) | Pick the validated report, donate | 200 + QR code |
| 4 | CSWS Main Office | Handle physical donations (UC-CM1) | Receive with actual quantity; Inventory | 200 |
| 5 | CMO Representative | City donation confirmation (UC-C1) | Confirm the donation | 201 |
| 6 | CSWS Main Office | Release & delivery tracking (UC-CM2) | Prepare a delivery | 201, Preparing |
| 7 | CSWS Main Office | Logistics support requests (UC-CM2 3a) | Request transport for that delivery | 201 |
| 8 | DRRMO Logistics Support | Logistics support requests (UC-DR1) | Accept with a schedule | 200 |
| 9 | CSWS Main Office | Release & delivery tracking | Move to next status twice | In Transit, then Delivered |
| 10 | Barangay Receiving Rep | Receive & acknowledge aid (UC-B1) | Confirm receipt | 201, fulfillment updated |
| 11 | CSWS Disaster Unit | Needs monitoring (UC-CD2) | Load | shows fulfillment % |

The same chain is automated on the backend in `backend/app/tests/test_role_flows.py`
(`pytest` from `backend/app`).

## Before the real demo

- Remove the test-account chips and the prefilled password in `lib/account_tab.dart`.
- Tighten `allow_origins` in `backend/app/main.py` (it is `*` for development).
