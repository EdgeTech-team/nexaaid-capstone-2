# Folder restructure change log

Branch `claude/project-thread-22rg65`, based on `copy-develop` (Nov 24, 2026).

This change moves files only. No endpoint, screen, database table, migration or
behaviour changed. The layout and the rules for new files are explained in
[docs/architecture/FOLDER_STRUCTURE.md](architecture/FOLDER_STRUCTURE.md).

## Summary

| Area | Files moved |
|---|---|
| Backend app code (`api/v1`, `services`, `models`, `schemas`, `core`) | 116 |
| Backend tests | 100 |
| Mobile app code (`lib/`) | 114 |
| Mobile tests | 63 |
| **Total** | **393** |

Checks after the move, run locally on this branch:

| Check | Before (copy-develop) | After (this branch) |
|---|---|---|
| `pytest` in `backend/app` | 621 passed, 10 skipped | 621 passed, 10 skipped |
| `flutter analyze --no-fatal-infos` | No issues found | No issues found |
| `flutter test` | 340 passed | 340 passed |

## Folders removed

These folders are empty after the move and are gone:

- `backend/app/api/` (with `api/v1/`)
- `backend/app/services/`
- `backend/app/models/`, including `models/__init__.py` (see "Import and config edits")
- `backend/app/schemas/`, including its `.gitkeep`
- `mobile/lib/ui/` (with `ui/landing/`) and `mobile/lib/design/`

Unchanged locations: `backend/app/main.py`, `backend/app/alembic/` (all migrations),
`backend/app/alembic.ini`, `backend/app/pytest.ini`, `backend/app/scripts/`,
`backend/app/tests/conftest.py`, `backend/app/tests/receipt_helpers.py`,
`backend/app/tests/reg_helpers.py`, `backend/app/tests/sql/`, `mobile/lib/main.dart`,
`mobile/test/fake_my_giving.dart`, `mobile/test/fake_report_server.dart`,
`mobile/test/fixtures/`, `mobile/assets/`, `mobile/android/`, `mobile/ios/`,
`mobile/web/`, `database/`, `.github/workflows/ci.yml` (it still runs from
`backend/app` and `mobile`, so it needed no change).

## Renamed files

Eight backend files shared a name with a file from another layer (for example
`models/report.py` and `schemas/report.py`). They now sit in the same folder, so
each one got a `_model` or `_schema` suffix, the same suffix most models and
schemas already used:

| Old path | New path |
|---|---|
| `backend/app/models/delivery.py` | `backend/app/core/m8_delivery_tracking/delivery_model.py` |
| `backend/app/models/notification.py` | `backend/app/core/notifications/notification_model.py` |
| `backend/app/models/report.py` | `backend/app/core/m2_disaster_reporting/report_model.py` |
| `backend/app/schemas/delivery.py` | `backend/app/core/m8_delivery_tracking/delivery_schema.py` |
| `backend/app/schemas/notification.py` | `backend/app/core/notifications/notification_schema.py` |
| `backend/app/schemas/report.py` | `backend/app/core/m2_disaster_reporting/report_schema.py` |

No other file was renamed.

## Import and config edits

1. **Python imports.** Every import of a moved module now uses its new dotted
   path, for example `from models.report import DisasterReport` became
   `from core.m2_disaster_reporting.report_model import DisasterReport`, and
   `import core.database as database` became `import core.shared.database as database`.
   The same replacement was applied to dotted names inside strings (such as
   `monkeypatch.setattr("...")` targets) and in `backend/app/alembic/env.py`.
2. **Package-level imports were split** where the names now live in different
   folders. For example `from core import database, realtime` became two lines,
   `from core.shared import database` and `from core.notifications import realtime`.
   `from services import handover` became `from core.m8_delivery_tracking import handover`.
   Aliases (`as ov`, `as mail_service`, ...) were kept.
3. **Test-to-test imports** such as `from tests.test_role_flows import ...` now
   include the test's module folder, e.g.
   `from tests.m1_user_management.test_role_flows import ...`.
4. **`backend/app/models/__init__.py` was removed.** It only imported `Role`,
   `Organization` and `User` (`from .role_model import Role`, ...). With models
   spread over module folders there is no `models` package left. `main.py`,
   `alembic/env.py` and `tests/conftest.py` already import every model they need,
   and the full test suite passes without it.
5. **`tests/cross_module/test_security_m4_m6_m7.py`**: the router list used short
   names that were loaded with `importlib.import_module(f"api.v1.{mod}")`. The
   list now holds the full new module paths (`core.m4_donation_management.donation_routes`, ...)
   and is loaded with `importlib.import_module(mod)`.
6. **Tests that find files from their own location** moved one folder deeper,
   so `Path(__file__).resolve().parents[N]` became `parents[N+1]` in:
   `tests/cross_module/test_nov21_fixes.py`, `tests/m2_disaster_reporting/test_disaster_types_migration.py`,
   `tests/shared/test_demo_seed.py`, `tests/shared/test_models_match_migrations.py`.
7. **Dart imports.** `package:mobile/...` imports point at the new paths
   (`package:mobile/ui/login_screen.dart` became
   `package:mobile/core/m1_user_management/login_screen.dart`). Relative imports
   (`'../api.dart'`, `'widgets.dart'`) were recomputed from each file's new folder.
   Mobile tests in sub-folders import the shared fakes as `'../fake_report_server.dart'`.
8. **No config file changed**: `pubspec.yaml`, `pytest.ini`, `alembic.ini`,
   `ci.yml`, Gradle and Xcode files are untouched.

## Path mentions in comments and docs

Comments, docstrings and living docs that named a moved file were updated to the
new path (for example `# see services/fulfillment.py` became
`# see core/m8_delivery_tracking/fulfillment.py`). 257 lines in 147 files changed this way. Import lines were not touched by this step.
Docs outside the code that were updated: `docs/architecture/donor-side-security.md`, `docs/architecture/multi-barangay-events.md`, `docs/architecture/per-item-fulfillment.md`, `docs/design/DESIGN_SYSTEM.md`, `mobile/TESTING.md`.

Left as they were on purpose, because they are dated records of past work:
`TEAM_PROGRESS.md`, `docs/security-audit-report.md` and the migration files in
`backend/app/alembic/versions/`. Paths in those files are the paths at the time
they were written; use the tables below to find the file today.

## Every file moved

### Backend app code

#### `backend/app/core/m1_user_management/` (18 files)

