import 'package:flutter/material.dart';

import 'location_picker.dart' show PickupRules;
import 'pickup_actions.dart' show ContactButtons, openNavigation;
import 'pickup_days.dart';
import 'pickup_plan.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Door to Door pickups as a list (Oct 12 notes): the "List" side of the
// Map / List switch on the CSWS Main Office Pickups tab.
//
// The map answers "which route today?"; this list answers "who is waiting
// where, and when are they home?". It uses the same plan as the map
// (GET /donations/pickup-plan), so a stop has the same planned date here,
// but the list has its own sorting:
//   * Group by  Day       one section per pickup weekday (Mon to Fri): every
//                         stop whose donors are home that day. A stop home
//                         on Mon and Wed is listed under both.
//               Suggested one section per date the planner suggests, in
//                         route order, then the stops that could not be
//                         planned (with the reason).
//   * Opens on TODAY (who is home today), like the map; the Filter button
//     picks another day or All days.
//   * Search    landmark, address, barangay, donor or QR reference.
// Inside a section: planned date, then route order, then landmark A to Z.
// Tapping a row opens the same stop details as tapping a pin.
// ---------------------------------------------------------------------------

enum PickupGroup { day, planned }

class PickupListView extends StatefulWidget {
  final PickupPlan plan;
  final PickupRules rules;

  /// The Map / List switch and the title, shown at the top of the list.
  final Widget header;

  /// Shown at the bottom (the requests sent to DRRMO).
  final Widget? footer;

  /// "Home on" day when the list opens (the map passes today's weekday).
  final int? initialHomeOn;
  final Future<void> Function() onRefresh;
  final void Function(PlanStop stop) onOpenStop;
  final void Function(PlanDonation d)? onOpenFollowUp;

  const PickupListView({
    super.key,
    required this.plan,
    required this.rules,
    required this.header,
    this.footer,
    this.initialHomeOn,
    required this.onRefresh,
    required this.onOpenStop,
    this.onOpenFollowUp,
  });

  @override
  State<PickupListView> createState() => _PickupListViewState();
}

class _PickupListViewState extends State<PickupListView> {
  PickupGroup _group = PickupGroup.day;
  late int? _homeOn = widget.initialHomeOn; // weekday filter, null = any
  String _query = '';

  bool _matches(PlanStop s) {
    if (_homeOn != null && !s.days.contains(_homeOn)) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    final text = [
      s.landmark,
      s.address,
      s.barangay ?? '',
      for (final d in s.donations) ...[d.donor, d.ref],
    ].join(' ').toLowerCase();
    return text.contains(q);
  }

  bool _matchesFollowUp(PlanDonation d) {
    if (_homeOn != null && !d.days.contains(_homeOn)) return false;
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [
      d.landmark,
      d.address,
      d.barangay ?? '',
      d.donor,
      d.ref,
    ].join(' ').toLowerCase().contains(q);
  }

  /// Planned date, then route order, then landmark A to Z.
  int _byPlan(PlanStop a, PlanStop b) {
    final da = a.plannedDate, db = b.plannedDate;
    if (da != null && db != null && da != db) return da.compareTo(db);
    if (da == null && db != null) return 1;
    if (da != null && db == null) return -1;
    final oa = a.order ?? 1 << 20, ob = b.order ?? 1 << 20;
    if (oa != ob) return oa.compareTo(ob);
    return a.landmark.toLowerCase().compareTo(b.landmark.toLowerCase());
  }

