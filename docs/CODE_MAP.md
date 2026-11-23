# NexaAid code map: where each function lives

The backend and the mobile app use the **same feature names**, so "where is X?"
has the same answer on both sides.

- Backend (FastAPI, run from `backend/app`): every layer is split by feature.
  `api/v1/<feature>/` = HTTP endpoints, `services/<feature>/` = business rules,
  `core/<feature>/` = shared engines and helpers, `models/<feature>/` = database
  tables (SQLAlchemy), `schemas/<feature>/` = request and response shapes
  (Pydantic), `tests/<feature>/` = tests.
- Mobile (Flutter, `mobile/lib`): `core/` = API client and app plumbing,
  `features/<feature>/` = screens, `shared/` = reusable widgets and form helpers,
  `design/` = design system, `dev_tools/` = the developer/testing console.
- Unchanged: `backend/app/main.py` (starts the API), `alembic/` (migrations),
  `scripts/` (maintenance scripts), `mobile/lib/main.dart` (starts the app).

## Quick answers for the panel

| If they ask about... | Open this |
|---|---|
| **Rule-based AI priority** (how a report gets Low / Medium / High / Critical) | `backend/app/core/priority_ai/priority_engine.py` (`compute_priority`, `explain_priority`) |
| How fulfillment lowers the priority as goods arrive | `backend/app/services/deliveries/fulfillment.py` |
| Recomputing every report's priority | `backend/app/scripts/recompute_priorities.py` |
| **Door to Door pickup zoning** (which zone a donor is in) | `backend/app/services/pickup/pickup_zones.py` |
| Pickup service area / geofence by city | `backend/app/services/pickup/pickup_geofence.py` |
| Pickup route planning (cluster by zone, then shortest route) | `backend/app/services/pickup/pickup_planner.py` |
| Pickup endpoints used by CSWS | `backend/app/api/v1/pickup/pickup_plan_routes.py` |
| Pickup map, days, list and route screens | `mobile/lib/features/pickup/` (`pickup_map.dart`, `pickup_plan.dart`, `pickup_days.dart`, `pickup_route.dart`) |
| Login, tokens, roles (RBAC) | `backend/app/core/security/auth.py`, `backend/app/api/v1/accounts/session_router.py` |
| Registration and account approval | `backend/app/api/v1/accounts/auth_router.py`, `backend/app/api/v1/accounts/admin_router.py` |
| Disaster report submission (app and SMS) | `backend/app/api/v1/reports/reports.py`, `mobile/lib/features/reports/report_screens.dart`, `mobile/lib/features/reports/sms_send_screen.dart` |
| Donations and donation entries (QR reference) | `backend/app/api/v1/donations/donation_routes.py`, `backend/app/services/donations/donation_entries.py`, `mobile/lib/features/donations/donate_screen.dart` |
| Receiving goods and inventory | `backend/app/api/v1/receiving/receiving_routes.py`, `backend/app/services/receiving/inventory.py`, `mobile/lib/features/receiving/csws_screens.dart` |
| Deliveries, trips, DRRMO logistics | `backend/app/api/v1/deliveries/`, `backend/app/services/deliveries/`, `mobile/lib/features/deliveries/ops_screens.dart` |
| Notifications, push, live updates | `backend/app/core/notifications/`, `mobile/lib/core/push.dart`, `mobile/lib/core/realtime.dart` |
| Dashboards | `backend/app/api/v1/dashboard/dashboard_routes.py`, `mobile/lib/features/donations/donor_dashboard.dart`, `mobile/lib/features/accounts/admin_screens.dart` |
| Database connection and settings | `backend/app/core/config/database.py`, `backend/app/core/config/config.py` |
| Audit log | `backend/app/core/security/audit.py` |

## Feature by feature

### accounts: login, registration, passwords, profiles, admin account management
- API: `api/v1/accounts/` auth_router (register, verify email, reset password), session_router (login, /auth/me), account_router (own account), admin_router (manage users, approve registrations, audit logs), admin_document_routes (view uploaded IDs)
- Services: `services/accounts/accounts.py` (account deletion)
- Core: `core/security/` auth, passwords, temp_password; `core/common/` names, usernames, validators
- Models: `models/accounts/` user_rbac_model, role_model, organization_model, email_verification_model, password_reset_model, guest_donor_model
- Schemas: `schemas/accounts/` user_schema, organization_schema
- Mobile: `features/accounts/` login_screen, register_screen, forgot_password_screen, change_password_screen, verify_email_sheet, profile_screen, admin_screens, account_form, account_detail_screen, private_file_view

### reports: disaster reports, SMS reports, events, needs
- API: `api/v1/reports/reports.py`
- Services: `services/reports/` report_feed, report_paging, report_story, need_templates, disaster_events
- Models: `models/reports/` report, disaster_event_model, disaster_type_model
- Schemas: `schemas/reports/report.py`
- Mobile: `features/reports/` report_screens, report_filters, report_summary_card, paged_reports, multi_report, event_screen, hazard_barangay_field, sitio_picker, sms_send_screen, sms_report_format, sms_original, needs_action, needs_progress, disaster_art

