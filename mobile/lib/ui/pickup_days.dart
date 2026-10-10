import 'package:flutter/material.dart';

import '../design/design.dart';
import 'location_picker.dart' show PickupRules;

// ---------------------------------------------------------------------------
// Door to Door pickup days (Oct 10 notes).
//
// Donors no longer pick one date and time. They tap the days they are home
// (M / T / W / Th / F ...) and CSWS collects on one of those days within the
// pickup hours. The Disaster Unit filters the pickup map with the same day
// buttons, so both sides speak the same "days" language.
// Days use 1 = Monday ... 7 = Sunday, like the backend.
// ---------------------------------------------------------------------------

const pickupDayLetters = ['M', 'T', 'W', 'Th', 'F', 'Sa', 'Su'];
const pickupDayShort = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const pickupDayNames = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

/// Days from the server ([1, 3] or "1,3"). Unknown parts are skipped.
Set<int> pickupDaysOf(Object? raw) {
  final parts = raw is List ? raw : '${raw ?? ''}'.split(',');
  return {
    for (final p in parts)
      if (int.tryParse('$p') case final d? when d >= 1 && d <= 7) d,
  };
}

/// {1, 3, 5} -> "Mon, Wed, Fri"; {1, 2, 3, 4, 5} -> "Mon to Fri".
/// Same rule as backend pickup_days_label.
String pickupDaysLabel(Iterable<int> days) {
  final d = days.toSet().toList()..sort();
  if (d.isEmpty) return '';
  final run = d.length > 2 && d.last - d.first == d.length - 1;
  if (run) {
    return '${pickupDayShort[d.first - 1]} to ${pickupDayShort[d.last - 1]}';
  }
  return d.map((x) => pickupDayShort[x - 1]).join(', ');
}

/// "9:00 AM to 5:00 PM" from the pickup rules.
String pickupHoursLabel(PickupRules rules) {
  String h(int hour) =>
      '${hour % 12 == 0 ? 12 : hour % 12}:00 '
      '${hour < 12 ? 'AM' : 'PM'}';
  return '${h(rules.startHour)} to ${h(rules.endHour)}';
}

/// A week of round day buttons: tap to turn a day on or off.
/// [enabled] limits which days can be chosen (CSWS pickup days); the others
/// are shown faded so the donor sees the whole week.
class PickupDayToggles extends StatelessWidget {
  final Set<int> selected;
  final ValueChanged<Set<int>> onChanged;
  final Set<int>? enabled;

  /// Smaller buttons, for filter bars above the map.
  final bool dense;

  /// Shown under a day, e.g. how many pickups fall on it.
  final Map<int, int>? counts;

  const PickupDayToggles({
    super.key,
    required this.selected,
    required this.onChanged,
    this.enabled,
    this.dense = false,
    this.counts,
  });

  @override
  Widget build(BuildContext context) {
    final size = dense ? 40.0 : 46.0;
    return LayoutBuilder(
      builder: (context, box) {
        // Seven buttons share the row; they shrink on narrow phones.
        final gap = dense ? 4.0 : 6.0;
        final fit = ((box.maxWidth - gap * 6) / 7).clamp(32.0, size);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var d = 1; d <= 7; d++)
              _DayButton(
                letter: pickupDayLetters[d - 1],
                name: pickupDayNames[d - 1],
                size: fit,
                on: selected.contains(d),
                available: enabled == null || enabled!.contains(d),
                count: counts?[d],
                onTap: () {
                  final next = {...selected};
                  next.contains(d) ? next.remove(d) : next.add(d);
                  onChanged(next);
                },
              ),
          ],
        );
      },
    );
  }
}

class _DayButton extends StatelessWidget {
  final String letter;
  final String name;
  final double size;
  final bool on;
  final bool available;
  final int? count;
  final VoidCallback onTap;

