## What changed
<!-- One or two sentences. Link the adviser item, e.g. "Item 5: one QR per donation". -->

## Screenshots (required for any screen change)
<!-- Pixel 8 emulator. Put light and dark side by side. -->

| Light | Dark | Text 200% |
|---|---|---|
|  |  |  |

## UI review gate (Fernandez checks these before approving)
- [ ] Uses design-system components (`AppButton`, `AppCard`, `StatusChip`, ...) instead of custom styling
- [ ] No hardcoded colors or font sizes in screens (no `Colors.grey`, hex, `Brand.ink`, `fontSize:`)
- [ ] Loading, empty and error states all work
- [ ] Readable in dark mode
- [ ] Nothing overflows or gets cut off at 200% text size
- [ ] Buttons and labels use sentence case and say what they do

## Definition of done
- [ ] Works on the emulator
- [ ] Backend checks the same rules as the frontend
- [ ] pytest covers new endpoints
- [ ] Notification fires (if in the event table)
- [ ] State changes written to the audit log
- [ ] `flutter analyze` and `flutter test` pass
- [ ] `alembic heads` shows one head (if you added a migration)
