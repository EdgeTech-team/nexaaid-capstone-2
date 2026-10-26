import 'package:flutter/material.dart';

import '../design/design.dart';
import 'location_picker.dart' show PickupRules, ServiceArea;

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

// ---------------------------------------------------------------------------
// Door to Door pickup DATES (Oct 23). The donor taps specific dates on a
// calendar instead of weekdays: "home on Mon, Oct 26 and Wed, Oct 28". Only
// CSWS pickup days from today up to maxDaysAhead can be tapped. The server
// gets ISO dates ("2026-10-26") in pickup_dates.
// ---------------------------------------------------------------------------

const _monthShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Dates from the server (["2026-10-26", ...]). Unknown parts are skipped.
Set<DateTime> pickupDatesOf(Object? raw) {
  final parts = raw is List ? raw : '${raw ?? ''}'.split(',');
  return {
    for (final p in parts)
      if (DateTime.tryParse('$p'.trim()) case final d?) _dayOnly(d),
  };
}

/// DateTime(2026, 10, 26) -> "2026-10-26".
String pickupDateIso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// "Mon, Oct 26"
String pickupDateShort(DateTime d) =>
    '${pickupDayShort[d.weekday - 1]}, ${_monthShort[d.month - 1]} ${d.day}';

/// Sorted, without duplicates, for chips and the request body.
List<DateTime> sortedDates(Iterable<DateTime> dates) =>
    dates.map(_dayOnly).toSet().toList()..sort();

/// Pop-out calendar where the donor taps the dates they are home.
/// Returns the chosen dates, or null if the donor closed it.
Future<Set<DateTime>?> pickPickupDates(
  BuildContext context,
  PickupRules rules, {
  Set<DateTime> current = const {},
}) {
  return showModalBottomSheet<Set<DateTime>>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _PickupDatesSheet(rules: rules, initial: current),
  );
}

class _PickupDatesSheet extends StatefulWidget {
  final PickupRules rules;
  final Set<DateTime> initial;
  const _PickupDatesSheet({required this.rules, required this.initial});

  @override
  State<_PickupDatesSheet> createState() => _PickupDatesSheetState();
}

