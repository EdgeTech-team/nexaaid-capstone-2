# NexaAid — Team Progress Log

## Castillo — Foundation (3.1 + 3.2)

**Status:** Done, merged to develop
**Last updated:** Sep 3, 2026

- Neon Postgres connected (pooled + direct URLs configured)
- Real schema discovered mid-build — DB already had full production tables,
  models rewritten to match (User: user_id/password_hash, normalized Role
  via role_id, not an enum) 
- Alembic baselined safely (schema-drop near-miss caught before running)
- core/auth.py: JWT login, password hashing, require_role() dependency
- /health, /health/secure, throwaway /token all tested working end-to-end
- Test admin: testadmin@gmail.com / testpass123 (role: admin) — usable by
  anyone needing a logged-in user before real registration exists

**For the team:** see note below on real column names + role table before
building anything that touches `users`.

---

## Castillo — Donation expiry, delivery filters, delivery trips (Oct 9)

**Status:** Built and tested on a branch, waiting for team review before merge
**Last updated:** Oct 9, 2026

Three additions to the spec, agreed by the team on Oct 9. None of them are
in the manuscript, so present them as improvements found during testing.

**1. Donations that never arrive now end (Expired / Cancelled).**
A pending donation used to stay Pending forever (manuscript 3.2 never closes
it). Now: Drop Off expires 14 days after it was submitted; Door to Door 7 days
after the preferred pickup time. Donors get a reminder 3 days before. Donors
can cancel while it is still waiting (guests prove it with their phone
number); CSWS can cancel for them, and can **Reopen** an expired one when
the donor arrives late (UC-CM1 alt 2a). Nothing is deleted: the row keeps
`closed_at`, `close_reason`, `closed_by_user_id` (NULL = the system).
Received goods and inventory are never touched.
- Rules: `services/donation_expiry.py`. Endpoints: `api/v1/donation_lifecycle_routes.py`
  (`GET /donations/expiry-rules`, `POST /donations/entries/{ref}/cancel`,
  `/reinstate`, `POST /donations/expiry/run`).
- No scheduler needed: pending lists and dashboards run the check when they
  load. Optional daily cron: `POST /donations/expiry/run` with header
  `X-Cron-Token: <DONATION_CRON_TOKEN>`.
- `.env` (optional): `DONATION_DROPOFF_DAYS=14`, `DONATION_PICKUP_GRACE_DAYS=7`,
  `DONATION_REMINDER_DAYS=3`, `DONATION_CRON_TOKEN=...`

**2. Deliveries screen: sorting, filtering, stock messages.**
`GET /deliveries/` gains `sort` (newest, oldest, date_soonest, date_latest,
status), `date_from`/`date_to`, `q` (barangay, item or delivery no.),
`trip_id`, and several statuses at once. Each delivery now carries readable
names (`destination_barangay_name`, `report_label`, `item_name`).
`GET /deliveries/counts` feeds the filter chips. Stock errors name the item:
"No more stock of Rice for this report." / "Only 50 kg of Rice left...".

**3. Trips: several reports on one truck.** (3 Banilad reports + 2 nearby
barangays in one go.) A trip groups ordinary deliveries; each still has one
report and one barangay, so stock per report, the barangay's own receipt
(UC-B1 alt 3a) and fulfillment per report work exactly as before.
Prepare (stock taken all-or-nothing) → Start → Arrived at each stop →
barangay confirms (one tap for all of theirs) → Completed automatically.
Undo is allowed only while still preparing (stock goes back).
No route optimisation (Limitation 6). Endpoints: `api/v1/trips.py`.
DRRMO transport requests are still per delivery; per-trip requests are a
later step (would make `logistics_requests.delivery_id` nullable).

**Schema (2 migrations, both additive, upgrade/downgrade tested on Postgres):**
- `5e1b8c3d9f20` physical_donations: statuses `Expired`, `Cancelled`; columns
  `expires_at`, `reminder_sent_at`, `closed_at`, `close_reason`,
  `closed_by_user_id`. Existing Pending rows get a deadline at least 7 days
  after the migration runs, so nothing expires on deploy day.
- `7a2c4e6b8d10` new table `delivery_trips`; deliveries get nullable
  `trip_id` and `stop_order`.

**Who should check what:**
- **Hoyohoy** (donations 3.5): `donation_routes.py` now sets `expires_at` on
  create and shows the deadline; entry/batch status knows Expired/Cancelled.
  `/donations/records` hides closed entries unless `status=` or
  `include_closed=true`. Run `test_donation_*`.
