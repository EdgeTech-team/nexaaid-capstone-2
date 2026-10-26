import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../design/design.dart';
import 'pickup_actions.dart' show ContactButtons, openNavigation;
import 'pickup_days.dart';

// ---------------------------------------------------------------------------
// Door to Door pickup plan (Oct 12 notes, pickup logic v2, revised: no
// scoring).
//
// GET /donations/pickup-plan returns the waiting donations grouped into
// stops (same landmark AND a shared day), each planned on a date by plain
// urgency rules (fewest days left, closest deadline, oldest first) and put
// in a one-way route from the CSWS office. There is no size estimate and no
// priority score: the picker judges the load from the items exactly as the
// donor entered them. This file has:
//   * the data classes for that response,
//   * the map pin (number = route order, corner badge = donations,
//     yellow ring = last chance, truck = in a DRRMO request),
//   * the stop details sheet the picker sees before navigating.
// The screen itself is pickup_map.dart.
//
// Terms: donation = one QR code with one or more items; stop = one place
// the picker visits; run = one trip on one date.
// ---------------------------------------------------------------------------

DateTime? _date(Object? raw) {
  final s = '${raw ?? ''}';
  if (s.isEmpty || s == 'null') return null;
  final d = DateTime.tryParse(s);
  return d == null ? null : DateTime(d.year, d.month, d.day);
}

List<String> _strings(Object? raw) => [
  for (final e in (raw as List? ?? const [])) '$e',
];

int? _int(Object? raw) => raw is num ? raw.toInt() : int.tryParse('$raw');

double _double(Object? raw) =>
    raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;