class _PickupDatesSheetState extends State<_PickupDatesSheet> {
  // Dates no longer allowed (passed, or CSWS changed its days) are dropped.
  late Set<DateTime> dates = {
    for (final d in widget.initial)
      if (widget.rules.isPickupDate(d)) _dayOnly(d),
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final chosen = sortedDates(dates);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('When are you home?', style: t.titleLarge),
            Gaps.v4,
            Text(
              'Tap the dates CSWS can come for your donation. '
              'They will pick it up on one of these dates.',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v16,
            PickupCalendar(
              rules: widget.rules,
              selected: dates,
              onChanged: (d) => setState(() => dates = d),
            ),
            Gaps.v12,
            if (chosen.isEmpty)
              Text(
                'No date chosen yet',
                textAlign: TextAlign.center,
                style: t.titleSmall?.copyWith(color: cs.onSurfaceVariant),
              )
            else
              PickupDateChips(
                chosen,
                onRemove: (d) => setState(() => dates = {...dates}..remove(d)),
              ),
            Gaps.v16,
            PickupHoursNote(widget.rules),
            Gaps.v8,
            Text(
              'Faded dates have no pickups.',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v16,
            Row(
              children: [
                TextButton(
                  onPressed: dates.isEmpty
                      ? null
                      : () => setState(() => dates = {}),
                  child: const Text('Clear all'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: dates.isEmpty
                      ? null
                      : () => Navigator.pop(context, dates),
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

/// A month calendar (Mon to Sun) where several dates can be on at once.
/// Only [PickupRules.isPickupDate] dates can be tapped.
class PickupCalendar extends StatefulWidget {
  final PickupRules rules;
  final Set<DateTime> selected;
  final ValueChanged<Set<DateTime>> onChanged;

  const PickupCalendar({
    super.key,
    required this.rules,
    required this.selected,
    required this.onChanged,
  });

  @override
  State<PickupCalendar> createState() => _PickupCalendarState();
}

class _PickupCalendarState extends State<PickupCalendar> {
  late final DateTime _today = _dayOnly(PickupRules.phNow());
  late final DateTime _first = DateTime(_today.year, _today.month);
  late final DateTime _last = () {
    final end = _today.add(Duration(days: widget.rules.maxDaysAhead));
    return DateTime(end.year, end.month);
  }();

  // Opens on the month of the first chosen date, else this month.
  late DateTime _month = () {
    final chosen = sortedDates(widget.selected);
    return chosen.isEmpty
        ? _first
        : DateTime(chosen.first.year, chosen.first.month);
  }();

  void _toggle(DateTime d) {
    final next = {...widget.selected};
    next.contains(d) ? next.remove(d) : next.add(d);
    widget.onChanged(next);
  }

  void _go(int months) =>
      setState(() => _month = DateTime(_month.year, _month.month + months));

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = DateTime(_month.year, _month.month).weekday - 1; // Mon = 0

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              onPressed: _month.isAfter(_first) ? () => _go(-1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                '${_monthNames[_month.month - 1]} ${_month.year}',
                textAlign: TextAlign.center,
                style: t.titleMedium,
              ),
            ),
            IconButton(
              tooltip: 'Next month',
              onPressed: _month.isBefore(_last) ? () => _go(1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Gaps.v4,
        Row(
          children: [
            for (final l in pickupDayLetters)
              Expanded(
                child: Text(
                  l,
                  textAlign: TextAlign.center,
                  style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
          ],
        ),
        Gaps.v4,
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          children: [
            for (var i = 0; i < lead; i++) const SizedBox.shrink(),
            for (var day = 1; day <= daysInMonth; day++)
              _DateCell(
                date: DateTime(_month.year, _month.month, day),
                on: widget.selected.contains(
                  DateTime(_month.year, _month.month, day),
                ),
                available: widget.rules.isPickupDate(
                  DateTime(_month.year, _month.month, day),
                ),
                today: DateTime(_month.year, _month.month, day) == _today,
                onTap: _toggle,
              ),
          ],
        ),
      ],
    );
  }
}

class _DateCell extends StatelessWidget {
  final DateTime date;
  final bool on;
  final bool available;
  final bool today;
  final ValueChanged<DateTime> onTap;

  const _DateCell({
    required this.date,
    required this.on,
    required this.available,
    required this.today,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final fg = !available
        ? cs.onSurfaceVariant.withValues(alpha: 0.38)
        : on
        ? cs.onPrimary
        : cs.onSurface;
    return Semantics(
      button: true,
      toggled: on,
      enabled: available,
      label:
          '${pickupDayNames[date.weekday - 1]}, '
          '${_monthNames[date.month - 1]} ${date.day}'
          '${available ? '' : ', no pickups'}',
      excludeSemantics: true,
      onTap: available ? () => onTap(date) : null,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.curve,
        decoration: BoxDecoration(
          color: on ? cs.primary : Colors.transparent,
          shape: BoxShape.circle,
          border: today && !on
              ? Border.all(color: cs.primary, width: 1.5)
              : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: available ? () => onTap(date) : null,
            child: Center(
              child: Text(
                '${date.day}',
                style: t.bodyMedium?.copyWith(
                  color: fg,
                  fontWeight: on || today ? FontWeight.w800 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The chosen dates as chips ("Mon, Oct 26"). [onRemove] adds an x;
/// [highlight] (the planned date) is filled, the others are light.
class PickupDateChips extends StatelessWidget {
  final List<DateTime> dates;
  final ValueChanged<DateTime>? onRemove;
  final DateTime? highlight;
  final bool dense;

  const PickupDateChips(
    this.dates, {
    super.key,
    this.onRemove,
    this.highlight,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final pad = dense ? 6.0 : Space.xs + 2;
    return Wrap(
      spacing: Space.xxs,
      runSpacing: Space.xxs,
      children: [
        for (final d in dates)
          Builder(
            builder: (context) {
              final strong = highlight == null || d == highlight;
              return Container(
                padding: EdgeInsets.fromLTRB(
                  pad,
                  dense ? 1 : 2,
                  onRemove == null ? pad : 2,
                  dense ? 1 : 2,
                ),
                decoration: BoxDecoration(
                  color: strong ? cs.primary : cs.primaryContainer,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      pickupDateShort(d),
                      style: (dense ? t.labelSmall : t.labelLarge)?.copyWith(
                        color: strong ? cs.onPrimary : cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (onRemove != null)
                      InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => onRemove!(d),
                        child: Padding(
                          padding: const EdgeInsets.all(2),
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: cs.onPrimary,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }
}

/// "Door-to-Door Pickup Coverage": where pickup is offered, and what to do
/// outside it (choose Drop Off).
class ServiceAreaCard extends StatelessWidget {
  final List<ServiceArea> areas;
  const ServiceAreaCard(this.areas, {super.key});

  /// "Mandaue" -> "Mandaue City"; a partly served Cebu City (barangays
  /// set in the backend .env) -> "Northern Cebu City".
  static String title(ServiceArea a) {
    if (a.name == 'Cebu City' && a.barangays.isNotEmpty) {
      return 'Northern Cebu City';
    }
    if (a.name == 'Consolacion' || a.name.endsWith('City')) return a.name;
    return '${a.name} City';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.local_shipping_outlined, size: 20, color: cs.primary),
              Gaps.h8,
              Expanded(
                child: Text(
                  'Door-to-Door Pickup Coverage',
                  style: t.titleSmall,
                ),
              ),
            ],
          ),
          Gaps.v4,
          Text(
            'Pickup is available only in these areas:',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v8,
          for (final a in areas)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.check_circle_outline,
                    size: 18,
                    color: AppColors.success,
                  ),
                  Gaps.h8,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title(a),
                          style: t.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (a.note.isNotEmpty)
                          Text(
                            a.note,
                            style: t.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          const Divider(height: Space.md),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.place_outlined, size: 18, color: cs.onSurfaceVariant),
              Gaps.h8,
              Expanded(
                child: Text.rich(
                  const TextSpan(
                    children: [
                      TextSpan(
                        text: 'Outside the service area? ',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(text: 'Please choose '),
                      TextSpan(
                        text: 'Drop Off',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text:
                            ' and bring your donation to an approved '
                            'collection point.',
                      ),
                    ],
                  ),
                  style: t.bodySmall,
                ),
              ),
            ],
          ),
          Gaps.v4,
          Text(
            'Pickup is still subject to volunteer and vehicle availability.',
            style: t.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Mandaue City, Cebu City, Consolacion and Lapu-Lapu City".
String serviceAreasSentence(List<ServiceArea> areas) {
  final names = areas.map(ServiceAreaCard.title).toList();
  if (names.length < 2) return names.join();
  return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
}

/// Shown as soon as the map check finds the landmark outside the Door to
/// Door service areas: a sorry, why (a current limit of the app), and a
/// one-tap switch to Drop Off.
///
/// Information, not an error (adviser, Oct 23): neutral surface and brand
/// colours, never red. On phones the two actions stack full width; on wider
/// screens they sit side by side at the end.
class OutOfAreaNotice extends StatelessWidget {
  final String? place; // e.g. "Carcar", from the map
  final List<ServiceArea> areas;
  final VoidCallback onDropOff;
  final VoidCallback onChangeLandmark;

  const OutOfAreaNotice({
    super.key,
    required this.place,
    required this.areas,
    required this.onDropOff,
    required this.onChangeLandmark,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final where = (place ?? '').trim().isEmpty ? 'this area' : place!;
    final dropOff = FilledButton.icon(
      onPressed: onDropOff,
      icon: const Icon(Icons.store_mall_directory_outlined),
      label: const Text('Switch to Drop Off'),
    );
    final change = TextButton.icon(
      onPressed: onChangeLandmark,
      icon: const Icon(Icons.edit_location_alt_outlined),
      label: const Text('Choose another landmark'),
    );
    return Semantics(
      liveRegion: true,
      container: true,
      child: Container(
        padding: const EdgeInsets.all(Space.md),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(color: cs.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.info_outline,
                    size: 22,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                Gaps.h12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Sorry, door-to-door pickup isn’t available '
                        'in $where yet',
                        style: t.titleSmall?.copyWith(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                      Gaps.v4,
                      Text(
                        'For now we pick up only in '
                        '${serviceAreasSentence(areas)}. This is a current '
                        'limitation of NexaAid, and we’re working to reach '
                        'more areas.',
                        style: t.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Gaps.v12,
            // The way forward, in the brand colour.
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.sm,
                vertical: Space.xs + 2,
              ),
              decoration: BoxDecoration(
                color: cs.primaryContainer.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.volunteer_activism_outlined,
                    size: 20,
                    color: cs.primary,
                  ),
                  Gaps.h8,
                  Expanded(
                    child: Text(
                      'You can still help: choose Drop Off and bring your '
                      'donation to the CSWS collection point.',
                      style: t.bodyMedium?.copyWith(
                        color: cs.onSurface,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Gaps.v12,
            LayoutBuilder(
              builder: (context, box) => box.maxWidth < 420
                  // Phone: big full-width targets, main action first.
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [dropOff, Gaps.v4, change],
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [change, Gaps.h8, dropOff],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small line under the landmark while the map is checked, or when the
/// place is covered.
class CoverageStatusLine extends StatelessWidget {
  final bool checking;
  const CoverageStatusLine({super.key, required this.checking});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        if (checking)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          const Icon(
            Icons.check_circle_outline,
            size: 18,
            color: AppColors.success,
          ),
        Gaps.h8,
        Expanded(
          child: Text(
            checking
                ? 'Checking the map for pickup coverage…'
                : 'Door-to-door pickup is available at this landmark.',
            style: t.bodySmall?.copyWith(
              color: checking ? cs.onSurfaceVariant : AppColors.success,
              fontWeight: checking ? null : FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
