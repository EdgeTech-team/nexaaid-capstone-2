# Folder structure: one folder per function

NexaAid's code is grouped by **function** (the modules in Appendix H, List of
Modules), not by technical layer. Everything one module needs (its routes, its
business rules, its database tables, its request and response shapes) sits in
one folder, so the person who owns a module finds all of it in one place.

The pattern is the same on the backend and in the mobile app:

```
backend/app/core/<function folder>/<files for that function>
mobile/lib/core/<function folder>/<files for that function>
backend/app/tests/<function folder>/test_<...>.py
mobile/test/<function folder>/<...>_test.dart
```

For example, everything about City Confirmation (Module 6, CMO) is in
`backend/app/core/m6_city_confirmation/`, its screens are in
`mobile/lib/core/m6_city_confirmation/`, and its tests are in
`backend/app/tests/m6_city_confirmation/` and `mobile/test/m6_city_confirmation/`.

Every file that moved, old path to new path, is listed in
[docs/RESTRUCTURE_CHANGELOG.md](../RESTRUCTURE_CHANGELOG.md).

## The function folders

The `mN_` number is the module number in Appendix H, so the folder list reads in
the same order as the manuscript.

| Folder | Appendix H module | Programmer | What is inside |
|---|---|---|---|
| `m1_user_management` | Module 1: User Management and Role-Based Access | Castillo | Registration, login and sessions, internal accounts, organization review, roles, passwords, usernames |
| `m2_disaster_reporting` | Module 2: Disaster Reporting and Monitoring | Mariquit | Post-disaster reports, SMS reporting, validation, report lists and feeds, multi-barangay events, suggested needs |
| `m3_priority_guidance` | Module 3: AI-Assisted Priority Guidance | Castillo | The priority engine |
| `m4_donation_management` | Module 4: Donation Management | Hoyohoy | Physical donation entries, guest donations, QR references, donation records and status, expiry and cancellation, barangay donation info |
| `m5_inventory` | Module 5: Inventory and Goods Management (CSWS) | Mariquit | Receiving goods, stored inventory per report, preparing goods for a delivery, Door to Door pickup planning |
| `m6_city_confirmation` | Module 6: City Confirmation (CMO) | Hoyohoy | CMO confirm or hold, donation summaries per report |
| `m7_logistics_support` | Module 7: Logistics Support Coordination (DRRMO) | Hoyohoy | Logistics support requests, DRRMO accept, decline and schedule, delivery reminders |
| `m8_delivery_tracking` | Module 8: Delivery Tracking and Receipt Confirmation | Fernandez | Deliveries and trips, delivery problems, handover code, receipts and acknowledgment, shortfall review, per-item fulfillment |
| `m9_dashboards` | Module 9: Role-Based Transparency Dashboard | Fernandez | Role dashboards (Admin, CSWS, DRRMO, donor), CSWS overview pages, response times, public landing summaries |

Three folders hold code that several modules use:

| Folder | What is inside |
|---|---|
| `shared` | Plumbing every module needs: settings (`config.py`), the database session (`database.py`), audit log, email, uploads and file storage, pagination, field validators, client IP and log privacy, health check. In the mobile app: the API client, router, theme, design system (`shared/design/`), common widgets, home navigation, and developer tools (`shared/dev_tools/`). |
| `notifications` | In-app notifications, Android push, live updates over WebSocket, and the readable report wording used in notices. |
| `reference_data` | Lookup data used by every form: cities, barangays, sitios, hazards, disaster types, the item catalog, units and packaging. (Backend only. The mobile app reads these through `shared/api.dart`.) |

There is no `m3_priority_guidance` folder in the mobile app, because the app only
shows the priority that the backend computes. It has no screens of its own.

## Backend: how files are named inside a folder

Each function folder is flat (no sub-folders). The file name tells you its job:

| Kind of file | Name ends in | Example |
|---|---|---|
| FastAPI router (endpoints) | `_routes.py` or `_router.py` (a few older ones are plural nouns: `reports.py`, `deliveries.py`, `trips.py`) | `m6_city_confirmation/cmo_router.py` |
| SQLAlchemy table | `_model.py` | `m4_donation_management/physical_donation_model.py` |
| Pydantic request and response shapes | `_schema.py` | `m8_delivery_tracking/delivery_schema.py` |
| Business rules and queries | a plain name | `m5_inventory/inventory.py`, `m8_delivery_tracking/handover.py` |

Imports use the full path from `backend/app`:

```python
from core.shared.database import get_db
from core.m1_user_management.auth import require_role
from core.m2_disaster_reporting.report_model import DisasterReport
from core.m8_delivery_tracking import handover
```

`backend/app/main.py` (the app entry point), `alembic/` (migrations),
`scripts/` (one-off command line tools) and `pytest.ini` stay where they were.
Run the server and tests from `backend/app` exactly as before.

## Mobile: how files are named inside a folder

Screens and widgets keep their names (`cmo_screens.dart`, `login_screen.dart`,
`delivery_widgets.dart`). `lib/main.dart` stays at the top of `lib/`. Imports
use the package path or a relative path, both work:

```dart
import 'package:mobile/core/shared/api.dart';
import 'package:mobile/core/m1_user_management/login_screen.dart';
import '../shared/widgets.dart';
```

## Where to put a new file

1. Find the Appendix H module the feature belongs to, and put the file in that
   module's folder. A new CMO endpoint goes in `backend/app/core/m6_city_confirmation/`,
   a new donor screen in `mobile/lib/core/m4_donation_management/`.
2. If two or more modules will use it and it is not owned by any one of them,
   put it in `shared/` (plumbing), `notifications/` or `reference_data/`.
3. Name backend files with the endings in the table above, so a router, a table
   and a schema for the same thing never get the same file name.
4. Put the test in the matching folder under `backend/app/tests/` or `mobile/test/`.
   Tests that walk through several modules at once (run-throughs, defense fixes,
   date-named fix batches) go in `cross_module/`.
5. A new model must also be imported in `backend/app/alembic/env.py` so
   `alembic revision --autogenerate` sees it.

## Files that serve more than one module

Some files help more than one module. They live with the module that owns the
main use case:

| File | Folder | Why there |
|---|---|---|
| `pickup_planner.py`, `pickup_zones.py`, `pickup_geofence.py`, `pickup_barangay.py`, `pickup_plan_routes.py` | `m5_inventory` | Door to Door pickups are how CSWS Main Office collects goods before receiving them (UC-CM1). |
| `delivery_allocation.py`, `delivery_stock.py` | `m5_inventory` | Taking goods out of inventory for a delivery is Module 5.4, Prepare Goods for Distribution. |
| `delivery_reminders.py` | `m7_logistics_support` | Reminders for the CSWS and DRRMO hand-off. |
| `fulfillment.py` | `m8_delivery_tracking` | Module 8.4, Update Fulfillment Progress. |
| `delivery_timing.py`, `needs_action.dart` | `m9_dashboards` | Response times shown on the dashboards. |
| `email_hold.py` | `m4_donation_management` | Holds Door to Door donations until the donor's email is verified. |
| `ops_screens.dart` | `mobile/.../m7_logistics_support` | Holds the DRRMO screen and the delivery stepper it uses. |