const _months = [
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

/// "Tue, Oct 13"
String planDateLabel(DateTime d) =>
    '${pickupDayShort[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';

bool sameDay(DateTime? a, DateTime? b) =>
    a != null &&
    b != null &&
    a.year == b.year &&
    a.month == b.month &&
    a.day == b.day;

/// Specific dates win; weekdays only for entries made before the calendar.
bool _availableOn(Set<int> days, Set<DateTime> dates, DateTime? d) {
  if (d == null) return false;
  if (dates.isNotEmpty) return dates.any((x) => sameDay(x, d));
  return days.contains(d.weekday);
}

/// Grey for pickups outside the distance limit.
const farGrey = Color(0xFF6B7280);

/// Dark yellow text for "last chance".
const lastChanceInk = Color(0xFF8A6100);

// ----- data -----------------------------------------------------------------

/// One item line exactly as the donor entered it.
class PlanItem {
  final String name;
  final String unit;
  final String packaging;
  final int quantity;
  final bool heavy; // sacks and gallon containers: load first

  PlanItem.fromJson(Map j)
    : name = '${j['item_name'] ?? 'Item'}',
      unit = '${j['unit'] ?? ''}',
      packaging = '${j['packaging'] ?? ''}',
      quantity = _int(j['quantity']) ?? 0,
      heavy = j['heavy'] == true;

  /// "Rice, Sack (50 kg) × 2"
  String get line =>
      '$name${packaging.isEmpty ? '' : ', $packaging'} × $quantity';
}

/// One donation (one QR code) at a stop.
class PlanDonation {
  final Map<String, dynamic> raw;
  final String ref;
  final List<PlanItem> items;
  final Set<int> days;
  final Set<DateTime> dates; // specific dates (calendar); empty = weekdays
  final List<String> flags;

  PlanDonation.fromJson(Map<String, dynamic> j)
    : raw = j,
      ref = '${j['batch_reference']}',
      items = [
        for (final e in (j['items'] as List? ?? const []))
          PlanItem.fromJson(e as Map),
      ],
      days = pickupDaysOf(j['pickup_days']),
      dates = pickupDatesOf(j['pickup_dates']),
      flags = _strings(j['flags']);

  /// The donor is home on [d]: one of their dates, or (older entries) one
  /// of their weekdays.
  bool availableOn(DateTime? d) => _availableOn(days, dates, d);

  String get donor => '${raw['donor'] ?? 'Donor'}';
  String get contact => '${raw['donor_contact'] ?? ''}'.trim();
  String get address => '${raw['pickup_address'] ?? ''}'.trim();
  String get landmark => '${raw['pickup_landmark'] ?? ''}'.trim();

  /// Read from the address text by the server; null when not found.
  String? get barangay => raw['barangay'] as String?;
  String get notes => '${raw['pickup_notes'] ?? ''}'.trim();
  String get reportLabel => '${raw['report_label'] ?? ''}';
  int? get daysLeft => _int(raw['days_left']);
  Map? get pickupRequest => raw['pickup_request'] as Map?;
  bool get tooFar => raw['too_far'] == true;
  double? get km => (raw['distance_km'] as num?)?.toDouble();
}

/// One place the picker visits.
class PlanStop {
  final String id;
  final LatLng point;
  final String landmark;
  final String address;
  final String? barangay; // read from the address text; null: not found
  final Set<int> days; // the days every donor here allows
  final Set<DateTime> dates; // the dates every donor here allows (calendar)
  final List<PlanDonation> donations;
  final bool heavy;
  final int? daysLeft;
  final bool tooFar;
  final double? km;
  final List<String> flags;
  final String status; // planned | no_feasible_day | far
  final String? reason;
  final DateTime? plannedDate;
  final int? order;
  final int? optionsLeft;
  final bool lastChance;
  final DateTime? nextDate;

  PlanStop.fromJson(Map<String, dynamic> j)
    : id = '${j['stop_id']}',
      point = LatLng(_double(j['lat']), _double(j['lng'])),
      landmark = '${j['landmark'] ?? ''}'.trim(),
      address = '${j['address'] ?? ''}'.trim(),
      barangay = j['barangay'] as String?,
      days = pickupDaysOf(j['days']),
      dates = pickupDatesOf(j['dates']),
      donations = [
        for (final e in (j['donations'] as List? ?? const []))
          PlanDonation.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
      heavy = j['heavy'] == true,
      daysLeft = _int(j['days_left']),
      tooFar = j['too_far'] == true,
      km = (j['distance_km'] as num?)?.toDouble(),
      flags = _strings(j['flags']),
      status = '${j['status'] ?? 'no_feasible_day'}',
      reason = j['reason'] as String?,
      plannedDate = _date(j['planned_date']),
      order = _int(j['route_order']),
      optionsLeft = _int(j['options_left']),
      lastChance = j['last_chance'] == true,
      nextDate = _date(j['next_date']);

  /// A donor here is home on [d] (see [PlanDonation.availableOn]).
  bool availableOn(DateTime? d) => _availableOn(days, dates, d);

  bool get planned => status == 'planned';
  bool get far => status == 'far';
  bool get inRun => donations.any((d) => d.pickupRequest != null);
  bool get callDonor => flags.contains('call_donor');
  bool get missedBefore => flags.contains('missed_before');
  List<String> get refs => [for (final d in donations) d.ref];
  List<PlanItem> get items => [for (final d in donations) ...d.items];

  /// Short landmark name for the pin and its title.
  String get area {
    var a = landmark.split(',').first.trim();
    if (a.isEmpty) a = address.split(',').first.trim();
    if (a.isEmpty) a = 'No landmark';
    return a.length > 32 ? '${a.substring(0, 31)}…' : a;
  }

  /// "3 donations · 7 items"
  String get countLine {
    final n = donations.length;
    final i = items.length;
    return '$n donation${n == 1 ? '' : 's'} · $i item${i == 1 ? '' : 's'}';
  }
}

/// One trip on one date.
class PlanRun {
  final DateTime date;
  final List<String> stopIds;
  final int donations;
  final double km;
  final int minutes;
  final String finishLabel;
  final int heavyStops;

  PlanRun.fromJson(Map j)
    : date = _date(j['date'])!,
      stopIds = _strings(j['stop_ids']),
      donations = _int(j['donations']) ?? 0,
      km = _double(j['km']),
      minutes = _int(j['minutes']) ?? 0,
      finishLabel = '${j['finish_label'] ?? ''}',
      heavyStops = _int(j['heavy_stops']) ?? 0;
}

class PickupPlan {
  final DateTime today;
  final List<DateTime> dates; // every CSWS pickup day in the window
  final List<PlanRun> runs;
  final List<PlanStop> stops;
  final List<PlanDonation> followUp; // Door to Door with no usable pin
  final LatLng? office;
  final double maxKm;
  final bool includesReturnTrip;
  final int windowDays;

  PickupPlan._({
    required this.today,
    required this.dates,
    required this.runs,
    required this.stops,
    required this.followUp,
    required this.office,
    required this.maxKm,
    required this.includesReturnTrip,
    required this.windowDays,
  });

  factory PickupPlan.fromJson(Map<String, dynamic> j, Set<int> pickupDays) {
    final today = _date(j['today']) ?? DateTime.now();
    final window = j['window'] as Map? ?? const {};
    final days = _int(window['days']) ?? 14;
    final office = j['office'] as Map?;
    final hours = j['hours'] as Map? ?? const {};
    return PickupPlan._(
      today: today,
      dates: [
        for (var i = 0; i < days; i++)
          if (pickupDays.contains(today.add(Duration(days: i)).weekday))
            DateTime(today.year, today.month, today.day + i),
      ],
      runs: [
        for (final r in (j['runs'] as List? ?? const []))
          PlanRun.fromJson(r as Map),
      ],
      stops: [
        for (final s in (j['stops'] as List? ?? const []))
          PlanStop.fromJson(Map<String, dynamic>.from(s as Map)),
      ],
      followUp: [
        for (final d in (j['follow_up'] as List? ?? const []))
          PlanDonation.fromJson(Map<String, dynamic>.from(d as Map)),
      ],
      office: office == null || office['lat'] == null
          ? null
          : LatLng(_double(office['lat']), _double(office['lng'])),
      maxKm: _double(j['max_km']),
      includesReturnTrip: hours['includes_return_trip'] == true,
      windowDays: days,
    );
  }

  PlanRun? runOn(DateTime? d) =>
      runs.where((r) => sameDay(r.date, d)).firstOrNull;

  /// Stops planned on [d], in route order.
  List<PlanStop> stopsOn(DateTime d) {
    final run = runOn(d);
    if (run == null) return const [];
    final byId = {for (final s in stops) s.id: s};
    return [
      for (final id in run.stopIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  List<PlanStop> get unplanned => [
    for (final s in stops)
      if (s.status == 'no_feasible_day') s,
  ];

  List<PlanStop> get far => [
    for (final s in stops)
      if (s.far) s,
  ];
}

/// Separate day chips ("Mon" "Wed" "Fri"), so a gap is never read as a
/// range. [highlight] is the planned day.
class DayChips extends StatelessWidget {
  final Set<int> days;
  final int? highlight;
  final bool dense;

  /// Specific dates (calendar): shown instead of [days] when not empty, with
  /// [highlightDate] (the planned date) filled.
  final Set<DateTime> dates;
  final DateTime? highlightDate;

  const DayChips(
    this.days, {
    super.key,
    this.highlight,
    this.dense = false,
    this.dates = const {},
    this.highlightDate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (dates.isNotEmpty) {
      return PickupDateChips(
        sortedDates(dates),
        dense: dense,
        highlight: highlightDate == null
            ? null
            : DateTime(
                highlightDate!.year,
                highlightDate!.month,
                highlightDate!.day,
              ),
      );
    }
    final sorted = days.toList()..sort();
    if (sorted.isEmpty) {
      return Text(
        'No shared day',
        style: t.labelMedium?.copyWith(color: cs.error),
      );
    }
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final d in sorted)
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: dense ? 6 : 9,
              vertical: dense ? 1 : 3,
            ),
            decoration: BoxDecoration(
              color: d == highlight ? cs.primary : cs.primaryContainer,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(
              pickupDayShort[d - 1],
              style: (dense ? t.labelSmall : t.labelMedium)?.copyWith(
                color: d == highlight ? cs.onPrimary : cs.onPrimaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
      ],
    );
  }
}

// ----- the map pin -----------------------------------------------------------

/// One stop on the map.
///   number inside   route order on the chosen day (a dot in "All")
///   colour          brand teal; grey = far (outside the distance limit)
///   corner badge    how many donations (×3)
///   yellow ring     last chance: the donors' only remaining day
///   truck           already in a DRRMO pickup request
class PlanPin extends StatelessWidget {
  final PlanStop stop;
  final int? number;
  final bool selected;
  final VoidCallback onTap;
  const PlanPin({
    super.key,
    required this.stop,
    required this.number,
    required this.selected,
    required this.onTap,
  });

  static const double _size = 50;

  /// Marker box for this pin (flutter_map needs a fixed size).
  static const Size box = Size(_size + 22, _size + 8);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = stop.far ? farGrey : cs.primary;
    const inner = _size * 0.46;
    final label = [
      number == null ? 'Stop' : 'Stop $number',
      stop.area,
      '${stop.donations.length} donation${stop.donations.length == 1 ? '' : 's'}',
      if (stop.lastChance) 'last chance',
      if (stop.far) 'far from the CSWS office',
      if (stop.inRun) 'in a DRRMO request',
    ].join(', ');
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          duration: Motion.fast,
          scale: selected ? 1.18 : 1,
          alignment: Alignment.bottomCenter,
          child: SizedBox(
            width: box.width,
            height: box.height,
            child: Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: 6,
                  child: Icon(
                    Icons.location_on,
                    size: _size,
                    color: color,
                    shadows: const [
                      Shadow(blurRadius: 4, color: Colors.black38),
                    ],
                  ),
                ),
                Positioned(
                  top: 6 + _size * 0.15,
                  child: Container(
                    width: inner,
                    height: inner,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected ? AppColors.vest : Colors.white,
                      shape: BoxShape.circle,
                      border: stop.lastChance
                          ? Border.all(color: AppColors.vest, width: 3)
                          : null,
                    ),
                    child: number == null
                        ? Icon(
                            stop.far ? Icons.priority_high : Icons.circle,
                            size: stop.far ? 14 : 8,
                            color: selected ? AppColors.vestInk : color,
                          )
                        : Text(
                            '$number',
                            style: TextStyle(
                              color: selected ? AppColors.vestInk : color,
                              fontWeight: FontWeight.w900,
                              fontSize: number! > 99 ? 9 : inner * 0.5,
                            ),
                          ),
                  ),
                ),
                if (stop.donations.length > 1)
                  Positioned(
                    right: 0,
                    top: 0,
                    child: _Tag('×${stop.donations.length}', border: color),
                  ),
                if (stop.inRun)
                  const Positioned(
                    left: 0,
                    bottom: _size * 0.30,
                    child: CircleAvatar(
                      radius: 9,
                      backgroundColor: Colors.white,
                      child: Icon(
                        Icons.fire_truck,
                        size: 12,
                        color: AppColors.success,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color border;
  const _Tag(this.text, {required this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 18),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: border, width: 1.5),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.ink,
          fontSize: 10,
          fontWeight: FontWeight.w900,
          height: 1.2,
        ),
      ),
    );
  }
}

// ----- the stop details sheet ------------------------------------------------

/// What the picker sees before navigating. Opened from a pin or a list row.
class StopDetailsSheet extends StatefulWidget {
  final PlanStop stop;
  final int? number;

  /// Opens the donation's QR entry to receive the goods: the picker's
  /// count is saved as the actual quantity, apart from what was declared.
  final Future<void> Function(PlanDonation d)? onPickedUp;
  final Future<void> Function()? onNotHome;
  final Future<void> Function(PlanDonation d)? onDecline;

  const StopDetailsSheet({
    super.key,
    required this.stop,
    required this.number,
    this.onPickedUp,
    this.onNotHome,
    this.onDecline,
  });

  @override
  State<StopDetailsSheet> createState() => _StopDetailsSheetState();
}

class _StopDetailsSheetState extends State<StopDetailsSheet> {
  bool _allItems = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final s = widget.stop;
    final items = [
      for (final d in s.donations)
        for (final i in d.items) (d, i),
    ];
    final visible = _allItems ? items : items.take(3).toList();
    final many = s.donations.length > 1;

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.62,
      minChildSize: 0.35,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
        children: [
          Text(
            '${widget.number != null ? '${widget.number}. ' : ''}'
            '${s.landmark.isEmpty ? 'No landmark' : s.area}',
            style: t.titleLarge,
          ),
          if (s.address.isNotEmpty) ...[
            Gaps.v4,
            Text(
              s.address,
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          Gaps.v8,
          Text(s.countLine, style: t.titleSmall),

          // Plan: date, last chance, or why it is not planned
          if (s.planned && s.plannedDate != null)
            _Note(
              icon: Icons.local_shipping_outlined,
              color: cs.primary,
              text:
                  'Suggested day: ${planDateLabel(s.plannedDate!)}'
                  '${s.optionsLeft != null && s.optionsLeft! > 1 ? ' · ${s.optionsLeft! - 1} more allowed day${s.optionsLeft! == 2 ? '' : 's'} in the next two weeks' : ''}',
            ),
          if (s.lastChance)
            const _Note(
              icon: Icons.flag,
              color: lastChanceInk,
              text:
                  'Last chance: this is the only day left in the next two '
                  'weeks that every donor here allows.',
            ),
          if (!s.planned && s.reason != null)
            _Note(icon: Icons.event_busy, color: cs.error, text: s.reason!),
          if (s.missedBefore)
            _Note(
              icon: Icons.door_front_door_outlined,
              color: cs.onSurfaceVariant,
              text: 'Nobody was home on an earlier visit.',
            ),
          if (s.callDonor)
            _Note(
              icon: Icons.phone_in_talk_outlined,
              color: cs.error,
              text:
                  'Close to the handover deadline'
                  '${s.daysLeft != null ? ' (${s.daysLeft} day${s.daysLeft == 1 ? '' : 's'} left)' : ''}: '
                  'call the donor.',
            ),

          // Items as the donor wrote them
          Gaps.v16,
          Row(
            children: [
              Text('Items', style: t.titleSmall),
              if (s.heavy) ...[
                Gaps.h8,
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: cs.errorContainer,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.fitness_center,
                        size: 14,
                        color: cs.onErrorContainer,
                      ),
                      Gaps.h4,
                      Text(
                        'Heavy: load first',
                        style: t.labelSmall?.copyWith(
                          color: cs.onErrorContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          Gaps.v4,
          for (final (d, i) in visible)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    i.heavy ? Icons.fitness_center : Icons.inventory_2_outlined,
                    size: 18,
                    color: i.heavy ? cs.error : cs.onSurfaceVariant,
                  ),
                  Gaps.h8,
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: i.line),
                          if (many)
                            TextSpan(
                              text: '  ·  ${d.ref}',
                              style: TextStyle(color: cs.onSurfaceVariant),
                            ),
                        ],
                      ),
                      style: t.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          if (items.length > 3)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _allItems = !_allItems),
                child: Text(
                  _allItems ? 'Show less' : '+${items.length - 3} more',
                ),
              ),
            ),

          // Donors (one QR each)
          Gaps.v16,
          Text(many ? 'Donations (one QR each)' : 'Donor', style: t.titleSmall),
          for (final d in s.donations)
            _DonationRow(
              d: d,
              showPickedUp: many && widget.onPickedUp != null,
              onPickedUp: widget.onPickedUp == null
                  ? null
                  : () => widget.onPickedUp!(d),
              onDecline: d.tooFar && widget.onDecline != null
                  ? () => widget.onDecline!(d)
                  : null,
            ),

          // Actions
          Gaps.v16,
          FilledButton.icon(
            onPressed: () => openNavigation(
              context,
              lat: s.point.latitude,
              lng: s.point.longitude,
              address: s.address,
            ),
            icon: const Icon(Icons.navigation_outlined),
            label: const Text('Navigate'),
          ),
          Gaps.v8,
          Row(
            children: [
              if (!many && widget.onPickedUp != null) ...[
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: () => widget.onPickedUp!(s.donations.first),
                    icon: const Icon(Icons.qr_code_scanner),
                    label: const Text('Mark picked up'),
                  ),
                ),
                Gaps.h8,
              ],
              if (widget.onNotHome != null && !s.far)
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.onNotHome,
                    icon: const Icon(Icons.door_front_door_outlined),
                    label: const Text('Not home'),
                  ),
                ),
            ],
          ),
          Gaps.v8,
          Text(
            'All items of a donation share one QR code. Scanning it opens '
            'the same list; the count you enter there is saved apart from '
            'what the donor declared.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Note extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  const _Note({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: Space.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          Gaps.h8,
          Expanded(
            child: Text(text, style: t.bodyMedium?.copyWith(color: color)),
          ),
        ],
      ),
    );
  }
}