### priority_ai: rule-based priority engine
- Core: `core/priority_ai/priority_engine.py`. Score = severity (affected families 4/7, disaster type 3/7) scaled by how much is still missing; thresholds map the score to Low / Medium / High / Critical; 100% delivered is always Low.
- Tests: `tests/priority_ai/`

### dashboard: dashboards and public landing stats
- API: `api/v1/dashboard/` dashboard_routes, public_routes
- Schemas: `schemas/dashboard/dashboard_schema.py`
- Mobile: landing page in `features/landing/`; role dashboards live with their feature (donor_dashboard in donations, admin dashboard in accounts)

### donations: pledges, donation entries, expiry, guest limits, items and units
- API: `api/v1/donations/` donation_routes, donation_info_routes, donation_lifecycle_routes (cancel / expire / reinstate), cmo_router (CMO confirms donations)
- Services: `services/donations/` donation_entries, donation_additions, donation_expiry, guest_limits, pledge_trust, entry_paging, items, item_quantities, units
- Models: `models/donations/` physical_donation_model, donation_info_model, donation_confirmation_model, item_model
- Schemas: `schemas/donations/` physical_donation_schema, donation_info_schema, donation_confirmation_schema
- Mobile: `features/donations/` donate_screen, donor_dashboard, donor_feed, donor_screens, my_giving, donation_info, donation_entries_view, paged_donation_entries, entry_report_views, records_screens, batch_sheet, cmo_screens, expiry_widgets, item_amounts, item_art, kit_contents, quantity_units, qr_save

### pickup: Door to Door pickup
- API: `api/v1/pickup/pickup_plan_routes.py`
- Services: `services/pickup/` pickup_zones (zoning), pickup_geofence (service area), pickup_planner (cluster first, route second), pickup_barangay, email_hold (pickups wait for a verified email)
- Mobile: `features/pickup/` pickup_map, pickup_plan, pickup_days, pickup_list, pickup_route, pickup_actions, location_picker

### receiving: receiving goods, inventory, proof of receipt
- API: `api/v1/receiving/receiving_routes.py`
- Services: `services/receiving/` receive_queue, inventory, handover, acknowledgment
- Models: `models/receiving/` received_goods_model, inventory_model
- Schemas: `schemas/receiving/received_goods_schema.py`
- Mobile: `features/receiving/` csws_screens (QR scanner and Receive screen), receive_filters, inventory_view, receipt_count_dialog, handover_code, acknowledgment_screen, signature_pad

### deliveries: logistics requests, deliveries, trips, shortfall
- API: `api/v1/deliveries/` deliveries, trips, delivery_problems, logistics_router, drrmo_router
- Services: `services/deliveries/` delivery_allocation, delivery_notices, delivery_reminders, delivery_stock, delivery_timing, delivery_views, logistics_stage, fulfillment, shortfall
- Models: `models/deliveries/` delivery, logistics_request_model
- Schemas: `schemas/deliveries/` delivery, logistics_request_schema
- Mobile: `features/deliveries/` ops_screens, delivery_widgets, logistics_cards, trip_screens, scheduled_deliveries, short_deliveries_screen

### notifications: in-app, push, live updates, email
- API: `api/v1/notifications/` notifications_router, push_router, realtime_router
- Core: `core/notifications/` notifications, push (Firebase), realtime (WebSocket), email (Brevo / SMTP)
- Models / schemas: `models/notifications/notification.py`, `schemas/notifications/notification.py`
- Mobile: `features/notifications/notifications_screen.dart`, `core/push.dart`, `core/realtime.dart`

### uploads: file uploads and storage
- API: `api/v1/uploads/upload_routes.py`
- Core: `core/uploads/` storage, uploads
- Models / schemas: `models/uploads/upload_model.py`, `schemas/uploads/upload_schema.py`
- Mobile: `features/uploads/upload_field.dart`

### locations: cities, barangays, sitios, hazards
- API: `api/v1/locations/` lookup_routes (barangay lookups), contacts (disaster unit and SMS receiver numbers)
- Models: `models/locations/` city_model, barangay_model, sitio_model, barangay_hazard_model

### config, security, common, system: shared foundations
- `core/config/` config (settings from .env), database (SQLAlchemy engine and session)
- `core/security/` auth, passwords, temp_password, client_ip, log_privacy, audit; `models/security/audit_log_model.py`
- `core/common/` validators, names, usernames, pagination
- `api/v1/system/health_routes.py` (health check)

### mobile app plumbing
- `lib/main.dart` app entry
- `lib/core/` api (HTTP client and roles), app_router and app_routes (navigation), app_navigator, push, realtime
- `lib/features/home/` home (bottom menu per role), home_nav
- `lib/shared/widgets/` widgets, paginated_list, blur_popup, copyable_phone, kept_views, theme_toggle
- `lib/shared/forms/` validators, input_formatters, form_draft
- `lib/design/` design system (tokens, theme, components)
- `lib/dev_tools/` developer console (dev_console, modules, checks_tab, account_tab, upload_demo_tab) and `dev_tools/legacy_reports/` (the first report list/detail screens, reachable only from the console)
