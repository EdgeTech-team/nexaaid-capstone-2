# NexaAid design system

Owner: Fernandez (UI/UX lead). Code: `mobile/lib/design/`.
See every component live in **Profile > Developer tools > Design system
gallery**.

## Import

Screens that already import `ui/widgets.dart` get the design system
automatically. New files:

```dart
import '../design/design.dart';
```

## Rules

1. **Colors come from the theme.** Use `Theme.of(context).colorScheme`
   (`primary`, `onSurface`, `onSurfaceVariant`, `outlineVariant`, `error`).
   Never hardcode `Colors.grey`, `Colors.black` or hex values in a screen;
   they break dark mode. `Brand.ink` and `Brand.muted` are the old fixed
   colors: replace them with `onSurface` and `onSurfaceVariant` when you
   restyle your screens.
2. **Text comes from the text theme.** `headlineSmall` for screen titles,
   `titleLarge` for section headers, `titleMedium` for card titles,
   `bodyMedium` for normal text, `bodySmall` for secondary info.
   No hardcoded `fontSize`.
3. **Spacing uses the 8-point scale.** `Space.xs` (8), `Space.md` (16),
   `Space.lg` (24); gaps are `Gaps.v8`, `Gaps.v16`, `Gaps.h8`. Screen
   padding is `Space.page`.
4. **One color per status.** Show statuses with `StatusChip(status)` and
   priorities with `PriorityChip(priority)`. Never pick a status color by
   hand. New status? Add it to `lib/design/status.dart` (PR to Fernandez).
5. **Every screen that loads data has three states:** loading
   (`SkeletonList` or `SkeletonCard`), empty (`EmptyView` that says what
   will appear and what to do), and error (`ErrorView.forStatus` with
   "Try again"). The shared `Loader` already does loading and error.
6. **Donate actions are yellow.** Use `AppButtonVariant.donate` for every
   "Donate" button and nothing else.
7. **One primary button per screen.** Others are `secondary`, `tonal` or
   `text`. Destructive actions (reject, decline) are `danger`.
8. **Touch targets are at least 48 px tall.** The button and input themes
   already do this; don't shrink them.

## Components

| Need | Use |
|---|---|
| Button | `AppButton('Save changes', onPressed: _save, loading: busy)` |
| Text input | `AppTextField(label: 'Email', icon: Icons.mail_outline)` |
| Password with eye button | `AppTextField(label: 'Password', password: true)` |
| Card | `AppCard(child: ..., onTap: ...)` |
| Section title | `SectionHeader('Donation history', action: TextButton(...))` |
| Dashboard numbers | `StatCardGrid([StatCard(label:, value:, icon:)])` |
| Status | `StatusChip('In Transit')` |
| Priority | `PriorityChip('Critical')` |
| Report progress | `FulfillmentBar(delivered: 40, needed: 100)` |
| Donation lifecycle | `StatusTimeline(steps: donationLifecycle, labels: donationLifecycleLabels, current: status)` |
| Loading | `SkeletonList()`, `SkeletonCard()`, `Skeleton(width: 120)` |
| Nothing to show | `EmptyView(title:, message:, action:)` |
| Failure | `ErrorView.forStatus(result.status, result.errorText, onRetry: _reload)` |

## Writing in the UI

- Sentence case everywhere: "Save changes", not "Save Changes".
- Buttons say what happens: "Confirm receipt", not "Submit".
- Errors say what happened and what to do: "Can't reach the server.
  Check that uvicorn is running." Never just "Error".
- Empty screens invite action: "No donations yet. Pick a report that
  needs help."

## Type and color choices (for the manuscript)

- **Lexend** for headings: designed to reduce visual stress and improve
  reading speed. **Source Sans 3** for body text: clear at small sizes.
- **Harbor teal** `#0B6E69` primary (kept from the earlier prototype),
  **life-vest yellow** `#F5B82E` reserved for donate actions.
- Light and dark themes, tested at 200% text size.