| Old path | New path |
|---|---|
| `backend/app/api/v1/account_router.py` | `backend/app/core/m1_user_management/account_router.py` |
| `backend/app/services/accounts.py` | `backend/app/core/m1_user_management/accounts.py` |
| `backend/app/api/v1/admin_document_routes.py` | `backend/app/core/m1_user_management/admin_document_routes.py` |
| `backend/app/api/v1/admin_router.py` | `backend/app/core/m1_user_management/admin_router.py` |
| `backend/app/core/auth.py` | `backend/app/core/m1_user_management/auth.py` |
| `backend/app/api/v1/auth_router.py` | `backend/app/core/m1_user_management/auth_router.py` |
| `backend/app/models/email_verification_model.py` | `backend/app/core/m1_user_management/email_verification_model.py` |
| `backend/app/core/names.py` | `backend/app/core/m1_user_management/names.py` |
| `backend/app/models/organization_model.py` | `backend/app/core/m1_user_management/organization_model.py` |
| `backend/app/schemas/organization_schema.py` | `backend/app/core/m1_user_management/organization_schema.py` |
| `backend/app/models/password_reset_model.py` | `backend/app/core/m1_user_management/password_reset_model.py` |
| `backend/app/core/passwords.py` | `backend/app/core/m1_user_management/passwords.py` |
| `backend/app/models/role_model.py` | `backend/app/core/m1_user_management/role_model.py` |
| `backend/app/api/v1/session_router.py` | `backend/app/core/m1_user_management/session_router.py` |
| `backend/app/core/temp_password.py` | `backend/app/core/m1_user_management/temp_password.py` |
| `backend/app/models/user_rbac_model.py` | `backend/app/core/m1_user_management/user_rbac_model.py` |
| `backend/app/schemas/user_schema.py` | `backend/app/core/m1_user_management/user_schema.py` |
| `backend/app/core/usernames.py` | `backend/app/core/m1_user_management/usernames.py` |

#### `backend/app/core/m2_disaster_reporting/` (9 files)

| Old path | New path |
|---|---|
| `backend/app/api/v1/contacts.py` | `backend/app/core/m2_disaster_reporting/contacts.py` |
| `backend/app/models/disaster_event_model.py` | `backend/app/core/m2_disaster_reporting/disaster_event_model.py` |
| `backend/app/services/disaster_events.py` | `backend/app/core/m2_disaster_reporting/disaster_events.py` |
| `backend/app/services/need_templates.py` | `backend/app/core/m2_disaster_reporting/need_templates.py` |
| `backend/app/services/report_feed.py` | `backend/app/core/m2_disaster_reporting/report_feed.py` |
| `backend/app/models/report.py` | `backend/app/core/m2_disaster_reporting/report_model.py` (renamed) |
| `backend/app/services/report_paging.py` | `backend/app/core/m2_disaster_reporting/report_paging.py` |
| `backend/app/schemas/report.py` | `backend/app/core/m2_disaster_reporting/report_schema.py` (renamed) |
| `backend/app/api/v1/reports.py` | `backend/app/core/m2_disaster_reporting/reports.py` |

#### `backend/app/core/m3_priority_guidance/` (1 files)

| Old path | New path |
|---|---|
| `backend/app/core/priority_engine.py` | `backend/app/core/m3_priority_guidance/priority_engine.py` |

#### `backend/app/core/m4_donation_management/` (15 files)

| Old path | New path |
|---|---|
| `backend/app/services/donation_additions.py` | `backend/app/core/m4_donation_management/donation_additions.py` |
| `backend/app/services/donation_entries.py` | `backend/app/core/m4_donation_management/donation_entries.py` |
| `backend/app/services/donation_expiry.py` | `backend/app/core/m4_donation_management/donation_expiry.py` |
| `backend/app/models/donation_info_model.py` | `backend/app/core/m4_donation_management/donation_info_model.py` |
| `backend/app/api/v1/donation_info_routes.py` | `backend/app/core/m4_donation_management/donation_info_routes.py` |
| `backend/app/schemas/donation_info_schema.py` | `backend/app/core/m4_donation_management/donation_info_schema.py` |
| `backend/app/api/v1/donation_lifecycle_routes.py` | `backend/app/core/m4_donation_management/donation_lifecycle_routes.py` |
| `backend/app/api/v1/donation_routes.py` | `backend/app/core/m4_donation_management/donation_routes.py` |
| `backend/app/services/email_hold.py` | `backend/app/core/m4_donation_management/email_hold.py` |
| `backend/app/services/entry_paging.py` | `backend/app/core/m4_donation_management/entry_paging.py` |
| `backend/app/models/guest_donor_model.py` | `backend/app/core/m4_donation_management/guest_donor_model.py` |
| `backend/app/services/guest_limits.py` | `backend/app/core/m4_donation_management/guest_limits.py` |
| `backend/app/models/physical_donation_model.py` | `backend/app/core/m4_donation_management/physical_donation_model.py` |
| `backend/app/schemas/physical_donation_schema.py` | `backend/app/core/m4_donation_management/physical_donation_schema.py` |
| `backend/app/services/pledge_trust.py` | `backend/app/core/m4_donation_management/pledge_trust.py` |

#### `backend/app/core/m5_inventory/` (13 files)

| Old path | New path |
|---|---|
| `backend/app/services/delivery_allocation.py` | `backend/app/core/m5_inventory/delivery_allocation.py` |
| `backend/app/services/delivery_stock.py` | `backend/app/core/m5_inventory/delivery_stock.py` |
| `backend/app/services/inventory.py` | `backend/app/core/m5_inventory/inventory.py` |
| `backend/app/models/inventory_model.py` | `backend/app/core/m5_inventory/inventory_model.py` |
| `backend/app/services/pickup_barangay.py` | `backend/app/core/m5_inventory/pickup_barangay.py` |
| `backend/app/services/pickup_geofence.py` | `backend/app/core/m5_inventory/pickup_geofence.py` |
| `backend/app/api/v1/pickup_plan_routes.py` | `backend/app/core/m5_inventory/pickup_plan_routes.py` |
| `backend/app/services/pickup_planner.py` | `backend/app/core/m5_inventory/pickup_planner.py` |
| `backend/app/services/pickup_zones.py` | `backend/app/core/m5_inventory/pickup_zones.py` |
| `backend/app/services/receive_queue.py` | `backend/app/core/m5_inventory/receive_queue.py` |
| `backend/app/models/received_goods_model.py` | `backend/app/core/m5_inventory/received_goods_model.py` |
| `backend/app/schemas/received_goods_schema.py` | `backend/app/core/m5_inventory/received_goods_schema.py` |
| `backend/app/api/v1/receiving_routes.py` | `backend/app/core/m5_inventory/receiving_routes.py` |

#### `backend/app/core/m6_city_confirmation/` (3 files)

| Old path | New path |
|---|---|
| `backend/app/api/v1/cmo_router.py` | `backend/app/core/m6_city_confirmation/cmo_router.py` |
| `backend/app/models/donation_confirmation_model.py` | `backend/app/core/m6_city_confirmation/donation_confirmation_model.py` |
| `backend/app/schemas/donation_confirmation_schema.py` | `backend/app/core/m6_city_confirmation/donation_confirmation_schema.py` |

#### `backend/app/core/m7_logistics_support/` (6 files)

| Old path | New path |
|---|---|
| `backend/app/services/delivery_reminders.py` | `backend/app/core/m7_logistics_support/delivery_reminders.py` |
| `backend/app/api/v1/drrmo_router.py` | `backend/app/core/m7_logistics_support/drrmo_router.py` |
| `backend/app/models/logistics_request_model.py` | `backend/app/core/m7_logistics_support/logistics_request_model.py` |
| `backend/app/schemas/logistics_request_schema.py` | `backend/app/core/m7_logistics_support/logistics_request_schema.py` |
| `backend/app/api/v1/logistics_router.py` | `backend/app/core/m7_logistics_support/logistics_router.py` |
| `backend/app/services/logistics_stage.py` | `backend/app/core/m7_logistics_support/logistics_stage.py` |

