# Donor-side security (Dave Hoyohoy, tasks D1 to D8)

Brief: *NexaAid Task Brief, Dave Hoyohoy, November 18, 2026*. One branch,
`feat/dave-d1-d8-donor-security`, based on `copy-develop`; the pull request
targets `copy-develop`.

Reviews before merging: **Castillo** (Module 1) reviews D4 and D6.
**Fernandez** reviews the D8 dashboard screens (Module 9). **Jenises**
reviews D3 (J6 uses `pledge_is_verified`).

## Gap Log rows

| ID | Type | Description | Manuscript ref | Module | Owner | Status |
|---|---|---|---|---|---|---|
| NF-004 | NEW FEATURE | Guests limited to Drop Off (setting GUEST_DOOR_TO_DOOR=blocked; "limited" allows one pickup per number) | Scope, UC-D2 | M4 | Hoyohoy | Open |
| NF-005 | NEW FEATURE | Guest donation limits | UC-D2, business rules | M4 | Hoyohoy | Open |
| NF-006 | NEW FEATURE | Verify account email once (Door to Door) | UC-D2, data dict., Fig. 55 | M4 (M1) | Hoyohoy | Open |
| NF-007 | NEW FEATURE | Call to confirm each pickup stop | Pickup run UC, data dict., Fig. 55 | M7 | Hoyohoy | Open |
| NF-008 | NEW FEATURE | Organization categories and verification states | UC-A2, data dict., Fig. 55 | M1 | Hoyohoy (Castillo) | Open |
| NF-011 | NEW FEATURE | Verified pledges (D3, with J6) | Business rules | M4 | Hoyohoy / Mariquit | Open |
| G-002 | MISSING IN APP | Packaging and quantities on all item views | Dashboard views | M4/M6/M7/M9 | Hoyohoy | Open |
| G-003 | MISSING IN APP | My Giving fails to load | Donor dashboard | M4 | Hoyohoy | Open |

## Business rules (manuscript drafts)

