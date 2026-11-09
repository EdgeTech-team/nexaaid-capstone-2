# Multi-barangay disaster events (NF-003)

UAT post-meeting, Nov 2026: "When the disaster type is earthquake, all
barangays must be in." Team decision (Mariquit, Nov 9): **one form creates
the reports for several barangays**, and donors pick the barangay to help
with one tap.

## Rule: one barangay = one report

A multi-barangay submission saves **one `disaster_reports` row per
barangay**. Each report keeps its own affected families, sitios, needs,
validation (the Administrator validates each one, UC-A3), priority,
deliveries and fulfillment. The reports are grouped by a `disaster_events`
row through `disaster_reports.event_id`. A single-barangay report has
`event_id = NULL` and works exactly as before. SMS reports stay
single-barangay.

## Database (migration `e4f1a9c3b7d2`, revises `d9e3b7a1c5f2`)

**disaster_events**

| Column | Type | Nullable | Key | Default |
|---|---|---|---|---|
| event_id | INTEGER | NO | PK | auto-increment |
| event_name | VARCHAR(150) | NO | | |
| disaster_type_id | INTEGER | NO | FK → disaster_types, ON DELETE RESTRICT | |
| disaster_type_other | VARCHAR(100) | YES | | NULL |
| created_by_user_id | INTEGER | NO | FK → users, ON DELETE RESTRICT | |
| created_at | TIMESTAMPTZ | NO | | now() |

**disaster_reports.event_id**: INTEGER NULL, FK → disaster_events ON DELETE
SET NULL, index `ix_disaster_reports_event_id`.

ERD: disaster_events 1 — N disaster_reports.

The same migration adds the item **Kitchen Set** (category Kitchen, unit
sets), from the same UAT meeting.

## Report form (CSWS Disaster Unit)

- "One barangay" / "Several barangays" switch under the disaster type
  (new reports only; not SMS encoding or corrections).
- Several barangays: tap barangay chips, or **All barangays** (general
  types) / **All prone barangays** (location-specific types, NF-004). A
  non-prone barangay still asks "not tagged as prone… Continue?" and is
  never blocked.
- One "Families" field per picked barangay. Blank or 0 = skipped.
- The needs are entered once, **per family** (up to 2 decimals, e.g. 0.2 =
  1 per 5 families). The preset fills them from `need_templates`.
- Each barangay's amount = ceil(families × per family), worked out in the
  app; the server only receives whole numbers.
- A review dialog lists every barangay's totals; the button reads
  "Submit N reports". The event name defaults to "<Type> – <date>" and can
  be typed.

## API

- `POST /reports/batch` (CSWS Disaster Unit, like `POST /reports`):
  `{disaster_type_id, disaster_type_other?, description?, event_name?,
  source?, barangays: [{barangay_id, sitio_ids?, affected_families,
  needs: [{item_id | other_item_name + other_item_unit, quantity}]}]}`.
  2 to 27 barangays, no duplicates. All or nothing: a bad row saves nothing
  and the 422 names the barangay. Writes one audit row
  `SUBMIT DISASTER EVENT` (event_id + report_ids) and one
  "new report" notification per report, as before.
- `GET /reports/events/{event_id}`: public (guests too). Rows lowest
  fulfillment first, with `donatable` (Validated and under 100%) and the
  top 3 unmet needs (needed − pledged). A report not validated yet is a
  placeholder `{barangay, status: "Awaiting validation"}` for anyone who may
  not open it (`can_view_unvalidated_report`); withdrawn reports are left
  out for them. Barangay count, families, event % and priority come from
  **validated reports only**. Event % = the reports' official % weighted by
  affected families, computed on read (120/80/40 families at 100/25/0% →
  58.33%).
- `event_id` and `event_name` were added to the report responses and to
  `/lookups` `validated_reports`.

## Donor side

- Dashboard "Barangays that need help" and the newsfeed show an event as
  **one card** ("Earthquake – Nov 9, 2026 · 3 barangays · 240 families")
  with a yellow **Choose a barangay** button.
- The event page lists each barangay with its progress and a
  **Donate to <barangay>** button.
- The donate form has a **Donating to** selector to switch to another
  barangay of the same event. A donation still links to one report
  (`physical_donations.report_id`); the donations schema did not change.

## Not changed

Validation code, `priority_engine.py`, the fulfillment formula, the
donations backend.

## Known limitations and follow-ups

- Hiding Donate at 100% is app-only; the donations backend still accepts a
  donation to a fulfilled report (Hoyohoy, M4).
- No event link on the guest landing page yet; guests switch barangays with
  "Donating to" after tapping Donate (Fernandez, M9).
- One notification per report; one per event is a team decision after the
  Mandaue visit.
- Sitios: the multi form saves each barangay as the whole barangay; staff
  can add sitios to a report afterwards with the existing edit.
- Per-family amounts are the team's assumptions until CSWS gives its
  standards (`services/need_templates.py`).