#### `backend/app/core/m8_delivery_tracking/` (11 files)

| Old path | New path |
|---|---|
| `backend/app/services/acknowledgment.py` | `backend/app/core/m8_delivery_tracking/acknowledgment.py` |
| `backend/app/api/v1/deliveries.py` | `backend/app/core/m8_delivery_tracking/deliveries.py` |
| `backend/app/models/delivery.py` | `backend/app/core/m8_delivery_tracking/delivery_model.py` (renamed) |
| `backend/app/services/delivery_notices.py` | `backend/app/core/m8_delivery_tracking/delivery_notices.py` |
| `backend/app/api/v1/delivery_problems.py` | `backend/app/core/m8_delivery_tracking/delivery_problems.py` |
| `backend/app/schemas/delivery.py` | `backend/app/core/m8_delivery_tracking/delivery_schema.py` (renamed) |
| `backend/app/services/delivery_views.py` | `backend/app/core/m8_delivery_tracking/delivery_views.py` |
| `backend/app/services/fulfillment.py` | `backend/app/core/m8_delivery_tracking/fulfillment.py` |
| `backend/app/services/handover.py` | `backend/app/core/m8_delivery_tracking/handover.py` |
| `backend/app/services/shortfall.py` | `backend/app/core/m8_delivery_tracking/shortfall.py` |
| `backend/app/api/v1/trips.py` | `backend/app/core/m8_delivery_tracking/trips.py` |

#### `backend/app/core/m9_dashboards/` (6 files)

| Old path | New path |
|---|---|
| `backend/app/services/csws_overview.py` | `backend/app/core/m9_dashboards/csws_overview.py` |
| `backend/app/api/v1/csws_overview_routes.py` | `backend/app/core/m9_dashboards/csws_overview_routes.py` |
| `backend/app/api/v1/dashboard_routes.py` | `backend/app/core/m9_dashboards/dashboard_routes.py` |
| `backend/app/schemas/dashboard_schema.py` | `backend/app/core/m9_dashboards/dashboard_schema.py` |
| `backend/app/services/delivery_timing.py` | `backend/app/core/m9_dashboards/delivery_timing.py` |
| `backend/app/api/v1/public_routes.py` | `backend/app/core/m9_dashboards/public_routes.py` |

#### `backend/app/core/notifications/` (9 files)

| Old path | New path |
|---|---|
| `backend/app/models/notification.py` | `backend/app/core/notifications/notification_model.py` (renamed) |
| `backend/app/schemas/notification.py` | `backend/app/core/notifications/notification_schema.py` (renamed) |
| `backend/app/core/notifications.py` | `backend/app/core/notifications/notifications.py` |
| `backend/app/api/v1/notifications_router.py` | `backend/app/core/notifications/notifications_router.py` |
| `backend/app/core/push.py` | `backend/app/core/notifications/push.py` |
| `backend/app/api/v1/push_router.py` | `backend/app/core/notifications/push_router.py` |
| `backend/app/core/realtime.py` | `backend/app/core/notifications/realtime.py` |
| `backend/app/api/v1/realtime_router.py` | `backend/app/core/notifications/realtime_router.py` |
| `backend/app/services/report_story.py` | `backend/app/core/notifications/report_story.py` |

#### `backend/app/core/reference_data/` (10 files)

| Old path | New path |
|---|---|
| `backend/app/models/barangay_hazard_model.py` | `backend/app/core/reference_data/barangay_hazard_model.py` |
| `backend/app/models/barangay_model.py` | `backend/app/core/reference_data/barangay_model.py` |
| `backend/app/models/city_model.py` | `backend/app/core/reference_data/city_model.py` |
| `backend/app/models/disaster_type_model.py` | `backend/app/core/reference_data/disaster_type_model.py` |
| `backend/app/models/item_model.py` | `backend/app/core/reference_data/item_model.py` |
| `backend/app/services/item_quantities.py` | `backend/app/core/reference_data/item_quantities.py` |
| `backend/app/services/items.py` | `backend/app/core/reference_data/items.py` |
| `backend/app/api/v1/lookup_routes.py` | `backend/app/core/reference_data/lookup_routes.py` |
| `backend/app/models/sitio_model.py` | `backend/app/core/reference_data/sitio_model.py` |
| `backend/app/services/units.py` | `backend/app/core/reference_data/units.py` |

#### `backend/app/core/shared/` (15 files)

| Old path | New path |
|---|---|
| `backend/app/core/audit.py` | `backend/app/core/shared/audit.py` |
| `backend/app/models/audit_log_model.py` | `backend/app/core/shared/audit_log_model.py` |
| `backend/app/core/client_ip.py` | `backend/app/core/shared/client_ip.py` |
| `backend/app/core/config.py` | `backend/app/core/shared/config.py` |
| `backend/app/core/database.py` | `backend/app/core/shared/database.py` |
| `backend/app/core/email.py` | `backend/app/core/shared/email.py` |
| `backend/app/api/v1/health_routes.py` | `backend/app/core/shared/health_routes.py` |
| `backend/app/core/log_privacy.py` | `backend/app/core/shared/log_privacy.py` |
| `backend/app/core/pagination.py` | `backend/app/core/shared/pagination.py` |
| `backend/app/core/storage.py` | `backend/app/core/shared/storage.py` |
| `backend/app/models/upload_model.py` | `backend/app/core/shared/upload_model.py` |
| `backend/app/api/v1/upload_routes.py` | `backend/app/core/shared/upload_routes.py` |
| `backend/app/schemas/upload_schema.py` | `backend/app/core/shared/upload_schema.py` |
| `backend/app/core/uploads.py` | `backend/app/core/shared/uploads.py` |
| `backend/app/core/validators.py` | `backend/app/core/shared/validators.py` |

### Backend tests

#### `backend/app/tests/cross_module/` (7 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_defense_fixes.py` | `backend/app/tests/cross_module/test_defense_fixes.py` |
| `backend/app/tests/test_manuscript_functions.py` | `backend/app/tests/cross_module/test_manuscript_functions.py` |
| `backend/app/tests/test_nov21_fixes.py` | `backend/app/tests/cross_module/test_nov21_fixes.py` |
| `backend/app/tests/test_paged_module_lists.py` | `backend/app/tests/cross_module/test_paged_module_lists.py` |
| `backend/app/tests/test_runthrough_gaps.py` | `backend/app/tests/cross_module/test_runthrough_gaps.py` |
| `backend/app/tests/test_security_m4_m6_m7.py` | `backend/app/tests/cross_module/test_security_m4_m6_m7.py` |
| `backend/app/tests/test_testing_fixes_oct19.py` | `backend/app/tests/cross_module/test_testing_fixes_oct19.py` |