**Guest donations (NF-004, NF-005).** A guest may donate without an account
by Drop Off. Door to Door is for registered donors ("For the safety of our
pickup team, Door to Door is for registered donors. Sign in or register, or
choose Drop Off."), so every pickup address belongs to an account with a
verified email, and every stop is confirmed by phone before a run. The app
shows Door to Door locked for guests with "Register (takes 2 minutes)" and
"Sign in", and the guest's donation is kept and reopened after signing in.
The setting `GUEST_DOOR_TO_DOOR` (blocked by default) can be switched to
`limited`, which lets guests have one Door to Door pickup waiting per number,
without a code change. A guest phone number may
have at most `GUEST_MAX_OPEN_ENTRIES` (2) Pending entries; one connection may
send at most `GUEST_MAX_PER_IP_HOUR` (5) guest donations an hour; the same
number cannot pledge the same item to the same report twice within 24 hours;
each guest item line is capped at `GUEST_MAX_LINE_QTY` base units ("For large
donations please sign in."). A filled-in hidden field is treated as a bot: the
answer looks successful and nothing is saved. Guest donations notify only
CSWS Main Office, at most one notice per 10 minutes per person ("3 new guest
donations"). None of this applies to logged-in donors.

**Verified pledge (NF-011).** A pledge is verified when CSWS has received it,
or when it comes from a logged-in account whose email is verified. CSWS
pending lists show "Guest – not yet received" or "Email not verified".

**Email verification (NF-006).** Registration signs in at once. The account
email is verified once, with a 6-digit code (stored hashed, valid 15 minutes,
5 wrong tries, at most 5 codes an hour). A Door to Door donation from an
unverified account is saved but stays off the CSWS pickup list, planner and
map, cannot join a pickup run, and expires after 48 hours with the reason
"Email not verified". When the email is verified, the donor's waiting Door to
Door donations appear on the map and their handover deadline counts from
that moment. Drop Off never needs verification.

**Pickup confirmation call (NF-007).** Before a pickup run is sent to DRRMO,
CSWS Main Office (or DRRMO) calls every stop and records Reached, No answer
or Wrong number. A run with a stop that is not Reached is refused, listing the
stops still to call. Wrong number cancels the donation ("Contact number not
reachable"). A second No answer in a row moves the stop to the donor's next
available date. A new pickup date or address needs a new call.

**Organizations (NF-008).** The organization type is chosen from a fixed list
in two categories. Government: Barangay / Barangay Council; City or Municipal
Government Office; National Government Agency; Public School or State
University; Government-Owned or Controlled Corporation. Non-government:
Non-Profit / NGO / Foundation; Religious Organization; Private Company or
Business; Private School or University; Civic or Community Group; Other
(specify). Every organization uploads the contact person's government ID;
Government types also upload one supporting document (authorization or
endorsement letter on office letterhead, or the contact person's office ID).
For Non-government types the document stays optional. **This tightens the
earlier adviser rule (document optional for every type): tell the adviser.**
States: Unverified (after registering; can sign in and donate), Verified
(Administrator reviewed it; Verified badge to CSWS and on the dashboard),
Deactivated (fake or wrong documents; reason required and emailed).

**Packaging and quantities (G-002).** Every user who can see a donated item
sees its packaging, its readable amount ("10 packs x 5 kg"), and the
quantities that exist: declared by the donor, counted by CSWS, received by
the barangay.

## Data dictionary rows

| Table.column | Type | Null | Description |
|---|---|---|---|
| users.email_verified_at | TIMESTAMPTZ | NULL | When the user confirmed their email with a code. NULL = not verified. |
| email_verification_codes.code_id | SERIAL | NOT NULL, PK | Code row. |
| email_verification_codes.user_id | INT | NOT NULL, FK users ON DELETE CASCADE | Account the code was sent to. |
| email_verification_codes.code_hash | VARCHAR(64) | NOT NULL | HMAC-SHA256 of the 6-digit code (never stored in plain text). |
| email_verification_codes.expires_at | TIMESTAMPTZ | NOT NULL | 15 minutes after it was sent. |
| email_verification_codes.used_at | TIMESTAMPTZ | NULL | When it was used or replaced by a newer code. |
| email_verification_codes.attempts | INT | NOT NULL, default 0 | Wrong tries (5 = locked). |
| email_verification_codes.created_at | TIMESTAMPTZ | NOT NULL | When it was sent. |
| physical_donations.contact_confirmed_at | TIMESTAMPTZ | NULL | When staff called the donor to confirm the pickup stop. |
| physical_donations.contact_confirmed_by_user_id | INT | NULL, FK users | Who called. |
| physical_donations.contact_outcome | VARCHAR(20) | NULL | Reached / No answer / Wrong number. |
| organizations.organization_category | VARCHAR(20) | NOT NULL | Government or Non-government, set from the organization type. Existing rows backfilled from their type (unknown = Non-government). |

## Figure 55 (ERD) changes

- **users**: add `email_verified_at`.
- **email_verification_codes** (new): `code_id` PK, `user_id` FK → users
  (one user has many codes), `code_hash`, `expires_at`, `used_at`,
  `attempts`, `created_at`. Same shape as `password_reset_tokens`.
- **physical_donations**: add `contact_confirmed_at`,
  `contact_confirmed_by_user_id` (FK → users), `contact_outcome`.
- **organizations**: add `organization_category`.

## Migrations (one head)

`e2a7c4d9f5b1` → `b3d9e1f4a7c2` (D4) → `c8f2a5d1e9b4` (D5) →
`d4a7b2e8c6f1` (D6). Run `alembic heads` after pulling `copy-develop`; if
Jenises's J1 migration also revises `e2a7c4d9f5b1`, whoever merges second
adds a merge migration.

Backfill notes:
- D4 marks staff accounts verified, **and** donor/organization accounts that
  already have a Door to Door donation waiting, so pickups on the CSWS map
  today don't vanish or expire on deploy. Everyone else verifies once.
- D6 sets `organization_category` from each row's type.

## D8 audit: every screen and API response that lists donated or delivered items

| Who sees it | Screen (app) | API response | Before | Now |
|---|---|---|---|---|
| Donor, Organization | My giving cards, donation details | `GET /donations/mine/entries`, `/donations/mine` | quantity, unit, packaging, CSWS count | + amount_text, declared, counted, barangay received |
| Donor | Receipt after donating, Edit donation | `POST /donations/batch`, `PUT /entries/{ref}` | amount_text, packaging | + declared, counted, barangay received |
| CSWS Main Office | Scan QR / receive | `GET /donations/by-batch/{ref}`, `/donations/by-qr/{qr}` | packaging, CSWS count | + amount_text, quantity summary |
| CSWS, CMO, Barangay | Records / receive queue / per report | `GET /donations/records`, `/donations/receive-queue`, `/records/per-report` | quantity, packaging | + amount_text, declared, counted, barangay received |
| CSWS Main Office | Pickup board | `GET /donations/pickups` | "2 kg Rice" (no packaging) | "Rice: 10 packs x 5 kg (Sack)" |
| CSWS Main Office | Pickup map / list / stop sheet | `GET /donations/pickup-plan` | quantity, packaging | + amount_text, quantity summary |
| DRRMO | Pickup runs and requests | `GET /drrmo/requests` (goods) | "2 kg Rice" | "Rice: 10 packs x 5 kg (Sack)" |
| CMO Representative | Review / acknowledge | `GET /cmo/donations/*`, `/cmo/entries/*` | quantity, packaging | + amount_text, declared, counted |
| CSWS, Barangay, DRRMO, Donor | Deliveries, trips, scheduled deliveries | `core/m8_delivery_tracking/delivery_views.py` | quantity, unit | + amount_text, barangay received |
| CSWS Main Office, Barangay | Dashboards (donation entries, latest donations) | `GET /dashboard/csws-main`, `/dashboard/barangay` | quantity (+ packaging on CSWS) | + amount_text, packaging on both |
| Administrator | Transparency dashboard | `GET /dashboard/summary` | counts only | + Verified organizations (D6) |

**Barangay received (J1).** `receipt_items.received_quantity` does not exist
on this branch yet. Every response already carries
`barangay_received_quantity` (null for now) and the app shows it when it is
set. After J1 is merged, fill `core/reference_data/item_quantities.barangay_received` and
`delivery_received` (one place each); no screen needs to change.

## G-003 (My Giving won't load): investigation

Reproduced with a donor and an organization that have Pending, Partly
Received, Received, Expired and Cancelled entries, removed items, items
added later, a Door to Door pickup and a typed-in item:

- Backend (SQLite): `/donations/mine/entries` (every sort, status, view and
  search) and `/counts` answer 200 in about 40 ms, about 30 queries each.
- App: the real server JSON from that history, fed into `MyGivingScreen` and
  every `DonationDetailScreen`, renders without an exception.

**No root cause was found in this setup**, so no speculative fix was made.
Regression tests keep it covered (`tests/m9_dashboards/test_my_giving_loads.py`,
`mobile/test/m9_dashboards/my_giving_real_data_test.dart`). To finish: run the backend
tests against a local Postgres (`TEST_POSTGRES_URL`) and send the Render log
line or the app's error text from the failing account.

## Test steps (manual)

1. **Guests** Signed out, Donate: Door to Door shows locked with "Register
   (takes 2 minutes)" and "Sign in". Tap Register, finish registering: the
   same donation reopens filled in, with Door to Door chosen. A guest
   Door to Door sent to the API answers 422 with the reason.
2. **D2** As a guest with one number: a 3rd Pending donation answers 429; the
   same item to the same report again answers 409; 101 kg on a line answers
   422 ("For large donations please sign in."). CSWS Main Office sees one
   notice "N new guest donations", not one per donation.
3. **D3** CSWS records / receive queue: a guest entry shows
   "Guest – not yet received" until it is received.
4. **D4** Register a donor, donate Door to Door: the receipt says "Check your
   email. Enter the code to send this pickup to CSWS."; CSWS's pickup map
   doesn't show it. Enter the code: it appears; the dashboard banner is gone.
5. **D5** CSWS pickup map, a stop: the donor's number, call buttons and
   "Called – confirmed? (required)". Request DRRMO support for a day: the
   sheet lists the stops still to call and Send is disabled. Tap Reached on
   each: Send works. Wrong number cancels the donation; No answer twice
   moves the stop.
6. **D6** Register an organization as Barangay / Barangay Council without a
   document: refused. As Religious Organization without a document: works
   (ID still required). Administrator > Registrations: Government first with
   "Government type – check document and ID"; Mark verified; Deactivate asks
   for a reason and emails it. The dashboard shows Verified organizations.
7. **D7** My giving > a donation > Edit donation: the form opens filled in
   with "+ Add item"; one Save changes sends the edited lines and the new
   ones. The drop-off card says CSWS Main Office.
8. **D8** Every list above shows "Rice · 10 packs x 5 kg" and
   "Sack · Declared 50 kg · Counted 48 kg".

## Project instructions (Section F)

- Remove: "Hold changes to the disaster-unit report validation workflow
  until after the Mandaue process visit".
- Add: "Guests can donate by Drop Off only" (matches agreement A9). The
  `GUEST_DOOR_TO_DOOR=limited` setting exists if the team later allows one
  guest pickup per number.

## Notification wording

Report notifications describe the need instead of "Report #21 is now
accepting donations" (`core/notifications/report_story.py`), e.g.
"Flood in Barangay Looc: families need your help" /
"35 families in Barangay Looc were affected by a flood. They need rice,
drinking water and 2 more items. High priority. Tap to see what they need
and donate." Staff messages keep the report number in the body.