- **Mariquit** (deliveries 3.10): `create_delivery` stock check moved to
  `services/delivery_stock.py` (same 409, clearer message);
  `advance_delivery` logic moved into `move_to_next_status()` (trips reuse it);
  `_receive_line` explains how to reopen an expired donation. Run
  `test_deliveries.py`, `test_delivery_lines.py`, `test_delivery_trips.py`.
- **Fernandez** (dashboard 3.13): `/dashboard/csws-main` adds
  `due_soon_donations`, `expired_donations`, `cancelled_donations` (existing
  fields unchanged). New statuses `Expired` and `Completed` have colors in
  `design/status.dart`.

**Test before merging:** `pytest` (new: `test_donation_expiry.py`,
`test_delivery_trips.py`), `TEST_POSTGRES_URL=... pytest
tests/test_models_match_migrations.py`, then `flutter analyze` (could not be
run in my environment). Migrations go to Neon only after review.

---

## Hoyohoy — Auth/Registration (3.3)

**Status:** Done
**Last updated:** Sep 6, 2026

- Donor self-registration, organization self-registration (starts "Pending"
  until an admin approves it), and admin-created internal staff accounts
  (CSWS, CMO, DRRMO, Barangay Rep) — all built on Castillo's
  password-hashing/`require_role()` foundation
- New: `api/v1/auth_router.py` (registration endpoints), `api/v1/admin_router.py`
  (admin-created accounts), `schemas/organization_schema.py`, `schemas/user_schema.py`
- Modified: `models/organization_model.py`, `models/user_rbac_model.py` to
  support the new registration fields
- Removed the old `api/v1/router.py` — routes now split across the new
  router files, so double-check everything is re-wired before merging
- Resolved environment issues (missing `python-jose`, wiped venv, stale DB
  password, missing `SECRET_KEY`) and confirmed registration/RBAC running
  end-to-end (200 OK)

**Note for the team:** touched `models/user_rbac_model.py`, which Ivan's
dashboard/report work also modified — diff this file carefully before merging.

---

---

## Mariquit — Module 2 (3.4, 3.11, 3.12) + Module 4 (3.7) + Module 6 (3.10)

### Done & tested (12/12 pytest passing)

- **3.4 Report Management**: full CRUD on disaster_reports, admin validate/reject
  with audit trail (validated_by, rejection_reason), SMS report ingestion
  (sms_report_metadata). Migrations applied to real Neon DB.
- **3.10 Delivery Tracking & Receipt Confirmation**: deliveries move through
  sequential statuses (Preparing → In Transit → Delivered), barangay confirms
  receipt (receipts table), which auto-recalculates the linked report's
  fulfillment_percentage/verification_status (report_fulfillments).
- Extended validate_report (3.4) to auto-create a report_fulfillments row,
  since 3.10/3.11 both depend on it existing.

- **3.7 Needs Monitoring**: added priority_level filter to GET /reports/,
  plus new GET /reports/monitoring endpoint joining disaster_reports with
  report_fulfillments (joinedload, avoids N+1) — returns fulfillment
  status/percentage/items alongside each report for staff/admin/barangay
  official roles.
- **3.11 AI-Assisted Priority Level Assignment**: rule-based scoring
  (core/priority_engine.py) triggered on report validation — factors in
  affected_families, estimated_quantity, disaster type severity, and
  current fulfillment status. Handles the manuscript's alt flows:
  insufficient data → "Needs Review", missing fulfillment record →
  scored as max unmet need, out-of-range score → "Review Required"
  safety fallback. Scoring weights/thresholds are a team-agreed rule,
  not manuscript-specified (manuscript intentionally leaves the formula
  open — see UC spec p.93-94).
### Still open / needs team input

- DisasterType stub currently only has 1 real row ("Flood") in the actual
  Neon DB — Typhoon/Fire/Earthquake severities in priority_engine.py's
  DISASTER_SEVERITY map are unreachable until whoever owns reference
  tables actually seeds those rows.
- Found a real mismatch: models/report.py's DisasterType stub maps the
  column as `name`, but the actual Postgres column is `type_name` — hasn't
  broken anything yet since nothing reads it, but will the moment code
  (like priority_engine.py) starts using report.disaster_type.name.
  Flagging for whoever owns reference/lookup tables.
  