#### `backend/app/tests/m1_user_management/` (15 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_account_deletion_privacy.py` | `backend/app/tests/m1_user_management/test_account_deletion_privacy.py` |
| `backend/app/tests/test_account_sections.py` | `backend/app/tests/m1_user_management/test_account_sections.py` |
| `backend/app/tests/test_admin_edit_accounts.py` | `backend/app/tests/m1_user_management/test_admin_edit_accounts.py` |
| `backend/app/tests/test_change_password.py` | `backend/app/tests/m1_user_management/test_change_password.py` |
| `backend/app/tests/test_delete_account.py` | `backend/app/tests/m1_user_management/test_delete_account.py` |
| `backend/app/tests/test_email_verification.py` | `backend/app/tests/m1_user_management/test_email_verification.py` |
| `backend/app/tests/test_organization_categories.py` | `backend/app/tests/m1_user_management/test_organization_categories.py` |
| `backend/app/tests/test_password_change_tokens.py` | `backend/app/tests/m1_user_management/test_password_change_tokens.py` |
| `backend/app/tests/test_password_reset_limits.py` | `backend/app/tests/m1_user_management/test_password_reset_limits.py` |
| `backend/app/tests/test_registration_review.py` | `backend/app/tests/m1_user_management/test_registration_review.py` |
| `backend/app/tests/test_registration_uploads.py` | `backend/app/tests/m1_user_management/test_registration_uploads.py` |
| `backend/app/tests/test_rejected_orgs.py` | `backend/app/tests/m1_user_management/test_rejected_orgs.py` |
| `backend/app/tests/test_role_flows.py` | `backend/app/tests/m1_user_management/test_role_flows.py` |
| `backend/app/tests/test_tokens.py` | `backend/app/tests/m1_user_management/test_tokens.py` |
| `backend/app/tests/test_usernames.py` | `backend/app/tests/m1_user_management/test_usernames.py` |

#### `backend/app/tests/m2_disaster_reporting/` (16 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_address_search_cap.py` | `backend/app/tests/m2_disaster_reporting/test_address_search_cap.py` |
| `backend/app/tests/test_barangay_hazards.py` | `backend/app/tests/m2_disaster_reporting/test_barangay_hazards.py` |
| `backend/app/tests/test_disaster_events.py` | `backend/app/tests/m2_disaster_reporting/test_disaster_events.py` |
| `backend/app/tests/test_disaster_type_filter.py` | `backend/app/tests/m2_disaster_reporting/test_disaster_type_filter.py` |
| `backend/app/tests/test_disaster_type_other.py` | `backend/app/tests/m2_disaster_reporting/test_disaster_type_other.py` |
| `backend/app/tests/test_disaster_types_migration.py` | `backend/app/tests/m2_disaster_reporting/test_disaster_types_migration.py` |
| `backend/app/tests/test_need_templates.py` | `backend/app/tests/m2_disaster_reporting/test_need_templates.py` |
| `backend/app/tests/test_report_barangay_scope.py` | `backend/app/tests/m2_disaster_reporting/test_report_barangay_scope.py` |
| `backend/app/tests/test_report_edit_withdraw.py` | `backend/app/tests/m2_disaster_reporting/test_report_edit_withdraw.py` |
| `backend/app/tests/test_report_paging.py` | `backend/app/tests/m2_disaster_reporting/test_report_paging.py` |
| `backend/app/tests/test_report_sitios.py` | `backend/app/tests/m2_disaster_reporting/test_report_sitios.py` |
| `backend/app/tests/test_report_soft_delete.py` | `backend/app/tests/m2_disaster_reporting/test_report_soft_delete.py` |
| `backend/app/tests/test_report_update_audit.py` | `backend/app/tests/m2_disaster_reporting/test_report_update_audit.py` |
| `backend/app/tests/test_reports.py` | `backend/app/tests/m2_disaster_reporting/test_reports.py` |
| `backend/app/tests/test_sms_report_lock.py` | `backend/app/tests/m2_disaster_reporting/test_sms_report_lock.py` |
| `backend/app/tests/test_sms_unregistered_sender.py` | `backend/app/tests/m2_disaster_reporting/test_sms_unregistered_sender.py` |

#### `backend/app/tests/m3_priority_guidance/` (2 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_drrmo_priority.py` | `backend/app/tests/m3_priority_guidance/test_drrmo_priority.py` |
| `backend/app/tests/test_priority_engine.py` | `backend/app/tests/m3_priority_guidance/test_priority_engine.py` |

#### `backend/app/tests/m4_donation_management/` (10 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_donation_additions.py` | `backend/app/tests/m4_donation_management/test_donation_additions.py` |
| `backend/app/tests/test_donation_batch.py` | `backend/app/tests/m4_donation_management/test_donation_batch.py` |
| `backend/app/tests/test_donation_entries.py` | `backend/app/tests/m4_donation_management/test_donation_entries.py` |
| `backend/app/tests/test_donation_expiry.py` | `backend/app/tests/m4_donation_management/test_donation_expiry.py` |
| `backend/app/tests/test_donation_info.py` | `backend/app/tests/m4_donation_management/test_donation_info.py` |
| `backend/app/tests/test_donation_notice_order.py` | `backend/app/tests/m4_donation_management/test_donation_notice_order.py` |
| `backend/app/tests/test_donation_records.py` | `backend/app/tests/m4_donation_management/test_donation_records.py` |
| `backend/app/tests/test_guest_cancel_and_qr_access.py` | `backend/app/tests/m4_donation_management/test_guest_cancel_and_qr_access.py` |
| `backend/app/tests/test_guest_donation_limits.py` | `backend/app/tests/m4_donation_management/test_guest_donation_limits.py` |
| `backend/app/tests/test_guest_donor_privacy.py` | `backend/app/tests/m4_donation_management/test_guest_donor_privacy.py` |

#### `backend/app/tests/m5_inventory/` (11 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_delivery_allocation.py` | `backend/app/tests/m5_inventory/test_delivery_allocation.py` |
| `backend/app/tests/test_inventory_concurrency.py` | `backend/app/tests/m5_inventory/test_inventory_concurrency.py` |
| `backend/app/tests/test_inventory_paths.py` | `backend/app/tests/m5_inventory/test_inventory_paths.py` |
| `backend/app/tests/test_item_quantities.py` | `backend/app/tests/m5_inventory/test_item_quantities.py` |
| `backend/app/tests/test_item_review.py` | `backend/app/tests/m5_inventory/test_item_review.py` |
| `backend/app/tests/test_pickup_contact_check.py` | `backend/app/tests/m5_inventory/test_pickup_contact_check.py` |
| `backend/app/tests/test_pickup_dates_and_areas.py` | `backend/app/tests/m5_inventory/test_pickup_dates_and_areas.py` |
| `backend/app/tests/test_pickup_days_and_runs.py` | `backend/app/tests/m5_inventory/test_pickup_days_and_runs.py` |
| `backend/app/tests/test_pickup_geofence.py` | `backend/app/tests/m5_inventory/test_pickup_geofence.py` |
| `backend/app/tests/test_pickup_plan.py` | `backend/app/tests/m5_inventory/test_pickup_plan.py` |
| `backend/app/tests/test_pickup_zones.py` | `backend/app/tests/m5_inventory/test_pickup_zones.py` |