  const _DayButton({
    required this.letter,
    required this.name,
    required this.size,
    required this.on,
    required this.available,
    required this.count,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final bg = on ? cs.primary : Colors.transparent;
    final fg = !available
        ? cs.onSurfaceVariant.withValues(alpha: 0.38)
        : on
        ? cs.onPrimary
        : cs.onSurface;
    final border = on
        ? cs.primary
        : available
        ? cs.outline
        : cs.outlineVariant.withValues(alpha: 0.5);
    // One clear label for screen readers ("Wednesday, 6 pickups") instead of
    // reading the letter, the tooltip and the count one by one.
    return Semantics(
      button: true,
      toggled: on,
      enabled: available,
      label: !available
          ? '$name, no pickups'
          : count == null
          ? name
          : '$name, $count pickup${count == 1 ? '' : 's'}',
      excludeSemantics: true,
      onTap: available ? onTap : null,
      child: Tooltip(
        message: available ? name : '$name: no pickups',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: Motion.fast,
              curve: Motion.curve,
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
                border: Border.all(color: border, width: on ? 2 : 1.25),
                boxShadow: on
                    ? [
                        BoxShadow(
                          color: cs.primary.withValues(alpha: 0.28),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ]
                    : null,
              ),
              child: Material(
                type: MaterialType.transparency,
                shape: const CircleBorder(),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: available ? onTap : null,
                  child: Center(
                    child: Text(
                      letter,
                      style: t.labelLarge?.copyWith(
                        color: fg,
                        fontWeight: on ? FontWeight.w800 : FontWeight.w600,
                        decoration: available
                            ? null
                            : TextDecoration.lineThrough,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (count != null) ...[
              const SizedBox(height: 2),
              Text(
                '$count',
                style: t.labelSmall?.copyWith(
                  color: count! > 0 ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The pickup hours note shown with the day buttons.
class PickupHoursNote extends StatelessWidget {
  final PickupRules rules;
  const PickupHoursNote(this.rules, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs + 2,
      ),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.schedule, size: 18, color: cs.onSecondaryContainer),
          Gaps.h8,
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  const TextSpan(text: 'Pickup hours are '),
                  TextSpan(
                    text: pickupHoursLabel(rules),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(text: '.'),
                ],
              ),
              style: t.bodyMedium?.copyWith(color: cs.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Pop-out where the donor taps the days they are home for the pickup.
/// Returns the chosen days, or null if the donor closed it.
Future<Set<int>?> pickPickupDays(
  BuildContext context,
  PickupRules rules, {
  Set<int> current = const {},
}) {
  return showModalBottomSheet<Set<int>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _PickupDaysSheet(rules: rules, initial: current),
  );
}

class _PickupDaysSheet extends StatefulWidget {
  final PickupRules rules;
  final Set<int> initial;
  const _PickupDaysSheet({required this.rules, required this.initial});

  @override
  State<_PickupDaysSheet> createState() => _PickupDaysSheetState();
}

class _PickupDaysSheetState extends State<_PickupDaysSheet> {
  late Set<int> days = widget.initial.intersection(widget.rules.days);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final allOn = days.length == widget.rules.days.length;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('When are you home?', style: t.titleLarge),
            Gaps.v4,
            Text(
              'Tap every day CSWS can come for your donation. '
              'They will pick it up on one of these days.',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v24,
            PickupDayToggles(
              selected: days,
              enabled: widget.rules.days,
              onChanged: (d) => setState(() => days = d),
            ),
            Gaps.v12,
            AnimatedSwitcher(
              duration: Motion.fast,
              child: Text(
                days.isEmpty
                    ? 'No day chosen yet'
                    : 'Home on ${pickupDaysLabel(days)}',
                key: ValueKey(days.length),
                textAlign: TextAlign.center,
                style: t.titleSmall?.copyWith(
                  color: days.isEmpty ? cs.onSurfaceVariant : cs.primary,
                ),
              ),
            ),
            Gaps.v16,
            PickupHoursNote(widget.rules),
            if (widget.rules.days.length < 7) ...[
              Gaps.v8,
              Text(
                'Days with a line through them have no pickups.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            Gaps.v16,
            Row(
              children: [
                TextButton(
                  onPressed: () => setState(
                    () => days = allOn ? <int>{} : {...widget.rules.days},
                  ),
                  child: Text(allOn ? 'Clear all' : 'Any pickup day'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: days.isEmpty
                      ? null
                      : () => Navigator.pop(context, days),
                  icon: const Icon(Icons.check),
                  label: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