  /// (title, subtitle, stops) per section, in display order.
  List<(String, String?, List<PlanStop>)> _sections(List<PlanStop> stops) {
    switch (_group) {
      case PickupGroup.day:
        final days = widget.rules.days.toList()..sort();
        final out = <(String, String?, List<PlanStop>)>[];
        for (final wd in days) {
          if (_homeOn != null && wd != _homeOn) continue;
          final list = stops.where((s) => s.days.contains(wd)).toList()
            // Stops planned on this weekday first, in route order.
            ..sort((a, b) {
              final pa = a.plannedDate?.weekday == wd ? 0 : 1;
              final pb = b.plannedDate?.weekday == wd ? 0 : 1;
              return pa != pb ? pa.compareTo(pb) : _byPlan(a, b);
            });
          if (list.isEmpty) continue;
          out.add((
            pickupDayNames[wd - 1],
            '${list.where((s) => s.plannedDate?.weekday == wd).length} '
                'planned on the next ${pickupDayNames[wd - 1]}',
            list,
          ));
        }
        final none = stops
            .where((s) => s.days.intersection(widget.rules.days).isEmpty)
            .toList();
        if (none.isNotEmpty && _homeOn == null) {
          out.add((
            'No CSWS pickup day',
            'Donors home only on other days',
            none,
          ));
        }
        return out;
      case PickupGroup.planned:
        final out = <(String, String?, List<PlanStop>)>[];
        for (final run in widget.plan.runs) {
          final list = widget.plan
              .stopsOn(run.date)
              .where(stops.contains)
              .toList();
          if (list.isEmpty) continue;
          out.add((
            planDateLabel(run.date),
            'Done about ${run.finishLabel}',
            list,
          ));
        }
        final rest = stops.where((s) => !s.planned).toList()..sort(_byPlan);
        if (rest.isNotEmpty) out.add(('Not planned', null, rest));
        return out;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final p = widget.plan;
    final stops = p.stops.where(_matches).toList();
    final followUp = p.followUp.where(_matchesFollowUp).toList();
    final sections = _sections(stops);
    final days = widget.rules.days.toList()..sort();

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          Space.md,
          Space.sm,
          Space.md,
          Space.xl,
        ),
        children: [
          widget.header,
          Gaps.v12,
          TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search landmark, donor or QR',
              isDense: true,
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          Gaps.v12,
          Row(
            children: [
              Expanded(
                child: Text(
                  _homeOn == null
                      ? 'Showing every waiting stop'
                      : _homeOn == p.today.weekday
                      ? 'Showing who is home today'
                      : 'Showing who is home on '
                            '${pickupDayNames[_homeOn! - 1]}',
                  style: t.titleSmall,
                ),
              ),
              DayFilterButton(
                weekday: _homeOn,
                todayWeekday: p.today.weekday,
                onPressed: () async {
                  final v = await showDayFilter(
                    context,
                    current: _homeOn,
                    todayWeekday: p.today.weekday,
                    pickupDays: days,
                    countOn: (wd) =>
                        p.stops.where((s) => s.days.contains(wd)).length,
                    allCount: p.stops.length,
                  );
                  if (v != null)
                    setState(() => _homeOn = v == kAllDays ? null : v);
                },
              ),
            ],
          ),
          Gaps.v12,
          Text('Group by', style: t.titleSmall),
          Gaps.v4,
          SegmentedButton<PickupGroup>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: PickupGroup.day,
                icon: Icon(Icons.calendar_view_week_outlined),
                label: Text('Day'),
              ),
              ButtonSegment(
                value: PickupGroup.planned,
                icon: Icon(Icons.route_outlined),
                label: Text('Suggested'),
              ),
            ],
            selected: {_group},
            onSelectionChanged: (v) => setState(() => _group = v.first),
          ),
          Gaps.v8,
          Text(
            '${stops.length} stop${stops.length == 1 ? '' : 's'}'
            '${followUp.isEmpty ? '' : ' · ${followUp.length} without a map pin'}',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (stops.isEmpty && followUp.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: Space.md),
              child: AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.filter_alt_off_outlined,
                  title: p.stops.isEmpty && p.followUp.isEmpty
                      ? 'No Door to Door pickups waiting'
                      : 'No pickups match',
                  message: p.stops.isEmpty && p.followUp.isEmpty
                      ? null
                      : 'Try another day or clear the search.',
                ),
              ),
            ),
          for (final (title, subtitle, list) in sections) ...[
            SectionHeader('$title (${list.length})', subtitle: subtitle),
            for (final s in list)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: StopRow(
                  stop: s,
                  number: _group == PickupGroup.planned ? s.order : null,
                  selected: false,
                  onTap: () => widget.onOpenStop(s),
                ),
              ),
          ],
          if (followUp.isNotEmpty) ...[
            const SectionHeader(
              'Needs follow-up',
              subtitle:
                  'No map pin: the donor typed a landmark without choosing '
                  'a suggestion. Call to confirm the place.',
            ),
            for (final d in followUp)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: FollowUpRow(
                  d: d,
                  onOpen: widget.onOpenFollowUp == null
                      ? null
                      : () => widget.onOpenFollowUp!(d),
                ),
              ),
          ],
          if (widget.footer != null) widget.footer!,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Day filter, shared by the map and the list (Oct 12 notes): both open on