#### `backend/app/tests/m6_city_confirmation/` (1 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_cmo_entries.py` | `backend/app/tests/m6_city_confirmation/test_cmo_entries.py` |

#### `backend/app/tests/m7_logistics_support/` (5 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_csws_drrmo_flow.py` | `backend/app/tests/m7_logistics_support/test_csws_drrmo_flow.py` |
| `backend/app/tests/test_delivery_reminders.py` | `backend/app/tests/m7_logistics_support/test_delivery_reminders.py` |
| `backend/app/tests/test_drrmo_marks_in_transit.py` | `backend/app/tests/m7_logistics_support/test_drrmo_marks_in_transit.py` |
| `backend/app/tests/test_logistics_needs.py` | `backend/app/tests/m7_logistics_support/test_logistics_needs.py` |
| `backend/app/tests/test_shared_logistics_notifications.py` | `backend/app/tests/m7_logistics_support/test_shared_logistics_notifications.py` |

#### `backend/app/tests/m8_delivery_tracking/` (13 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_delete_delivery.py` | `backend/app/tests/m8_delivery_tracking/test_delete_delivery.py` |
| `backend/app/tests/test_deliveries.py` | `backend/app/tests/m8_delivery_tracking/test_deliveries.py` |
| `backend/app/tests/test_delivery_history_privacy.py` | `backend/app/tests/m8_delivery_tracking/test_delivery_history_privacy.py` |
| `backend/app/tests/test_delivery_lines.py` | `backend/app/tests/m8_delivery_tracking/test_delivery_lines.py` |
| `backend/app/tests/test_delivery_problems.py` | `backend/app/tests/m8_delivery_tracking/test_delivery_problems.py` |
| `backend/app/tests/test_delivery_status_times.py` | `backend/app/tests/m8_delivery_tracking/test_delivery_status_times.py` |
| `backend/app/tests/test_delivery_trips.py` | `backend/app/tests/m8_delivery_tracking/test_delivery_trips.py` |
| `backend/app/tests/test_donor_deliveries.py` | `backend/app/tests/m8_delivery_tracking/test_donor_deliveries.py` |
| `backend/app/tests/test_handover_receipt.py` | `backend/app/tests/m8_delivery_tracking/test_handover_receipt.py` |
| `backend/app/tests/test_per_item_fulfillment.py` | `backend/app/tests/m8_delivery_tracking/test_per_item_fulfillment.py` |
| `backend/app/tests/test_receipt_counts.py` | `backend/app/tests/m8_delivery_tracking/test_receipt_counts.py` |
| `backend/app/tests/test_shortfall_review.py` | `backend/app/tests/m8_delivery_tracking/test_shortfall_review.py` |
| `backend/app/tests/test_still_needed_chips.py` | `backend/app/tests/m8_delivery_tracking/test_still_needed_chips.py` |

#### `backend/app/tests/m9_dashboards/` (5 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_csws_dashboard.py` | `backend/app/tests/m9_dashboards/test_csws_dashboard.py` |
| `backend/app/tests/test_dashboard_drilldowns.py` | `backend/app/tests/m9_dashboards/test_dashboard_drilldowns.py` |
| `backend/app/tests/test_dashboard_report_total.py` | `backend/app/tests/m9_dashboards/test_dashboard_report_total.py` |
| `backend/app/tests/test_my_giving_loads.py` | `backend/app/tests/m9_dashboards/test_my_giving_loads.py` |
| `backend/app/tests/test_public_report_source.py` | `backend/app/tests/m9_dashboards/test_public_report_source.py` |

#### `backend/app/tests/notifications/` (4 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_live_updates.py` | `backend/app/tests/notifications/test_live_updates.py` |
| `backend/app/tests/test_notification_delete.py` | `backend/app/tests/notifications/test_notification_delete.py` |
| `backend/app/tests/test_notifications_unit.py` | `backend/app/tests/notifications/test_notifications_unit.py` |
| `backend/app/tests/test_push.py` | `backend/app/tests/notifications/test_push.py` |

#### `backend/app/tests/reference_data/` (1 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_lookups_access.py` | `backend/app/tests/reference_data/test_lookups_access.py` |

#### `backend/app/tests/shared/` (10 files)

| Old path | New path |
|---|---|
| `backend/app/tests/test_client_ip.py` | `backend/app/tests/shared/test_client_ip.py` |
| `backend/app/tests/test_connection.py` | `backend/app/tests/shared/test_connection.py` |
| `backend/app/tests/test_demo_seed.py` | `backend/app/tests/shared/test_demo_seed.py` |
| `backend/app/tests/test_docs_and_cors.py` | `backend/app/tests/shared/test_docs_and_cors.py` |
| `backend/app/tests/test_log_privacy.py` | `backend/app/tests/shared/test_log_privacy.py` |
| `backend/app/tests/test_models_match_migrations.py` | `backend/app/tests/shared/test_models_match_migrations.py` |
| `backend/app/tests/test_pagination.py` | `backend/app/tests/shared/test_pagination.py` |
| `backend/app/tests/test_paging_all_roles.py` | `backend/app/tests/shared/test_paging_all_roles.py` |
| `backend/app/tests/test_upload_cleanup.py` | `backend/app/tests/shared/test_upload_cleanup.py` |
| `backend/app/tests/test_uploads.py` | `backend/app/tests/shared/test_uploads.py` |

### Mobile app code

#### `mobile/lib/core/m1_user_management/` (10 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/account_detail_screen.dart` | `mobile/lib/core/m1_user_management/account_detail_screen.dart` |
| `mobile/lib/ui/account_form.dart` | `mobile/lib/core/m1_user_management/account_form.dart` |
| `mobile/lib/account_tab.dart` | `mobile/lib/core/m1_user_management/account_tab.dart` |
| `mobile/lib/ui/admin_screens.dart` | `mobile/lib/core/m1_user_management/admin_screens.dart` |
| `mobile/lib/ui/change_password_screen.dart` | `mobile/lib/core/m1_user_management/change_password_screen.dart` |
| `mobile/lib/ui/forgot_password_screen.dart` | `mobile/lib/core/m1_user_management/forgot_password_screen.dart` |
| `mobile/lib/ui/login_screen.dart` | `mobile/lib/core/m1_user_management/login_screen.dart` |
| `mobile/lib/ui/profile_screen.dart` | `mobile/lib/core/m1_user_management/profile_screen.dart` |
| `mobile/lib/ui/register_screen.dart` | `mobile/lib/core/m1_user_management/register_screen.dart` |
| `mobile/lib/ui/verify_email_sheet.dart` | `mobile/lib/core/m1_user_management/verify_email_sheet.dart` |

