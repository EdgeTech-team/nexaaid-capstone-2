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

Run `database/seeds/demo_seed.sql` in the Neon SQL Editor. It is safe to run again. It adds:
Sitio 1-10 per barangay, relief items with units, 11 disaster types, one Barangay Receiving
Representative per barangay (`<barangay>.rep@example.com`), the `audit_logs` table (if
missing), approves the test organization, and sets `testpass123` on the donor and
organization test accounts.

## Menus per role (bottom bar)

| Role | Menu | Manuscript |
|------|------|------------|
| Guest | Donate | 1.4, UC-D2 |
| Individual Donor / Relief Organization | Dashboard · Donate | UC-D2-D4, UC-R2-R4, 7.3 |
| Administrator | Overview (activity log) · Reports · Accounts (users, organizations, new account) · Monitoring | UC-A1-A4, 7.7 |
| CSWS Disaster Unit | Overview · New report · Monitoring | UC-CD1, UC-CD2, 7.2 |
| CSWS Main Office | Overview · Receive (scan QR / search, inventory per report) · Deliveries | UC-CM1-CM3, 7.1 |
| CMO Representative | Confirmations (confirm / hold / review / revert, summary per report) | UC-C1, UC-C2, 7.4 |
| DRRMO Logistics Support | Logistics (new / scheduled / in transit / completed) | UC-DR1, UC-DR2, 7.5 |
| Barangay Receiving Rep | Incoming aid (confirm receipt, acknowledge, history) · Overview | UC-B1, UC-B2, 7.6 |

Profile → Developer tools opens the original test console.

## Full walk-through

| # | Log in as | Do | Expect |
|---|-----------|----|--------|
| 1 | new organization | Register organization, then try to log in | "registration is Pending" |
| 2 | Administrator | Accounts → Organizations → Approve | organization can log in |
| 3 | CSWS Disaster Unit | New report: type, barangay, sitio, needs | Pending |
| 4 | Administrator | Reports → Validate | Validated, priority set |
| 5 | Donor or guest | Donate → Donate → items → Submit | QR code per item |
| 6 | CSWS Main Office | Receive → Scan QR code (or type it) → Receive goods, actual quantity | stock under the report |
| 7 | CMO Representative | Hold, then Confirm (Revert undoes it) | Officially confirmed |
| 8 | CSWS Main Office | Deliveries → Prepare delivery (only in-stock items) → Request transport | stock goes down |
| 9 | DRRMO | Accept & schedule | Scheduled |
| 10 | CSWS Main Office | Mark In Transit, Mark Delivered | DRRMO sees In transit |
| 11 | DRRMO | In transit → Mark completed with a summary | Completed |
| 12 | `<barangay>.rep@example.com` | Incoming aid → Confirm receipt → Acknowledge → History | fulfillment updated |
| 13 | any office role | Overview | role dashboard; Admin sees the activity log |

The same chains are automated in `backend/app/tests/` (`pytest` from `backend/app`).

## Before the real demo

- Remove the demo-account card in `lib/ui/login_screen.dart` and the test accounts in `lib/account_tab.dart`.
- Replace the placeholder drop-off address in `lib/ui/donor_screens.dart` (`storageAddress`).
- Tighten `allow_origins` and remove the dev error middleware in `backend/app/main.py`.