// TODAY automatically; this button is only for looking at another day.
// ---------------------------------------------------------------------------

/// Returned by [showDayFilter] for "All days".
const kAllDays = 0;

/// "Today", "Wed" or "All days" for the filter button.
String dayFilterLabel(int? weekday, int todayWeekday) => weekday == null
    ? 'All days'
    : weekday == todayWeekday
    ? 'Today'
    : pickupDayShort[weekday - 1];

/// The "Filter" button: shows the day being shown, opens [showDayFilter].
class DayFilterButton extends StatelessWidget {
  final int? weekday; // null = all days
  final int todayWeekday;
  final VoidCallback onPressed;
  const DayFilterButton({
    super.key,
    required this.weekday,
    required this.todayWeekday,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final filtered = weekday != todayWeekday;
    final label = Text(dayFilterLabel(weekday, todayWeekday));
    const icon = Icon(Icons.filter_list, size: 18);
    return filtered
        ? FilledButton.icon(onPressed: onPressed, icon: icon, label: label)
        : OutlinedButton.icon(onPressed: onPressed, icon: icon, label: label);
  }
}

/// Pop-up to pick the day: Today first, the other pickup days, All days.
/// Each shows how many stops have a donor home. Returns the weekday,
/// [kAllDays], or null if closed.
Future<int?> showDayFilter(
  BuildContext context, {
  required int? current,
  required int todayWeekday,
  required List<int> pickupDays,
  required int Function(int weekday) countOn,
  required int allCount,
}) {
  return showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    builder: (sheet) {
      final t = Theme.of(sheet).textTheme;
      final cs = Theme.of(sheet).colorScheme;
      Widget option(int value, String title, int count, {bool today = false}) {
        final selected = value == kAllDays ? current == null : current == value;
        return ListTile(
          leading: Icon(
            selected ? Icons.radio_button_checked : Icons.radio_button_off,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
          title: Text(
            title,
            style: today ? const TextStyle(fontWeight: FontWeight.w700) : null,
          ),
          trailing: Text(
            '$count stop${count == 1 ? '' : 's'}',
            style: t.labelLarge?.copyWith(
              color: count == 0 ? cs.onSurfaceVariant : cs.primary,
            ),
          ),
          onTap: () => Navigator.pop(sheet, value),
        );
      }

      final days = [...pickupDays]..sort();
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.lg,
                  0,
                  Space.lg,
                  Space.xs,
                ),
                child: Text('Who is home on', style: t.titleMedium),
              ),
              if (days.contains(todayWeekday))
                option(
                  todayWeekday,
                  'Today (${pickupDayNames[todayWeekday - 1]})',
                  countOn(todayWeekday),
                  today: true,
                ),
              for (final wd in days)
                if (wd != todayWeekday)
                  option(wd, pickupDayNames[wd - 1], countOn(wd)),
              const Divider(height: 1),
              option(kAllDays, 'All days', allCount),
            ],
          ),
        ),
      );
    },
  );
}

/// One stop in a list (under the map, or the list view), with Navigate.
class StopRow extends StatelessWidget {
  final PlanStop stop;
  final int? number;
  final bool selected;
  final VoidCallback onTap;

  /// Show "Brgy. ..." under the address when the server found one.
  final bool showBarangay;