## Fernandez — Dashboard (3.13)

**Status:** In progress — core endpoints built, pending final verification
**Last updated:** Sep 6, 2026

- Read-only aggregation endpoints added: `/dashboard/summary`, `/reports`,
  `/donations`, `/fulfillment`, `/logistics`
- New minimal models added for tables nobody else had modeled yet:
  physical_donations, donation_confirmations, inventory, deliveries,
  logistics_requests, report_fulfillments (all use `extend_existing=True`
  as a safety net — if Hoyohoy/others build canonical models for these
  tables, swap to their import instead of mine, same way I did for
  DisasterReport)
- Reused real `DisasterReport` model from `models/report.py` — did NOT
  duplicate it
- Protected with `require_role("admin", "csws_staff", "barangay_official")`
  — matches the confirmed role strings used in reports.py
- No writes, no schema changes, no new dependencies

**Blocked on / needs team input:**

- reports.py has an "ASSUMPTION TO VERIFY" comment about role names — if
  that gets corrected, my `DASHBOARD_ROLES` tuple needs the same fix
- CMO and DRRMO role name strings are still unconfirmed (not found
  anywhere in the codebase yet) — dashboard currently doesn't grant them
  access since I don't want to guess wrong; easy one-line fix once
  someone confirms the real values from the `roles` table

**Still to do:**

- Run `uvicorn main:app --reload` and test all 5 endpoints against the
  test admin account
- Confirm empty-table case doesn't error (should return zeros)

---

## Fernandez — UI/UX lead: Sprint 0 design system + app shell, Item 8 landing page

**Status:** Ready for review (branch `feat/0-design-system`)
**Last updated:** Oct 1, 2026

- **Design system** in `mobile/lib/design/`: light and dark themes, Lexend +
  Source Sans 3 type, 8-pt spacing, radius scale, one fixed color per status
  and priority, and components (`AppButton`, `AppTextField` with password eye
  toggle, `AppCard`, `StatCard`, `StatusChip`, `PriorityChip`,
  `FulfillmentBar`, `StatusTimeline`, skeletons, `EmptyView`, `ErrorView`).
  Rules: `docs/design/DESIGN_SYSTEM.md`.
- **Everyone's screens restyled for free:** `ui/widgets.dart` now draws the
  old `Badge2`, `StatTile`, `Progress`, `EmptyState`, `PageHeader` and
  `Loader` with the new components, and re-exports the design system.
  No screen code changed.
- **App shell:** new app bar, bottom bar on phones and side rail on
  tablets/Chrome, Appearance setting (System / Light / Dark) in Profile,
  `_shellActions` slot in `ui/home.dart` for the notification bell.
- **Component gallery:** Profile > Developer tools > Design system gallery,
  with dark-mode and 100/130/200% text switches.
- **Landing page (Item 8)** in `ui/landing/`: shown when signed out. Hero
  with the most urgent report, live stats, how it works, report feed with
  priority filter, Donate as guest / Log in / Create account.
- **Team tooling:** `docs/setup/EMULATOR.md`, `.github/pull_request_template.md`
  (UI review gate checklist).
- Tests: `test/design_system_test.dart`; `test/widget_test.dart` updated for
  the landing page.

**For Mariquit (Item 8 data):** the landing page already calls
`GET /public/reports` and `GET /public/stats` and falls back to
`/lookups` while they return 404. Shapes it expects:
- `/public/reports`: list of validated reports with the same keys as
  `/lookups` `validated_reports` (`id` or `report_id`, `disaster`,
  `barangay`, `sitio`, `priority_level`, `assistance_needed`,
  `affected_families`, `description`, `total_items_needed`,
  `total_items_delivered`, `fulfillment_percentage`). No reporter info.
- `/public/stats`: `{active_reports, families_affected, urgent_reports,
  barangays, donations_received, deliveries_completed}`. Any missing key
  is computed from the reports instead.

**For Mariquit (privacy):** `/lookups` is public and its
`pending_donations` / `received_donations` include QR references. Worth
moving those lists behind auth when you build `/public/*`.

**For everyone:** when you restyle your screens, replace `Brand.ink` /
`Brand.muted` with `colorScheme.onSurface` / `onSurfaceVariant` so they
work in dark mode.

**Next:** Item 10 donor/org dashboards (stat cards, `StatusTimeline` per
donation, supported-report progress, optional self-declared financial log),
then Module 8 delivery screens.