#### `mobile/lib/core/m2_disaster_reporting/` (15 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/event_screen.dart` | `mobile/lib/core/m2_disaster_reporting/event_screen.dart` |
| `mobile/lib/ui/hazard_barangay_field.dart` | `mobile/lib/core/m2_disaster_reporting/hazard_barangay_field.dart` |
| `mobile/lib/ui/multi_report.dart` | `mobile/lib/core/m2_disaster_reporting/multi_report.dart` |
| `mobile/lib/ui/paged_reports.dart` | `mobile/lib/core/m2_disaster_reporting/paged_reports.dart` |
| `mobile/lib/report_api.dart` | `mobile/lib/core/m2_disaster_reporting/report_api.dart` |
| `mobile/lib/report_detail_screen.dart` | `mobile/lib/core/m2_disaster_reporting/report_detail_screen.dart` |
| `mobile/lib/ui/report_filters.dart` | `mobile/lib/core/m2_disaster_reporting/report_filters.dart` |
| `mobile/lib/report_list_screen.dart` | `mobile/lib/core/m2_disaster_reporting/report_list_screen.dart` |
| `mobile/lib/report_model.dart` | `mobile/lib/core/m2_disaster_reporting/report_model.dart` |
| `mobile/lib/ui/report_screens.dart` | `mobile/lib/core/m2_disaster_reporting/report_screens.dart` |
| `mobile/lib/ui/report_summary_card.dart` | `mobile/lib/core/m2_disaster_reporting/report_summary_card.dart` |
| `mobile/lib/ui/sitio_picker.dart` | `mobile/lib/core/m2_disaster_reporting/sitio_picker.dart` |
| `mobile/lib/ui/sms_original.dart` | `mobile/lib/core/m2_disaster_reporting/sms_original.dart` |
| `mobile/lib/ui/sms_report_format.dart` | `mobile/lib/core/m2_disaster_reporting/sms_report_format.dart` |
| `mobile/lib/ui/sms_send_screen.dart` | `mobile/lib/core/m2_disaster_reporting/sms_send_screen.dart` |

#### `mobile/lib/core/m4_donation_management/` (11 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/donate_screen.dart` | `mobile/lib/core/m4_donation_management/donate_screen.dart` |
| `mobile/lib/ui/donation_entries_view.dart` | `mobile/lib/core/m4_donation_management/donation_entries_view.dart` |
| `mobile/lib/ui/donation_info.dart` | `mobile/lib/core/m4_donation_management/donation_info.dart` |
| `mobile/lib/ui/donor_feed.dart` | `mobile/lib/core/m4_donation_management/donor_feed.dart` |
| `mobile/lib/ui/donor_screens.dart` | `mobile/lib/core/m4_donation_management/donor_screens.dart` |
| `mobile/lib/ui/entry_report_views.dart` | `mobile/lib/core/m4_donation_management/entry_report_views.dart` |
| `mobile/lib/ui/expiry_widgets.dart` | `mobile/lib/core/m4_donation_management/expiry_widgets.dart` |
| `mobile/lib/ui/my_giving.dart` | `mobile/lib/core/m4_donation_management/my_giving.dart` |
| `mobile/lib/ui/paged_donation_entries.dart` | `mobile/lib/core/m4_donation_management/paged_donation_entries.dart` |
| `mobile/lib/ui/qr_save.dart` | `mobile/lib/core/m4_donation_management/qr_save.dart` |
| `mobile/lib/ui/records_screens.dart` | `mobile/lib/core/m4_donation_management/records_screens.dart` |

#### `mobile/lib/core/m5_inventory/` (11 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/batch_sheet.dart` | `mobile/lib/core/m5_inventory/batch_sheet.dart` |
| `mobile/lib/ui/csws_screens.dart` | `mobile/lib/core/m5_inventory/csws_screens.dart` |
| `mobile/lib/ui/inventory_view.dart` | `mobile/lib/core/m5_inventory/inventory_view.dart` |
| `mobile/lib/ui/pickup_actions.dart` | `mobile/lib/core/m5_inventory/pickup_actions.dart` |
| `mobile/lib/ui/pickup_days.dart` | `mobile/lib/core/m5_inventory/pickup_days.dart` |
| `mobile/lib/ui/pickup_list.dart` | `mobile/lib/core/m5_inventory/pickup_list.dart` |
| `mobile/lib/ui/pickup_map.dart` | `mobile/lib/core/m5_inventory/pickup_map.dart` |
| `mobile/lib/ui/pickup_plan.dart` | `mobile/lib/core/m5_inventory/pickup_plan.dart` |
| `mobile/lib/ui/pickup_route.dart` | `mobile/lib/core/m5_inventory/pickup_route.dart` |
| `mobile/lib/ui/receipt_count_dialog.dart` | `mobile/lib/core/m5_inventory/receipt_count_dialog.dart` |
| `mobile/lib/ui/receive_filters.dart` | `mobile/lib/core/m5_inventory/receive_filters.dart` |

#### `mobile/lib/core/m6_city_confirmation/` (1 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/cmo_screens.dart` | `mobile/lib/core/m6_city_confirmation/cmo_screens.dart` |

#### `mobile/lib/core/m7_logistics_support/` (2 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/logistics_cards.dart` | `mobile/lib/core/m7_logistics_support/logistics_cards.dart` |
| `mobile/lib/ui/ops_screens.dart` | `mobile/lib/core/m7_logistics_support/ops_screens.dart` |

#### `mobile/lib/core/m8_delivery_tracking/` (8 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/acknowledgment_screen.dart` | `mobile/lib/core/m8_delivery_tracking/acknowledgment_screen.dart` |
| `mobile/lib/ui/delivery_widgets.dart` | `mobile/lib/core/m8_delivery_tracking/delivery_widgets.dart` |
| `mobile/lib/ui/handover_code.dart` | `mobile/lib/core/m8_delivery_tracking/handover_code.dart` |
| `mobile/lib/ui/needs_progress.dart` | `mobile/lib/core/m8_delivery_tracking/needs_progress.dart` |
| `mobile/lib/ui/scheduled_deliveries.dart` | `mobile/lib/core/m8_delivery_tracking/scheduled_deliveries.dart` |
| `mobile/lib/ui/short_deliveries_screen.dart` | `mobile/lib/core/m8_delivery_tracking/short_deliveries_screen.dart` |
| `mobile/lib/ui/signature_pad.dart` | `mobile/lib/core/m8_delivery_tracking/signature_pad.dart` |
| `mobile/lib/ui/trip_screens.dart` | `mobile/lib/core/m8_delivery_tracking/trip_screens.dart` |

#### `mobile/lib/core/m9_dashboards/` (11 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/csws_dashboard.dart` | `mobile/lib/core/m9_dashboards/csws_dashboard.dart` |
| `mobile/lib/ui/donor_dashboard.dart` | `mobile/lib/core/m9_dashboards/donor_dashboard.dart` |
| `mobile/lib/ui/landing/about_section.dart` | `mobile/lib/core/m9_dashboards/landing/about_section.dart` |
| `mobile/lib/ui/landing/landing_band.dart` | `mobile/lib/core/m9_dashboards/landing/landing_band.dart` |
| `mobile/lib/ui/landing/landing_extras.dart` | `mobile/lib/core/m9_dashboards/landing/landing_extras.dart` |
| `mobile/lib/ui/landing/landing_screen.dart` | `mobile/lib/core/m9_dashboards/landing/landing_screen.dart` |
| `mobile/lib/ui/landing/landing_sections.dart` | `mobile/lib/core/m9_dashboards/landing/landing_sections.dart` |
| `mobile/lib/ui/landing/landing_v2.dart` | `mobile/lib/core/m9_dashboards/landing/landing_v2.dart` |
| `mobile/lib/ui/landing/mission_section.dart` | `mobile/lib/core/m9_dashboards/landing/mission_section.dart` |
| `mobile/lib/ui/landing/public_data.dart` | `mobile/lib/core/m9_dashboards/landing/public_data.dart` |
| `mobile/lib/ui/needs_action.dart` | `mobile/lib/core/m9_dashboards/needs_action.dart` |