  const StopRow({
    super.key,
    required this.stop,
    required this.number,
    required this.selected,
    required this.onTap,
    this.showBarangay = true,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final s = stop;
    final far = s.far;
    final color = far ? farGrey : cs.primary;
    final items = s.items;
    return AnimatedContainer(
      duration: Motion.fast,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: selected ? cs.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: AppCard(
        onTap: onTap,
        padding: const EdgeInsets.all(Space.sm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: s.lastChance
                    ? Border.all(color: AppColors.vest, width: 3)
                    : null,
              ),
              child: number != null
                  ? Text(
                      '$number',
                      style: t.labelLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                      ),
                    )
                  : Icon(
                      far ? Icons.priority_high : Icons.location_on,
                      size: 18,
                      color: Colors.white,
                    ),
            ),
            Gaps.h12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.landmark.isEmpty ? 'No landmark' : s.landmark,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleSmall,
                  ),
                  if (s.address.isNotEmpty)
                    Text(
                      s.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  if (showBarangay && s.barangay != null)
                    Text(
                      'Brgy. ${s.barangay}',
                      style: t.labelMedium?.copyWith(
                        color: cs.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  Gaps.v4,
                  Text(
                    [
                      s.countLine,
                      if (s.heavy) 'heavy',
                      if (number == null && s.plannedDate != null)
                        'suggested ${planDateLabel(s.plannedDate!)}',
                    ].join(' · '),
                    style: t.bodyMedium,
                  ),
                  if (items.isNotEmpty)
                    Text(
                      items.take(2).map((i) => i.line).join('; ') +
                          (items.length > 2
                              ? ' +${items.length - 2} more'
                              : ''),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  if (s.reason != null && !s.planned) ...[
                    Gaps.v4,
                    Text(
                      far
                          ? 'Far: about ${s.km?.round()} km from the CSWS office'
                          : s.reason!,
                      style: t.labelMedium?.copyWith(
                        color: far ? AppColors.danger : cs.error,
                      ),
                    ),
                  ],
                  if (s.lastChance || s.callDonor || s.inRun) ...[
                    Gaps.v4,
                    Wrap(
                      spacing: Space.xs,
                      children: [
                        if (s.lastChance)
                          Text(
                            '⚑ Last chance',
                            style: t.labelMedium?.copyWith(
                              color: lastChanceInk,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (s.callDonor)
                          Text(
                            'Call the donor',
                            style: t.labelMedium?.copyWith(color: cs.error),
                          ),
                        if (s.inRun)
                          Text(
                            'In a DRRMO request',
                            style: t.labelMedium?.copyWith(
                              color: AppColors.success,
                            ),
                          ),
                      ],
                    ),
                  ],
                  Gaps.v8,
                  Row(
                    children: [
                      Expanded(
                        child: DayChips(
                          s.days,
                          highlight: s.plannedDate?.weekday,
                          dense: true,
                        ),
                      ),
                      FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                        ),
                        onPressed: () => openNavigation(
                          context,
                          lat: s.point.latitude,
                          lng: s.point.longitude,
                          address: s.address,
                        ),
                        icon: const Icon(Icons.navigation_outlined, size: 18),
                        label: const Text('Navigate'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A Door to Door donation with no usable pin: staff call and fix it.
class FollowUpRow extends StatelessWidget {
  final PlanDonation d;
  final VoidCallback? onOpen;
  const FollowUpRow({super.key, required this.d, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            d.landmark.isEmpty ? 'No landmark' : d.landmark,
            style: t.titleSmall,
          ),
          if (d.address.isNotEmpty)
            Text(
              d.address,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          if (d.barangay != null)
            Text(
              'Brgy. ${d.barangay}',
              style: t.labelMedium?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          Text(
            d.items.map((i) => i.line).join('; '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: t.bodyMedium,
          ),
          Gaps.v4,
          Row(
            children: [
              Icon(Icons.person_outline, size: 18, color: cs.onSurfaceVariant),
              Gaps.h4,
              Expanded(
                child: Text(
                  d.donor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (d.contact.isNotEmpty) ContactButtons(phone: d.contact),
            ],
          ),
          Gaps.v4,
          Row(
            children: [
              Expanded(child: DayChips(d.days, dense: true)),
              if (d.address.isNotEmpty)
                IconButton(
                  tooltip: 'Navigate by address',
                  onPressed: () => openNavigation(context, address: d.address),
                  icon: const Icon(Icons.navigation_outlined),
                ),
              if (onOpen != null)
                TextButton(onPressed: onOpen, child: const Text('Open')),
            ],
          ),
        ],
      ),
    );
  }
}
