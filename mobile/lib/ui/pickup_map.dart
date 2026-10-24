import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import 'batch_sheet.dart' show openDonationByQr;
import 'home_nav.dart';
import 'location_picker.dart' show PickupRules;
import 'pickup_actions.dart'
    show openNavigation, openRouteNavigation, routeLegStops;
import 'pickup_days.dart';
import 'pickup_list.dart';
import 'pickup_plan.dart';
import 'pickup_route.dart'
    show centerOf, kmBetween, mandaueCenter, niceKm, pathKm;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Door to Door pickups: the CSWS Main Office "Pickups" tab (UC-D2 alt 7c,
// UC-CM1 for Door to Door; Oct 12 notes, pickup logic v2).
//
// Two views of the same data (GET /donations/pickup-plan), switched with the
// Map / List buttons:
//
// Map  "Who is home that day, and in which order do we go?"
//   * Opens on TODAY automatically, with nothing to tap: only the stops with
//     a donor home today (the next pickup day on weekends, with a note).
//     The Filter button (top right) picks another day or All days, with
//     how many stops each has; "Back to today" returns.
//   * Without tapping anything: a summary of the day (donations, last
//     chances, expiring soon, missed visits, heavy loads), and each stop's
//     items and warnings in the sheet. Pins carry only the route number,
//     so nearby pins don't cover each other. Choosing a day shows ONLY those stops (the same rule as
//     the list's "Home on" filter), numbered by urgency: fewest dates left,
//     then closest deadline, then oldest donation; distance from the
//     previous stop only breaks an exact tie (_homeOn).
//   * A short sheet under the map: the stops in that order, each with
//     Navigate. Tapping a pin or a row opens the stop details (items as the
//     donor wrote them, days, Navigate / Mark picked up / Not home).
//
// List "Who is waiting, where, and when are they home?" (pickup_list.dart)
//   * Group by barangay, by day of availability or by the planner's
//     suggested runs; "Home on" filter; search; stops needing attention,
//     donations without a map pin, and the requests sent to DRRMO.
//
// Everything is a suggestion; CSWS staff confirm each run.
// ---------------------------------------------------------------------------

const _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _appId = 'nexaaid.mandauecity.app';

/// Show the "Ask DRRMO for help" button. The manuscript has DRRMO help only
/// after goods are prepared for release (Scope 5.2 / 5.3); the Oct 11 notes
/// added it for pickups. Set to false if the team decides DRRMO does not
/// help with pickups. Requests already sent stay listed either way.
const kDrrmoPickupSupport = true;

/// How much of a phone screen the stop sheet covers when the map opens.
const _sheetStart = 0.30;

/// All of Cebu province, until GET /donations/pickup-rules says otherwise.
final _cebu = LatLngBounds(
  const LatLng(9.40, 123.25),
  const LatLng(11.30, 124.10),
);

class PickupMapScreen extends StatefulWidget {
  /// True when pushed as its own page (from the CSWS Pickups tab).
  final bool standalone;
  const PickupMapScreen({super.key, this.standalone = false});

  @override
  State<PickupMapScreen> createState() => _PickupMapScreenState();
}

class _PickupMapScreenState extends State<PickupMapScreen> {
  final _map = MapController();
  bool _mapReady = false;

  bool _loading = true;
  String? _error;
  int _errorStatus = 0;
  PickupPlan? _plan;
  List<Map<String, dynamic>> _runs = [];
  PickupRules _rules = const PickupRules();
  LatLngBounds _areaBounds = _cebu;

  int? _day; // weekday shown on the map (1 = Mon); null = all days
  bool _dayPicked = false; // the user chose a day (keep it on reload)
  String? _selected; // stop id of the tapped pin
  bool _listMode = false; // Map / List switch

  bool get _canRequest => kDrrmoPickupSupport && api.role == Roles.cswsMain;
  bool get _canReceive => api.role == Roles.cswsMain || api.role == Roles.admin;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final results = await Future.wait([
      api.get('/donations/pickup-plan'),
      api.get('/donations/pickup-rules'),
      if (api.role == Roles.cswsMain) api.get('/logistics/requests'),
    ]);
    if (!mounted) return;
    final res = results[0];
    if (!res.ok || res.json is! Map) {
      setState(() {
        _loading = false;
        _error = res.errorText;
        _errorStatus = res.status;
      });
      return;
    }
    var rules = _rules;
    var bounds = _areaBounds;
    final rr = results[1];
    if (rr.ok && rr.json is Map) {
      final j = Map<String, dynamic>.from(rr.json as Map);
      rules = PickupRules.fromJson(j);
      final bb = ((j['area'] as Map?)?['bbox'] as List?)?.cast<num>();
      if (bb != null && bb.length == 4) {
        bounds = LatLngBounds(
          LatLng(bb[1].toDouble(), bb[0].toDouble()),
          LatLng(bb[3].toDouble(), bb[2].toDouble()),
        );
      }
    }
    final plan = PickupPlan.fromJson(
      Map<String, dynamic>.from(res.json as Map),
      rules.days,
    );
    var runs = <Map<String, dynamic>>[];
    if (results.length > 2 && results[2].ok && results[2].json is List) {
      runs = [
        for (final e in results[2].json as List)
          Map<String, dynamic>.from(e as Map),
      ];
    }
    setState(() {
      _loading = false;
      _plan = plan;
      _rules = rules;
      _areaBounds = bounds;
      _runs = runs;
      // Opens on TODAY automatically (who is home today). On a day without
      // pickups (e.g. Saturday) it shows the next pickup day and says so.
      // Later loads keep the day the user chose.
      if (!_dayPicked) _day = _defaultDay(plan, rules);
      if (!plan.stops.any((s) => s.id == _selected)) _selected = null;
    });
    _fitSoon();
  }

  /// Today's weekday, or the next CSWS pickup day when today has none.
  int? _defaultDay(PickupPlan plan, PickupRules rules) {
    final today = plan.today.weekday;
    if (rules.days.contains(today)) return today;
    return plan.dates.firstOrNull?.weekday;
  }

  /// Today is not a CSWS pickup day (e.g. a weekend).
  bool get _noPickupsToday =>
      _plan != null && !_rules.days.contains(_plan!.today.weekday);

  // ----- what is shown --------------------------------------------------------

  /// Stops with a donor home on [weekday] (far pickups left out), in
  /// urgency order (Oct 12 notes), the same three rules as the planner:
  ///   1. fewest pickup dates left in the next two weeks (a donor home only
  ///      on Thursdays, with one Thursday left, goes first),
  ///   2. closest handover deadline (days left before the donation expires),
  ///   3. oldest donation first.
  /// Only when two stops are exactly as urgent does distance decide: the
  /// one nearest to the previous stop (or the CSWS office) goes first.
  List<PlanStop> _homeOn(PickupPlan p, int weekday) {
    final left = [
      for (final s in p.stops)
        if (!s.far && s.days.contains(weekday)) s,
    ];
    final from = _dateOf(weekday, p);
    final key = {for (final s in left) s.id: _urgency(p, s, from)};
    final out = <PlanStop>[];
    var here = p.office;
    while (left.isNotEmpty) {
      final at = here;
      left.sort((a, b) {
        final c = _compareUrgency(key[a.id]!, key[b.id]!);
        if (c != 0 || at == null) return c;
        return kmBetween(at, a.point).compareTo(kmBetween(at, b.point));
      });
      final next = left.removeAt(0);
      out.add(next);
      here = next.point;
    }
    return out;
  }

  /// (dates left, days to deadline, oldest donation) for one stop.
  (int, int, DateTime) _urgency(PickupPlan p, PlanStop s, DateTime? from) {
    // A visit where nobody was home: only dates after it count.
    DateTime? missed;
    for (final d in s.donations) {
      final m = DateTime.tryParse('${d.raw['not_home_date'] ?? ''}');
      if (m != null && (missed == null || m.isAfter(missed))) missed = m;
    }
    final dates = p.dates.where(
      (d) =>
          s.days.contains(d.weekday) &&
          (from == null || !d.isBefore(from)) &&
          (missed == null || d.isAfter(missed)),
    );
    var oldest = DateTime(9999);
    for (final d in s.donations) {
      final c = DateTime.tryParse('${d.raw['created_at'] ?? ''}');
      if (c != null && c.isBefore(oldest)) oldest = c;
    }
    return (dates.length, s.daysLeft ?? 1 << 20, oldest);
  }

  int _compareUrgency((int, int, DateTime) a, (int, int, DateTime) b) {
    if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
    if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
    return a.$3.compareTo(b.$3);
  }

  /// Stops on the map and in the sheet.
  List<PlanStop> get _shown {
    final p = _plan;
    if (p == null) return const [];
    if (_day != null) return _homeOn(p, _day!);
    return p.stops;
  }

  /// Route number when a day is chosen; none in "All".
  Map<String, int> get _numbers {
    if (_day == null) return const {};
    final shown = _shown;
    return {for (var i = 0; i < shown.length; i++) shown[i].id: i + 1};
  }

  /// The next date (today counts) with this weekday.
  DateTime? _dateOf(int weekday, [PickupPlan? plan]) =>
      (plan ?? _plan)?.dates.where((d) => d.weekday == weekday).firstOrNull;

  Future<void> _openFilter() async {
    final p = _plan;
    if (p == null) return;
    final v = await showDayFilter(
      context,
      current: _day,
      todayWeekday: p.today.weekday,
      pickupDays: _rules.days.toList(),
      countOn: (wd) => _homeOn(p, wd).length,
      allCount: p.stops.length,
    );
    if (v != null) _pickDay(v == kAllDays ? null : v);
  }

  void _pickDay(int? weekday) {
    setState(() {
      _day = weekday;
      _dayPicked = true;
      _selected = null;
    });
    _fitSoon();
  }

  // ----- camera ---------------------------------------------------------------

  void _fitSoon() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit());

  void _fit() {
    if (!_mapReady || !mounted || _listMode) return;
    final p = _plan;
    final shown = _shown;
    // Far pins only when nothing else is shown, so the city stays readable.
    final near = [
      for (final s in shown)
        if (!s.far) s.point,
    ];
    final pts = [
      if (near.isNotEmpty) ...near else for (final s in shown) s.point,
      if (p?.office != null && _day != null) p!.office!,
    ];
    if (pts.isEmpty) {
      _map.move(p?.office ?? mandaueCenter, 13);
      return;
    }
    if (pts.length == 1) {
      _map.move(pts.first, 16);
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= Breakpoints.expanded;
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: EdgeInsets.fromLTRB(
          48,
          wide ? 90 : 100,
          64,
          wide ? 48 : size.height * _sheetStart + 24,
        ),
        maxZoom: 17,
      ),
    );
  }

  void _setListMode(bool list) {
    if (list == _listMode) return;
    setState(() {
      _listMode = list;
      _selected = null;
      // The map is rebuilt when it comes back; onMapReady fits it again.
      if (list) _mapReady = false;
    });
  }

  void _focus(PlanStop s) {
    setState(() => _selected = s.id);
    if (_mapReady && !_listMode) {
      final zoom = _map.camera.zoom < 15 ? 15.0 : _map.camera.zoom;
      _map.move(s.point, zoom);
    }
  }

  // ----- stop details and its actions ------------------------------------------

  Future<void> _openStop(PlanStop s) async {
    _focus(s);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => StopDetailsSheet(
        stop: s,
        number: _listMode ? null : _numbers[s.id],
        onPickedUp: _canReceive
            ? (d) async {
                Navigator.pop(sheet);
                _goScan();
              }
            : null,
        onNotHome: _canReceive
            ? () async {
                Navigator.pop(sheet);
                await _notHome(s);
              }
            : null,
        onDecline: _canReceive
            ? (d) async {
                Navigator.pop(sheet);
                await _decline(d);
              }
            : null,
      ),
    );
  }

  /// "Mark picked up": go to the Receive tab with the QR scanner open. The
  /// picker scans the donor's QR and enters the actual quantity there, like
  /// any other receipt (saved apart from what the donor declared).
  void _goScan() {
    HomeNav.go(context, const HomeTarget('Receive', view: 'scan'));
  }

  /// Opens a donation's QR entry directly (donations without a map pin).
  Future<void> _receive(String ref) async {
    await openDonationByQr(context, ref);
    if (mounted) await _load();
  }

  /// Nobody home: the stop moves to the donors' next allowed day.
  Future<void> _notHome(PlanStop s) async {
    final next = s.nextDate == null ? null : planDateLabel(s.nextDate!);
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nobody home?'),
        content: Text(
          'The pickup at ${s.area} moves to the '
          '${s.donations.length == 1 ? 'donor\'s' : 'donors\''} next pickup '
          'day${next == null ? '' : ' (about $next)'}. Registered donors are '
          'told in the app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Not home'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final r = await act(
      context,
      () => api.post(
        '/donations/pickup-plan/not-home',
        body: {'batch_references': s.refs},
      ),
      success: 'Moved to the next pickup day',
    );
    if (r.ok && mounted) await _load();
  }

  /// A pickup farther than PICKUP_MAX_KM: cancel it with a reason the donor
  /// reads, and ask them to drop it off instead.
  Future<void> _decline(PlanDonation d) async {
    final km = d.km?.round();
    final v = await formDialog(
      context,
      title: 'Decline this pickup?',
      message:
          '${d.landmark.isEmpty ? d.address : d.landmark} is about $km km '
          'from the CSWS office, outside the pickup area. The donor is told '
          'and can still bring the goods to the office.',
      fields: [
        DialogField(
          'reason',
          'Message to the donor',
          multiline: true,
          initial:
              'Sorry, your address is too far for a Door to Door pickup '
              '(about $km km from the CSWS office). Please drop off your '
              'donation at the CSWS office instead.',
        ),
      ],
      confirm: 'Decline pickup',
    );
    if (v == null || !mounted) return;
    final r = await act(
      context,
      () => api.post(
        '/donations/entries/${Uri.encodeComponent(d.ref)}/cancel',
        body: {'reason': v['reason']},
      ),
      success: 'Pickup declined. The donor was told.',
    );
    if (r.ok && mounted) await _load();
  }

  // ----- DRRMO logistics support -----------------------------------------------

  Future<void> _requestSupport(DateTime day, List<PlanStop> stops) async {
    final free = [
      for (final s in stops)
        for (final d in s.donations)
          if (d.pickupRequest == null) d.ref,
    ];
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Every stop on this day is already in a request.'),
        ),
      );
      return;
    }
    final sent = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) =>
          _RunRequestSheet(day: day, stops: stops, refs: free, rules: _rules),
    );
    if (sent == true && mounted) await _load();
  }

  Future<void> _cancelRun(Map<String, dynamic> run) async {
    final v = await formDialog(
      context,
      title: 'Cancel pickup request #${run['request_id']}?',
      message: 'DRRMO is told that you no longer need this support.',
      fields: const [
        DialogField(
          'reason',
          'Reason',
          hint: 'e.g. Donors will drop the goods off instead',
          multiline: true,
        ),
      ],
      confirm: 'Cancel request',
    );
    if (v == null || !mounted) return;
    final r = await act(
      context,
      () => api.post(
        '/logistics/requests/${run['request_id']}/cancel',
        body: {'reason': v['reason']},
      ),
      success: 'Pickup request cancelled. DRRMO was told.',
    );
    if (r.ok && mounted) await _load();
  }

  /// "Show on map" on a DRRMO request: its weekday on the map.
  void _showRun(Map<String, dynamic> run) {
    final d = DateTime.tryParse('${run['pickup_date'] ?? ''}');
    _setListMode(false);
    _pickDay(d?.weekday);
  }

  // ----- build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (!widget.standalone) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Pickups')),
      body: body,
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _plan == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _plan == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: ErrorView.forStatus(_errorStatus, _error!, onRetry: _load),
        ),
      );
    }
    if (_listMode) {
      return Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Breakpoints.expanded),
          child: PickupListView(
            plan: _plan!,
            rules: _rules,
            initialHomeOn: _day,
            header: _listHeader(context),
            footer: _requestsSection(),
            onRefresh: _load,
            onOpenStop: _openStop,
            onOpenFollowUp: _canReceive ? (d) => _receive(d.ref) : null,
          ),
        ),
      );
    }
    final shown = _shown;
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;
    final map = _mapView(context, shown);
    if (wide) {
      return Row(
        children: [
          SizedBox(
            width: 400,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: _sheet(context, shown, null),
            ),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: map),
        ],
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: map),
        DraggableScrollableSheet(
          initialChildSize: _sheetStart,
          minChildSize: 0.12,
          maxChildSize: 0.9,
          snap: true,
          snapSizes: const [0.12, _sheetStart, 0.9],
          builder: (context, scroll) => Material(
            elevation: 12,
            color: Theme.of(context).colorScheme.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(Radii.xl),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: _sheet(context, shown, scroll, handle: true),
          ),
        ),
      ],
    );
  }

  // The map, with the day card floating on top.
  Widget _mapView(BuildContext context, List<PlanStop> shown) {
    final cs = Theme.of(context).colorScheme;
    final p = _plan!;
    final numbers = _numbers;
    final line = [
      if (_day != null && p.office != null) p.office!,
      if (_day != null)
        for (final s in shown) s.point,
    ];
    // The selected pin is drawn last so it sits on top.
    final ordered = [
      ...shown.where((s) => s.id != _selected),
      ...shown.where((s) => s.id == _selected),
    ];

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: centerOf([for (final s in shown) s.point]),
            initialZoom: 13,
            minZoom: 8,
            cameraConstraint: CameraConstraint.containCenter(
              bounds: _areaBounds,
            ),
            onMapReady: () {
              _mapReady = true;
              _fit();
            },
            onTap: (_, _) => setState(() => _selected = null),
          ),
          children: [
            TileLayer(
              urlTemplate: _osmTileUrl,
              userAgentPackageName: _appId,
              maxZoom: 19,
            ),
            if (line.length > 1)
              PolylineLayer(
                polylines: [
                  Polyline(
                    points: line,
                    strokeWidth: 5,
                    color: cs.primary.withValues(alpha: 0.85),
                    borderStrokeWidth: 2,
                    borderColor: Colors.white.withValues(alpha: 0.9),
                    pattern: StrokePattern.dashed(segments: const [14, 8]),
                  ),
                ],
              ),
            MarkerLayer(
              markers: [
                if (p.office != null)
                  Marker(
                    point: p.office!,
                    width: 44,
                    height: 44,
                    child: Tooltip(
                      message: 'CSWS office (start)',
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppColors.vest,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 3),
                          boxShadow: const [
                            BoxShadow(blurRadius: 6, color: Colors.black26),
                          ],
                        ),
                        child: const Icon(
                          Icons.warehouse_outlined,
                          color: AppColors.vestInk,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                for (final s in ordered)
                  Marker(
                    point: s.point,
                    width: PlanPin.box.width,
                    height: PlanPin.box.height,
                    alignment: Alignment.topCenter,
                    child: PlanPin(
                      stop: s,
                      number: numbers[s.id],
                      selected: s.id == _selected,
                      onTap: () => _openStop(s),
                    ),
                  ),
              ],
            ),
            RichAttributionWidget(
              attributions: [
                TextSourceAttribution(
                  'OpenStreetMap contributors',
                  onTap: () => launchUrl(
                    Uri.parse('https://www.openstreetmap.org/copyright'),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ],
            ),
          ],
        ),
        Positioned(
          left: Space.sm,
          right: Space.sm,
          top: Space.sm,
          child: _TopBar(
            selected: _day,
            todayWeekday: p.today.weekday,
            onFilter: _openFilter,
            onFit: _fit,
            onList: () => _setListMode(true),
          ),
        ),
      ],
    );
  }

  // Title and the Map / List switch at the top of the list view.
  Widget _listHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final p = _plan!;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Pickups', style: t.titleLarge),
              Text(
                '${p.stops.length} stop${p.stops.length == 1 ? '' : 's'} '
                'waiting',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
        _ViewSwitch(list: true, onChanged: _setListMode),
        IconButton(
          tooltip: 'Refresh',
          onPressed: _loading ? null : _load,
          icon: _loading
              ? const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
        ),
      ],
    );
  }

  /// Requests already sent to DRRMO (bottom of the list view).
  Widget? _requestsSection() {
    if (_runs.isEmpty) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('Requests to DRRMO'),
        for (final r in _runs)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.xs),
            child: _RunCard(
              run: r,
              onShow: () => _showRun(r),
              onCancel: () => _cancelRun(r),
            ),
          ),
      ],
    );
  }

  // The short sheet under the map: the chosen day's stops in order.
  Widget _sheet(
    BuildContext context,
    List<PlanStop> shown,
    ScrollController? scroll, {
    bool handle = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final p = _plan!;
    final numbers = _numbers;
    final day = _day;
    final date = day == null ? null : _dateOf(day);
    final km = day == null
        ? 0.0
        : pathKm([
            if (p.office != null) p.office!,
            for (final s in shown) s.point,
          ]);

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.xl),
        children: [
          if (handle)
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.symmetric(vertical: Space.sm),
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
              ),
            )
          else
            Gaps.v16,
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      day == null
                          ? 'All days'
                          : '${sameDay(date, p.today) ? 'Today · ' : ''}'
                                '${pickupDayNames[day - 1]}'
                                '${date == null ? '' : ' · ${planDateLabel(date).split(', ').last}'}',
                      style: t.titleLarge,
                    ),
                    Text(
                      day == null
                          ? '${shown.length} stop${shown.length == 1 ? '' : 's'} · pick a day to see the route'
                          : shown.isEmpty
                          ? 'No donor is home this day'
                          : '${shown.length} stop${shown.length == 1 ? '' : 's'} · '
                                '${niceKm(km)} one way from CSWS',
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (_canRequest && date != null && shown.isNotEmpty)
                IconButton.filledTonal(
                  tooltip: 'Ask DRRMO for a truck or volunteers',
                  onPressed: () => _requestSupport(date, shown),
                  icon: const Icon(Icons.local_shipping_outlined),
                ),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _loading ? null : _load,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_noPickupsToday && day != null && !_dayPicked && date != null)
            _Banner(
              icon: Icons.event_busy,
              text:
                  'No pickups on ${pickupDayNames[p.today.weekday - 1]}s. '
                  'Showing the next pickup day, ${planDateLabel(date)}.',
            ),
          if (day != p.today.weekday && !_noPickupsToday)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _pickDay(p.today.weekday),
                icon: const Icon(Icons.today, size: 18),
                label: const Text('Back to today'),
              ),
            ),
          if (day != null && shown.isNotEmpty) _DaySummary(stops: shown),
          // Turn-by-turn through the whole run in this order (Oct 2026,
          // route planning): one way from CSWS, in legs of 10 stops.
          if (day != null && shown.isNotEmpty)
            Wrap(
              spacing: Space.xs,
              children: [
                for (var leg = 0; leg * routeLegStops < shown.length; leg++)
                  FilledButton.tonalIcon(
                    onPressed: () => openRouteNavigation(
                      context,
                      origin: p.office == null
                          ? null
                          : (p.office!.latitude, p.office!.longitude),
                      stops: [
                        for (final s in shown)
                          (s.point.latitude, s.point.longitude),
                      ],
                      leg: leg,
                    ),
                    icon: const Icon(Icons.navigation_outlined),
                    label: Text(
                      shown.length <= routeLegStops
                          ? 'Navigate this route'
                          : 'Navigate stops ${leg * routeLegStops + 1}-'
                                '${((leg + 1) * routeLegStops).clamp(0, shown.length)}',
                    ),
                  ),
              ],
            ),
          Gaps.v8,
          if (p.stops.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: Space.lg),
              child: EmptyView(
                compact: true,
                icon: Icons.door_front_door_outlined,
                title: 'No Door to Door pickups waiting',
              ),
            ),
          for (final s in shown)
            _MiniStopRow(
              stop: s,
              number: numbers[s.id],
              selected: s.id == _selected,
              onTap: () => _openStop(s),
            ),
          if (p.unplanned.isNotEmpty || p.followUp.isNotEmpty) ...[
            Gaps.v8,
            TextButton.icon(
              onPressed: () => _setListMode(true),
              icon: const Icon(Icons.error_outline, size: 18),
              label: Text(
                '${p.unplanned.length + p.followUp.length} need attention · '
                'open the list',
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// A one-line notice in the sheet.
class _Banner extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Banner({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(top: Space.xs),
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xs,
      ),
      decoration: BoxDecoration(
        color: cs.secondaryContainer.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: cs.onSecondaryContainer),
          Gaps.h8,
          Expanded(
            child: Text(
              text,
              style: t.bodyMedium?.copyWith(color: cs.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// What needs attention on the chosen day, at a glance (no tapping):
/// donations, last chances, near deadlines, missed visits, heavy loads.
class _DaySummary extends StatelessWidget {
  final List<PlanStop> stops;
  const _DaySummary({required this.stops});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    int count(bool Function(PlanStop) f) => stops.where(f).length;
    final donations = stops.fold<int>(0, (n, s) => n + s.donations.length);
    final chips = <(IconData, String, Color)>[
      (
        Icons.volunteer_activism_outlined,
        '$donations donation${donations == 1 ? '' : 's'}',
        cs.primary,
      ),
      if (count((s) => s.lastChance) > 0)
        (
          Icons.flag,
          '${count((s) => s.lastChance)} last chance',
          lastChanceInk,
        ),
      if (count((s) => s.callDonor) > 0)
        (
          Icons.phone_in_talk_outlined,
          '${count((s) => s.callDonor)} expiring soon',
          cs.error,
        ),
      if (count((s) => s.missedBefore) > 0)
        (
          Icons.door_front_door_outlined,
          '${count((s) => s.missedBefore)} missed before',
          cs.onSurfaceVariant,
        ),
      if (count((s) => s.heavy) > 0)
        (Icons.fitness_center, '${count((s) => s.heavy)} heavy', cs.error),
      if (count((s) => s.inRun) > 0)
        (
          Icons.fire_truck,
          '${count((s) => s.inRun)} with DRRMO',
          AppColors.success,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final (icon, text, c) in chips)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: c.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14, color: c),
                  const SizedBox(width: 4),
                  Text(
                    text,
                    style: t.labelMedium?.copyWith(
                      color: c,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Map / List switch.
class _ViewSwitch extends StatelessWidget {
  final bool list;
  final ValueChanged<bool> onChanged;
  const _ViewSwitch({required this.list, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<bool>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(
          value: false,
          icon: Icon(Icons.map_outlined, size: 18),
          label: Text('Map'),
        ),
        ButtonSegment(
          value: true,
          icon: Icon(Icons.format_list_bulleted, size: 18),
          label: Text('List'),
        ),
      ],
      selected: {list},
      onSelectionChanged: (v) => onChanged(v.first),
    );
  }
}

/// The bar on top of the map: Map / List, the day filter, fit all pins.
/// The map already shows TODAY; the filter is only for another day.
class _TopBar extends StatelessWidget {
  final int? selected;
  final int todayWeekday;
  final VoidCallback onFilter;
  final VoidCallback onFit;
  final VoidCallback onList;

  const _TopBar({
    required this.selected,
    required this.todayWeekday,
    required this.onFilter,
    required this.onFit,
    required this.onList,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.xs),
        child: Row(
          children: [
            _ViewSwitch(
              list: false,
              onChanged: (v) {
                if (v) onList();
              },
            ),
            const Spacer(),
            DayFilterButton(
              weekday: selected,
              todayWeekday: todayWeekday,
              onPressed: onFilter,
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: 'Fit all pins',
              onPressed: onFit,
              icon: const Icon(Icons.zoom_out_map),
            ),
          ],
        ),
      ),
    );
  }
}

/// One stop in the sheet under the map: number, place, Navigate.
class _MiniStopRow extends StatelessWidget {
  final PlanStop stop;
  final int? number;
  final bool selected;
  final VoidCallback onTap;

  const _MiniStopRow({
    required this.stop,
    required this.number,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final s = stop;
    final color = s.far ? farGrey : cs.primary;
    final where = [
      if (s.barangay != null) 'Brgy. ${s.barangay}',
      s.countLine,
    ].join(' · ');
    final items = s.items;
    final what = items.isEmpty
        ? ''
        : items.take(2).map((i) => i.line).join('; ') +
              (items.length > 2 ? '; +${items.length - 2} more' : '');
    final tags = <(IconData, String, Color)>[
      if (s.lastChance) (Icons.flag, 'Last chance', lastChanceInk),
      if (s.callDonor)
        (
          Icons.phone_in_talk_outlined,
          s.daysLeft == null
              ? 'Call donor'
              : 'Expires in ${s.daysLeft} day${s.daysLeft == 1 ? '' : 's'}',
          cs.error,
        ),
      if (s.missedBefore)
        (Icons.door_front_door_outlined, 'Missed before', cs.onSurfaceVariant),
      if (s.heavy) (Icons.fitness_center, 'Heavy', cs.error),
      if (s.inRun) (Icons.fire_truck, 'DRRMO', AppColors.success),
    ];
    return Material(
      color: selected
          ? cs.primaryContainer.withValues(alpha: 0.4)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(Radii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: Space.xs,
            horizontal: 4,
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
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
                        s.far ? Icons.priority_high : Icons.location_on,
                        size: 16,
                        color: Colors.white,
                      ),
              ),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.area,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall,
                    ),
                    Text(
                      where,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                    if (what.isNotEmpty)
                      Text(
                        what,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: t.bodySmall,
                      ),
                    if (tags.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Wrap(
                        spacing: 8,
                        runSpacing: 2,
                        children: [
                          for (final (icon, text, c) in tags)
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(icon, size: 13, color: c),
                                const SizedBox(width: 2),
                                Text(
                                  text,
                                  style: t.labelSmall?.copyWith(
                                    color: c,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Navigate',
                onPressed: () => openNavigation(
                  context,
                  lat: s.point.latitude,
                  lng: s.point.longitude,
                  address: s.address,
                ),
                icon: const Icon(Icons.navigation_outlined),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A pickup request already sent to DRRMO.
class _RunCard extends StatelessWidget {
  final Map<String, dynamic> run;
  final VoidCallback onShow;
  final VoidCallback onCancel;
  const _RunCard({
    required this.run,
    required this.onShow,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final status = '${run['status']}';
    final open = status == 'Pending' || status == 'Accepted';
    final stops = (run['stops'] as List? ?? const []).length;
    return AppCard(
      onTap: onShow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '#${run['request_id']} · ${run['report_label'] ?? 'Pickup run'}',
                  style: t.titleSmall,
                ),
              ),
              StatusChip(status),
            ],
          ),
          Gaps.v4,
          if (run['needs'] != null)
            Text(
              '${run['needs']}',
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          Text(
            'Requested ${niceDate(run['created_at'])} · $stops '
            'stop${stops == 1 ? '' : 's'}',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
          Row(
            children: [
              TextButton.icon(
                onPressed: onShow,
                icon: const Icon(Icons.map_outlined),
                label: const Text('Show on map'),
              ),
              const Spacer(),
              if (open)
                TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(foregroundColor: cs.error),
                  child: const Text('Cancel'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Ask DRRMO for support for one day's run
// ---------------------------------------------------------------------------

class _RunRequestSheet extends StatefulWidget {
  final DateTime day;
  final List<PlanStop> stops; // in route order
  final List<String> refs; // QR references not already in a request
  final PickupRules rules;
  const _RunRequestSheet({
    required this.day,
    required this.stops,
    required this.refs,
    required this.rules,
  });

  @override
  State<_RunRequestSheet> createState() => _RunRequestSheetState();
}

class _RunRequestSheetState extends State<_RunRequestSheet> {
  int _trucks = 1;
  int _volunteers = 2;
  int _pushcarts = 0;
  final _notes = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _send() async {
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.post(
        '/logistics/pickup-requests',
        body: {
          'pickup_date': _ymd(widget.day),
          'batch_references': widget.refs,
          'trucks': _trucks,
          'volunteers': _volunteers,
          'pushcarts': _pushcarts,
          if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
        },
      ),
      success: 'Pickup request sent to DRRMO',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok) Navigator.pop(context, true);
  }

  Widget _count(
    String label,
    IconData icon,
    int value,
    int max,
    ValueChanged<int> onChanged,
  ) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, prefixIcon: Icon(icon)),
      items: [
        for (var i = 0; i <= max; i++)
          DropdownMenuItem(value: i, child: Text(i == 0 ? 'None' : '$i')),
      ],
      onChanged: (v) => setState(() => onChanged(v ?? 0)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final nothing = _trucks == 0 && _volunteers == 0 && _pushcarts == 0;
    final stops = widget.stops;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Request DRRMO logistics support', style: t.titleLarge),
              Gaps.v4,
              Text(
                'For the Door to Door run on ${planDateLabel(widget.day)}. '
                'DRRMO sees the stops, the landmarks and what to load, not '
                'the donors\' numbers.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v12,
              PickupHoursNote(widget.rules),
              Gaps.v12,
              Container(
                padding: const EdgeInsets.all(Space.sm),
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${stops.length} stop${stops.length == 1 ? '' : 's'}, '
                      'in this order:',
                      style: t.titleSmall,
                    ),
                    Gaps.v4,
                    for (var i = 0; i < stops.length && i < 8; i++)
                      Text(
                        '${i + 1}. ${stops[i].area} · ${stops[i].countLine}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (stops.length > 8) Text('and ${stops.length - 8} more'),
                  ],
                ),
              ),
              Gaps.v16,
              Text('What is needed', style: t.titleSmall),
              Gaps.v8,
              _count(
                'Trucks',
                Icons.local_shipping_outlined,
                _trucks,
                10,
                (v) => _trucks = v,
              ),
              Gaps.v12,
              _count(
                'Manpower (volunteers)',
                Icons.groups_outlined,
                _volunteers,
                20,
                (v) => _volunteers = v,
              ),
              Gaps.v12,
              _count(
                'Pushcarts',
                Icons.shopping_cart_outlined,
                _pushcarts,
                10,
                (v) => _pushcarts = v,
              ),
              Gaps.v12,
              TextField(
                controller: _notes,
                maxLength: 500,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Notes for DRRMO (optional)',
                  hintText: 'e.g. Narrow street at stop 3, small vehicle only',
                  prefixIcon: Icon(Icons.sticky_note_2_outlined),
                ),
              ),
              if (nothing)
                Text(
                  'Choose at least one: a truck, volunteers or a pushcart.',
                  style: t.bodySmall?.copyWith(color: cs.error),
                ),
              Gaps.v12,
              AppButton(
                'Send request for ${stops.length} '
                'stop${stops.length == 1 ? '' : 's'}',
                icon: Icons.send,
                expand: true,
                loading: _busy,
                onPressed: nothing || _busy ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