#### `mobile/lib/core/notifications/` (3 files)

| Old path | New path |
|---|---|
| `mobile/lib/ui/notifications_screen.dart` | `mobile/lib/core/notifications/notifications_screen.dart` |
| `mobile/lib/push.dart` | `mobile/lib/core/notifications/push.dart` |
| `mobile/lib/realtime.dart` | `mobile/lib/core/notifications/realtime.dart` |

#### `mobile/lib/core/shared/` (42 files)

| Old path | New path |
|---|---|
| `mobile/lib/api.dart` | `mobile/lib/core/shared/api.dart` |
| `mobile/lib/app_navigator.dart` | `mobile/lib/core/shared/app_navigator.dart` |
| `mobile/lib/app_router.dart` | `mobile/lib/core/shared/app_router.dart` |
| `mobile/lib/app_routes.dart` | `mobile/lib/core/shared/app_routes.dart` |
| `mobile/lib/ui/blur_popup.dart` | `mobile/lib/core/shared/blur_popup.dart` |
| `mobile/lib/ui/brand_title.dart` | `mobile/lib/core/shared/brand_title.dart` |
| `mobile/lib/common.dart` | `mobile/lib/core/shared/common.dart` |
| `mobile/lib/ui/copyable_phone.dart` | `mobile/lib/core/shared/copyable_phone.dart` |
| `mobile/lib/design/components/controls.dart` | `mobile/lib/core/shared/design/components/controls.dart` |
| `mobile/lib/design/components/display.dart` | `mobile/lib/core/shared/design/components/display.dart` |
| `mobile/lib/design/components/feedback.dart` | `mobile/lib/core/shared/design/components/feedback.dart` |
| `mobile/lib/design/components/motion.dart` | `mobile/lib/core/shared/design/components/motion.dart` |
| `mobile/lib/design/components/nav.dart` | `mobile/lib/core/shared/design/components/nav.dart` |
| `mobile/lib/design/components/toast.dart` | `mobile/lib/core/shared/design/components/toast.dart` |
| `mobile/lib/design/design.dart` | `mobile/lib/core/shared/design/design.dart` |
| `mobile/lib/design/gallery_screen.dart` | `mobile/lib/core/shared/design/gallery_screen.dart` |
| `mobile/lib/design/status.dart` | `mobile/lib/core/shared/design/status.dart` |
| `mobile/lib/design/theme.dart` | `mobile/lib/core/shared/design/theme.dart` |
| `mobile/lib/design/tokens.dart` | `mobile/lib/core/shared/design/tokens.dart` |
| `mobile/lib/checks_tab.dart` | `mobile/lib/core/shared/dev_tools/checks_tab.dart` |
| `mobile/lib/dev_console.dart` | `mobile/lib/core/shared/dev_tools/dev_console.dart` |
| `mobile/lib/upload_demo_tab.dart` | `mobile/lib/core/shared/dev_tools/upload_demo_tab.dart` |
| `mobile/lib/ui/disaster_art.dart` | `mobile/lib/core/shared/disaster_art.dart` |
| `mobile/lib/ui/form_draft.dart` | `mobile/lib/core/shared/form_draft.dart` |
| `mobile/lib/ui/home.dart` | `mobile/lib/core/shared/home.dart` |
| `mobile/lib/ui/home_nav.dart` | `mobile/lib/core/shared/home_nav.dart` |
| `mobile/lib/ui/input_formatters.dart` | `mobile/lib/core/shared/input_formatters.dart` |
| `mobile/lib/ui/item_amounts.dart` | `mobile/lib/core/shared/item_amounts.dart` |
| `mobile/lib/ui/item_art.dart` | `mobile/lib/core/shared/item_art.dart` |
| `mobile/lib/ui/kept_views.dart` | `mobile/lib/core/shared/kept_views.dart` |
| `mobile/lib/ui/kit_contents.dart` | `mobile/lib/core/shared/kit_contents.dart` |
| `mobile/lib/ui/location_picker.dart` | `mobile/lib/core/shared/location_picker.dart` |
| `mobile/lib/modules.dart` | `mobile/lib/core/shared/modules.dart` |
| `mobile/lib/nexa_theme.dart` | `mobile/lib/core/shared/nexa_theme.dart` |
| `mobile/lib/nexa_widgets.dart` | `mobile/lib/core/shared/nexa_widgets.dart` |
| `mobile/lib/ui/paginated_list.dart` | `mobile/lib/core/shared/paginated_list.dart` |
| `mobile/lib/ui/private_file_view.dart` | `mobile/lib/core/shared/private_file_view.dart` |
| `mobile/lib/ui/quantity_units.dart` | `mobile/lib/core/shared/quantity_units.dart` |
| `mobile/lib/ui/theme_toggle.dart` | `mobile/lib/core/shared/theme_toggle.dart` |
| `mobile/lib/ui/upload_field.dart` | `mobile/lib/core/shared/upload_field.dart` |
| `mobile/lib/ui/validators.dart` | `mobile/lib/core/shared/validators.dart` |
| `mobile/lib/ui/widgets.dart` | `mobile/lib/core/shared/widgets.dart` |

### Mobile tests

#### `mobile/test/cross_module/` (5 files)

| Old path | New path |
|---|---|
| `mobile/test/concerns_nov4_test.dart` | `mobile/test/cross_module/concerns_nov4_test.dart` |
| `mobile/test/paged_module_lists_test.dart` | `mobile/test/cross_module/paged_module_lists_test.dart` |
| `mobile/test/problema_napud_test.dart` | `mobile/test/cross_module/problema_napud_test.dart` |
| `mobile/test/testing_fixes_oct19_test.dart` | `mobile/test/cross_module/testing_fixes_oct19_test.dart` |
| `mobile/test/testing_fixes_oct20_test.dart` | `mobile/test/cross_module/testing_fixes_oct20_test.dart` |

#### `mobile/test/m1_user_management/` (12 files)

| Old path | New path |
|---|---|
| `mobile/test/account_form_test.dart` | `mobile/test/m1_user_management/account_form_test.dart` |
| `mobile/test/accounts_list_test.dart` | `mobile/test/m1_user_management/accounts_list_test.dart` |
| `mobile/test/change_password_token_test.dart` | `mobile/test/m1_user_management/change_password_token_test.dart` |
| `mobile/test/forgot_password_test.dart` | `mobile/test/m1_user_management/forgot_password_test.dart` |
| `mobile/test/guest_consent_test.dart` | `mobile/test/m1_user_management/guest_consent_test.dart` |
| `mobile/test/login_back_test.dart` | `mobile/test/m1_user_management/login_back_test.dart` |
| `mobile/test/login_popup_test.dart` | `mobile/test/m1_user_management/login_popup_test.dart` |
| `mobile/test/profile_screen_test.dart` | `mobile/test/m1_user_management/profile_screen_test.dart` |
| `mobile/test/register_popup_test.dart` | `mobile/test/m1_user_management/register_popup_test.dart` |
| `mobile/test/registration_test.dart` | `mobile/test/m1_user_management/registration_test.dart` |
| `mobile/test/registrations_test.dart` | `mobile/test/m1_user_management/registrations_test.dart` |
| `mobile/test/token_storage_test.dart` | `mobile/test/m1_user_management/token_storage_test.dart` |