class _DonationRow extends StatelessWidget {
  final PlanDonation d;
  final bool showPickedUp;
  final VoidCallback? onPickedUp;
  final VoidCallback? onDecline;
  const _DonationRow({
    required this.d,
    required this.showPickedUp,
    this.onPickedUp,
    this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final run = d.pickupRequest;
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.person_outline, size: 18, color: cs.onSurfaceVariant),
              Gaps.h4,
              Expanded(
                child: Text(
                  d.donor,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (d.contact.isNotEmpty) ContactButtons(phone: d.contact),
            ],
          ),
          Text(
            '${d.ref} · ${d.reportLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          if (d.notes.isNotEmpty)
            Text(
              'Note: ${d.notes}',
              style: t.bodySmall?.copyWith(fontStyle: FontStyle.italic),
            ),
          if (run != null)
            Text(
              'In DRRMO request #${run['request_id']} (${run['status']})',
              style: t.labelMedium?.copyWith(color: AppColors.success),
            ),
          if (showPickedUp || onDecline != null)
            Wrap(
              spacing: Space.xs,
              children: [
                if (showPickedUp)
                  TextButton.icon(
                    onPressed: onPickedUp,
                    icon: const Icon(Icons.qr_code_scanner, size: 18),
                    label: const Text('Mark picked up'),
                  ),
                if (onDecline != null)
                  TextButton.icon(
                    onPressed: onDecline,
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.danger,
                    ),
                    icon: const Icon(Icons.block, size: 18),
                    label: const Text('Decline: too far'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
