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

## First: load the demo data into Neon

Run `database/seeds/demo_seed.sql` in the Neon SQL Editor once. It adds Sitio 1-10 for every
barangay, relief items with units (rice kg, water gallons, ...), one Barangay Receiving
Representative per barangay (`<barangay>.rep@example.com`), and sets `testpass123` on the
donor and organization test accounts. It is safe to run again.

## How the app works

1. **Login screen**: log in, tap a demo-account chip (one per role, password `testpass123`),
   or tap **Donate as guest**. You can also register a donor or an organization here.
   The gear icon (top right) changes the server address.
2. After login, the **menu depends on the role** (sidebar on wide screens, ☰ on phones).
   The look follows the Capstone 1 wireframes in the manuscript:

| Role | Menu |
|------|------|
| Individual Donor / Relief Organization / guest | Donate (validated reports → donate → QR code) |
| CSWS Disaster Unit | New report · Monitoring · Dashboard |
| Administrator | Reports (validate / reject / encode SMS) · Monitoring · Dashboard · Accounts |
| CSWS Main Office | Donations (receive, inventory) · Deliveries (prepare, request transport, update status) · Dashboard |
| CMO Representative | Confirmations |
| DRRMO Logistics Support | Requests (accept & schedule / decline) |
| Barangay Receiving Rep | Incoming aid (confirm receipt) · Monitoring · Dashboard |

3. **Profile → Developer tools** opens the original test console (raw API forms and the
   Checks tab that compares every endpoint against the expected status for the role).

## Full walk-through (follows the manuscript use cases)

Everything is done with buttons, dropdowns and dialogs; no ids are typed.

| # | Log in as | Module | Action | Expect |
|---|-----------|--------|--------|--------|
| 1 | CSWS Disaster Unit | New report (UC-CD1) | Fill in and submit | Pending |
| 2 | Administrator | Reports (UC-A3) | Tap Validate | Validated, priority set |
| 3 | Individual Donor or guest | Donate (UC-D2) | Tap Donate on the report | QR code |
| 4 | CSWS Main Office | Donations (UC-CM1) | Tap Receive, enter actual quantity | Inventory updated |
| 5 | CMO Representative | Confirmations (UC-C1) | Tap Confirm | Officially confirmed |
| 6 | CSWS Main Office | Deliveries (UC-CM2) | Tap Prepare delivery | Preparing |
| 7 | CSWS Main Office | Deliveries (UC-CM2 3a) | Tap Request transport | Sent to DRRMO |
| 8 | DRRMO Logistics Support | Requests (UC-DR1) | Tap Accept & schedule | Scheduled |
| 9 | CSWS Main Office | Deliveries | Tap Mark In Transit, then Mark Delivered | Delivered |
| 10 | Barangay Receiving Rep | Incoming aid (UC-B1) | Tap Confirm receipt | Fulfillment updated |
| 11 | CSWS Disaster Unit | Monitoring (UC-CD2) | Open | Progress bar, e.g. 50% |

The same chain is automated on the backend in `backend/app/tests/test_role_flows.py`
(`pytest` from `backend/app`).

## Before the real demo

- Remove the demo-account card in `lib/ui/login_screen.dart` and the test accounts in `lib/account_tab.dart`.
- Tighten `allow_origins` in `backend/app/main.py` (it is `*` for development).