#### `mobile/test/m2_disaster_reporting/` (11 files)

| Old path | New path |
|---|---|
| `mobile/test/disaster_type_filter_test.dart` | `mobile/test/m2_disaster_reporting/disaster_type_filter_test.dart` |
| `mobile/test/disaster_type_other_test.dart` | `mobile/test/m2_disaster_reporting/disaster_type_other_test.dart` |
| `mobile/test/hazard_barangay_field_test.dart` | `mobile/test/m2_disaster_reporting/hazard_barangay_field_test.dart` |
| `mobile/test/multi_barangay_test.dart` | `mobile/test/m2_disaster_reporting/multi_barangay_test.dart` |
| `mobile/test/report_filters_test.dart` | `mobile/test/m2_disaster_reporting/report_filters_test.dart` |
| `mobile/test/report_paging_test.dart` | `mobile/test/m2_disaster_reporting/report_paging_test.dart` |
| `mobile/test/report_status_filters_test.dart` | `mobile/test/m2_disaster_reporting/report_status_filters_test.dart` |
| `mobile/test/sitios_and_sms_test.dart` | `mobile/test/m2_disaster_reporting/sitios_and_sms_test.dart` |
| `mobile/test/sms_original_test.dart` | `mobile/test/m2_disaster_reporting/sms_original_test.dart` |
| `mobile/test/sms_report_format_test.dart` | `mobile/test/m2_disaster_reporting/sms_report_format_test.dart` |
| `mobile/test/sms_unregistered_sender_test.dart` | `mobile/test/m2_disaster_reporting/sms_unregistered_sender_test.dart` |

#### `mobile/test/m4_donation_management/` (6 files)

| Old path | New path |
|---|---|
| `mobile/test/donation_additions_test.dart` | `mobile/test/m4_donation_management/donation_additions_test.dart` |
| `mobile/test/donation_entries_test.dart` | `mobile/test/m4_donation_management/donation_entries_test.dart` |
| `mobile/test/donation_info_test.dart` | `mobile/test/m4_donation_management/donation_info_test.dart` |
| `mobile/test/donor_security_test.dart` | `mobile/test/m4_donation_management/donor_security_test.dart` |
| `mobile/test/donor_typed_items_test.dart` | `mobile/test/m4_donation_management/donor_typed_items_test.dart` |
| `mobile/test/report_sheet_donate_test.dart` | `mobile/test/m4_donation_management/report_sheet_donate_test.dart` |

#### `mobile/test/m5_inventory/` (9 files)

| Old path | New path |
|---|---|
| `mobile/test/delivery_allocation_test.dart` | `mobile/test/m5_inventory/delivery_allocation_test.dart` |
| `mobile/test/inventory_view_test.dart` | `mobile/test/m5_inventory/inventory_view_test.dart` |
| `mobile/test/kit_contents_test.dart` | `mobile/test/m5_inventory/kit_contents_test.dart` |
| `mobile/test/pickup_dates_test.dart` | `mobile/test/m5_inventory/pickup_dates_test.dart` |
| `mobile/test/pickup_days_test.dart` | `mobile/test/m5_inventory/pickup_days_test.dart` |
| `mobile/test/receipt_count_dialog_test.dart` | `mobile/test/m5_inventory/receipt_count_dialog_test.dart` |
| `mobile/test/receive_entry_test.dart` | `mobile/test/m5_inventory/receive_entry_test.dart` |
| `mobile/test/receive_filters_test.dart` | `mobile/test/m5_inventory/receive_filters_test.dart` |
| `mobile/test/receive_paging_test.dart` | `mobile/test/m5_inventory/receive_paging_test.dart` |

#### `mobile/test/m6_city_confirmation/` (1 files)

| Old path | New path |
|---|---|
| `mobile/test/cmo_screens_test.dart` | `mobile/test/m6_city_confirmation/cmo_screens_test.dart` |

#### `mobile/test/m7_logistics_support/` (3 files)

| Old path | New path |
|---|---|
| `mobile/test/csws_drrmo_flow_test.dart` | `mobile/test/m7_logistics_support/csws_drrmo_flow_test.dart` |
| `mobile/test/csws_drrmo_lock_test.dart` | `mobile/test/m7_logistics_support/csws_drrmo_lock_test.dart` |
| `mobile/test/drrmo_dashboard_test.dart` | `mobile/test/m7_logistics_support/drrmo_dashboard_test.dart` |

#### `mobile/test/m8_delivery_tracking/` (4 files)

| Old path | New path |
|---|---|
| `mobile/test/acknowledgment_screen_test.dart` | `mobile/test/m8_delivery_tracking/acknowledgment_screen_test.dart` |
| `mobile/test/per_item_fulfillment_test.dart` | `mobile/test/m8_delivery_tracking/per_item_fulfillment_test.dart` |
| `mobile/test/short_deliveries_test.dart` | `mobile/test/m8_delivery_tracking/short_deliveries_test.dart` |
| `mobile/test/still_needed_chips_test.dart` | `mobile/test/m8_delivery_tracking/still_needed_chips_test.dart` |

#### `mobile/test/m9_dashboards/` (4 files)

| Old path | New path |
|---|---|
| `mobile/test/csws_dashboard_test.dart` | `mobile/test/m9_dashboards/csws_dashboard_test.dart` |
| `mobile/test/donor_dashboard_test.dart` | `mobile/test/m9_dashboards/donor_dashboard_test.dart` |
| `mobile/test/landing_redesign_test.dart` | `mobile/test/m9_dashboards/landing_redesign_test.dart` |
| `mobile/test/my_giving_real_data_test.dart` | `mobile/test/m9_dashboards/my_giving_real_data_test.dart` |

#### `mobile/test/shared/` (8 files)

| Old path | New path |
|---|---|
| `mobile/test/design_system_test.dart` | `mobile/test/shared/design_system_test.dart` |
| `mobile/test/kept_tabs_test.dart` | `mobile/test/shared/kept_tabs_test.dart` |
| `mobile/test/lookups_cache_test.dart` | `mobile/test/shared/lookups_cache_test.dart` |
| `mobile/test/paginated_list_test.dart` | `mobile/test/shared/paginated_list_test.dart` |
| `mobile/test/release_settings_test.dart` | `mobile/test/shared/release_settings_test.dart` |
| `mobile/test/web_headers_test.dart` | `mobile/test/shared/web_headers_test.dart` |
| `mobile/test/web_routes_test.dart` | `mobile/test/shared/web_routes_test.dart` |
| `mobile/test/widget_test.dart` | `mobile/test/shared/widget_test.dart` |
