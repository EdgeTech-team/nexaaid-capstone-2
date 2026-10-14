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

## Menus per role (bottom bar), following Appendix H (List of Modules)

| Role | Menu | Appendix H |
|------|------|------------|
| Guest | Donate | 4.2 |
| Individual Donor / Relief Organization | Dashboard · Donate (validated reports with priority filter) | 1.1, 2.4, 3.2, 3.3, Module 4, 9.4 |
| Administrator | Overview · Validate (pending / validated with priority filter / rejected) · Monitoring · Records (donations, per report, deliveries, logistics) · Accounts | 1.2, 1.3, 2.3-2.5, 3.1-3.3, 4.4, 4.5, 6.3, 7.5, 8.5, 9.1 |
| CSWS Disaster Unit | Overview · New report (field report or **SMS report**) · Reports (validated / status, priority filter) | 2.1, 2.2, 2.4, 2.5, 3.3, 9.3 |
| CSWS Main Office | Overview · Reports (validated / status, priority filter) · Receive (scan QR, inventory, all donation records) · Deliveries (logistics support records) | 2.4, 2.5, 3.3, 4.4, Module 5, 7.1, 7.5, 8.1, 9.2 |
| CMO Representative | Confirmations · Reports | Module 6, 2.4, 9.5 |
| DRRMO Logistics Support | Logistics · Deliveries (view only) · Reports (no priority, per 3.2) | Module 7, 8.5, 2.4, 9.6 |
| Barangay Receiving Rep | Incoming aid · Overview · Reports | 8.2-8.5, 2.4, 9.7 |

Profile → Developer tools opens the original test console.

## Full walk-through

| # | Log in as | Do | Expect |
|---|-----------|----|--------|
| 1 | new organization | Register organization, then try to log in | "registration is Pending" |
| 2 | Administrator | Accounts → Organizations → Approve | organization can log in |
| 3 | CSWS Disaster Unit | New report: type, barangay, sitio, needs (or switch to SMS report) | Pending |
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
