import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import 'batch_sheet.dart' show openDonationByQr;
import 'location_picker.dart' show PickupRules;
import 'pickup_actions.dart' show ContactButtons, openNavigation;
import 'pickup_days.dart';
import 'pickup_plan.dart';
import 'pickup_route.dart' show centerOf, mandaueCenter, niceKm;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Door to Door pickups on a map: the CSWS Main Office "Pickups" tab
// (UC-D2 alt 7c, UC-CM1 for Door to Door; Oct 12 notes, pickup logic v2).
//
// The server plans (GET /donations/pickup-plan); this screen shows it:
//   * Above the map, one chip per pickup weekday (Mon to Fri) with how many
//     stops and how full the vehicle is on that weekday's next run.
//     Choosing a weekday shows ONLY the stops planned that day, numbered in
//     the one-way order from the CSWS office. "All" shows every waiting
//     stop, with its size letter.
//   * One pin per stop (donors at the same landmark who share a day).
//     Colour + letter = size, corner badge = donations, "?" = size
//     uncertain, yellow ring = last chance (see pickup_plan.dart).
//   * Tapping a pin or a row opens the stop details: the items as the donor
//     wrote them, the days as separate chips, how full the vehicle is after
//     the stop, and Navigate / Mark picked up / Not home.
//   * Below the list: stops that could not be planned (with the reason),
//     far pickups Main Office may decline, and Door to Door donations
//     without a map pin ("needs follow-up").
// The plan is a suggestion; CSWS staff confirm it.
// ---------------------------------------------------------------------------

const _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _appId = 'nexaaid.mandauecity.app';

/// Show the "Request DRRMO support" button. The manuscript has DRRMO help
/// only after goods are prepared for release (Scope 5.2 / 5.3); the Oct 11
/// notes added it for pickups. Set to false if the team decides DRRMO does
/// not help with pickups. Requests already sent stay listed either way.
const kDrrmoPickupSupport = true;

/// How much of a phone screen the list covers when the map opens.
const _sheetStart = 0.36;

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

  String? _vehicle; // null: the server's default vehicle
  DateTime? _date; // null: all waiting stops
  bool _datePicked = false; // the user chose a date (keep it on reload)
  String? _selected; // stop id of the tapped pin

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
      api.get(
        '/donations/pickup-plan',
        query: _vehicle == null ? null : {'vehicle': _vehicle!},
      ),
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
      _vehicle = plan.vehicle.key;
      // First load: open on the first day with a run (usually today or
      // tomorrow). Later loads keep the day the user chose.
      if (!_datePicked || !plan.dates.any((d) => sameDay(d, _date))) {
        _date = plan.runs.isEmpty ? null : plan.runs.first.date;
      }
      if (!plan.stops.any((s) => s.id == _selected)) _selected = null;
    });
    _fitSoon();
  }

  // ----- what is shown --------------------------------------------------------

  /// Stops on the map and in the list, in route order on a chosen day.
  List<PlanStop> get _shown {
    final p = _plan;
    if (p == null) return const [];
    if (_date != null) return p.stopsOn(_date!);
    return p.stops;
  }

  /// Route number on a chosen day; none in the all-days view.
  int? _numberOf(PlanStop s) => _date == null ? null : s.order;

  void _pickDate(DateTime? d) {
    setState(() {
      _date = d;
      _datePicked = true;
      _selected = null;
    });
    _fitSoon();
  }

  Future<void> _pickVehicle(String key) async {
    if (key == _vehicle) return;
    setState(() => _vehicle = key);
    await _load();
  }

  // ----- camera ---------------------------------------------------------------

  void _fitSoon() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit());

  void _fit() {
    if (!_mapReady || !mounted) return;
    final p = _plan;
    final shown = _shown;
    // Far pins only when nothing else is shown, so the city stays readable.
    final near = [
      for (final s in shown)
        if (s.status != 'far') s.point,
    ];
    final pts = [
      if (near.isNotEmpty) ...near else for (final s in shown) s.point,
      if (p?.office != null && _date != null) p!.office!,
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
          wide ? 200 : 210,
          64,
          wide ? 48 : size.height * _sheetStart + 24,
        ),
        maxZoom: 17,
      ),
    );
  }

  void _focus(PlanStop s) {
    setState(() => _selected = s.id);
    if (_mapReady) {
      final zoom = _map.camera.zoom < 15 ? 15.0 : _map.camera.zoom;
      _map.move(s.point, zoom);
    }
  }

  // ----- stop details and its actions ------------------------------------------

  Future<void> _openStop(PlanStop s) async {
    _focus(s);
    final p = _plan;
    if (p == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (sheet) => StopDetailsSheet(
        stop: s,
        number: _numberOf(s),
        vehicle: p.vehicle,
        onPickedUp: _canReceive
            ? (d) async {
                Navigator.pop(sheet);
                await _receive(d.ref);
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

  /// "Mark picked up": the donation's QR entry, where the picker enters the
  /// actual quantity (saved apart from what the donor declared).
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

  void _showRun(Map<String, dynamic> run) {
    final d = DateTime.tryParse('${run['pickup_date'] ?? ''}');
    final p = _plan;
    if (d == null || p == null || !p.dates.any((x) => sameDay(x, d))) {
      _pickDate(null);
      return;
    }
    _pickDate(DateTime(d.year, d.month, d.day));
  }

  // ----- build ------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final body = _body(context);
    if (!widget.standalone) return body;
    return Scaffold(
      appBar: AppBar(title: const Text('Pickup map')),
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
    final shown = _shown;
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;
    final map = _mapView(context, shown);
    if (wide) {
      return Row(
        children: [
          SizedBox(
            width: 440,
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              child: _panel(context, shown, null),
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
          minChildSize: 0.16,
          maxChildSize: 0.92,
          snap: true,
          snapSizes: const [0.16, _sheetStart, 0.92],
          builder: (context, scroll) => Material(
            elevation: 12,
            color: Theme.of(context).colorScheme.surface,
            shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(Radii.xl),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: _panel(context, shown, scroll, handle: true),
          ),
        ),
      ],
    );
  }

  // The map, with the date strip floating on top.
  Widget _mapView(BuildContext context, List<PlanStop> shown) {
    final cs = Theme.of(context).colorScheme;
    final p = _plan!;
    final line = [
      if (_date != null && p.office != null) p.office!,
      if (_date != null)
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
                          Icons.home_work,
                          color: AppColors.vestInk,
                          size: 22,
                        ),
                      ),
                    ),
                  ),
                for (final s in ordered)
                  Marker(
                    point: s.point,
                    width: PlanPin.boxFor(s).width,
                    height: PlanPin.boxFor(s).height,
                    alignment: Alignment.topCenter,
                    child: PlanPin(
                      stop: s,
                      number: _numberOf(s),
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
          child: _DateStrip(
            plan: p,
            selected: _date,
            rules: _rules,
            onPick: _pickDate,
            onFit: _fit,
          ),
        ),
      ],
    );
  }

  // Run summary, the stops in order, then what needs attention.
  Widget _panel(
    BuildContext context,
    List<PlanStop> shown,
    ScrollController? scroll, {
    bool handle = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final p = _plan!;
    final run = p.runOn(_date);
    final attention = [...p.unplanned, ...p.far];

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

          // Title and route summary
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _date == null
                          ? '${p.stops.length} stop${p.stops.length == 1 ? '' : 's'} waiting'
                          : '${shown.length} stop${shown.length == 1 ? '' : 's'} · '
                                '${planDateLabel(_date!)}',
                      style: t.titleLarge,
                    ),
                    if (run != null) ...[
                      Text(
                        'One way from the CSWS office · about '
                        '${niceKm(run.km)} (straight line, not road distance)',
                        style: t.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      Text(
                        '${p.vehicle.name} about ${run.fullness}% full · '
                        'done about ${run.finishLabel}'
                        '${p.includesReturnTrip ? ' (back at the office)' : ' (last stop)'}',
                        style: t.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ] else if (_date == null)
                      Text(
                        'Pick a day above to see its run in order.',
                        style: t.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
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
          Gaps.v12,

          // Vehicle for the run (capacity changes the plan)
          Text('Vehicle going out', style: t.titleSmall),
          Gaps.v4,
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final v in p.vehicles)
                ChoiceChip(
                  label: Text(v.name),
                  avatar: Icon(
                    v.key == 'car'
                        ? Icons.directions_car_outlined
                        : v.key == 'truck'
                        ? Icons.local_shipping_outlined
                        : Icons.airport_shuttle_outlined,
                    size: 18,
                  ),
                  selected: v.key == p.vehicle.key,
                  onSelected: _loading ? null : (_) => _pickVehicle(v.key),
                ),
            ],
          ),
          Gaps.v12,

          // Run briefing
          if (run != null) ...[
            _Briefing(run: run, vehicle: p.vehicle),
            Gaps.v12,
          ],

          if (_canRequest && run != null && shown.isNotEmpty) ...[
            OutlinedButton.icon(
              onPressed: () => _requestSupport(_date!, shown),
              icon: const Icon(Icons.fire_truck_outlined),
              label: const Text('Request DRRMO support for this run'),
            ),
            Gaps.v12,
          ],

          // The stops
          if (p.stops.isEmpty && p.followUp.isEmpty)
            AppCard(
              child: EmptyView(
                compact: true,
                icon: Icons.door_front_door_outlined,
                title: 'No Door to Door pickups waiting',
                message:
                    'When a donor chooses Door to Door, a pin appears at the '
                    'landmark they picked.',
              ),
            )
          else if (shown.isEmpty)
            AppCard(
              child: EmptyView(
                compact: true,
                icon: Icons.event_available_outlined,
                title: 'Nothing planned this day',
                message: 'Try another day, or tap All.',
              ),
            ),
          for (final s in shown)
            if (_date != null || s.planned)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: _StopRow(
                  stop: s,
                  number: _numberOf(s),
                  selected: s.id == _selected,
                  onTap: () => _openStop(s),
                ),
              ),

          // Needs attention: not plannable, special handling, far
          if (attention.isNotEmpty) ...[
            SectionHeader(
              'Needs attention',
              subtitle: 'Not in any run in the next ${p.windowDays} days',
            ),
            for (final s in attention)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: _StopRow(
                  stop: s,
                  number: null,
                  selected: s.id == _selected,
                  onTap: () => _openStop(s),
                ),
              ),
          ],

          // Door to Door without a usable pin
          if (p.followUp.isNotEmpty) ...[
            SectionHeader(
              'Needs follow-up',
              subtitle:
                  'No map pin: the donor typed a landmark without choosing '
                  'a suggestion. Call to confirm the place.',
            ),
            for (final d in p.followUp)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: _FollowUpRow(
                  d: d,
                  onOpen: _canReceive ? () => _receive(d.ref) : null,
                ),
              ),
          ],

          // Requests already sent to DRRMO
          if (_runs.isNotEmpty) ...[
            const SectionHeader('Pickup requests to DRRMO'),
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

          Gaps.v12,
          Text(
            'Sizes are estimates from the packaging and quantity the donor '
            'entered; the count at pickup is final. This is a suggested '
            'plan: CSWS confirms each run.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// "Pickup availability": All + one chip per pickup weekday (Mon to Fri).
class _DateStrip extends StatelessWidget {
  final PickupPlan plan;
  final DateTime? selected;
  final PickupRules rules;
  final ValueChanged<DateTime?> onPick;
  final VoidCallback onFit;

  const _DateStrip({
    required this.plan,
    required this.selected,
    required this.rules,
    required this.onPick,
    required this.onFit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final far = plan.far.length;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.sm,
          Space.xs,
          Space.xs,
          Space.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.event_available_outlined,
                  size: 18,
                  color: cs.primary,
                ),
                Gaps.h8,
                Expanded(
                  child: Text('Pickup availability', style: t.titleSmall),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Show all pins',
                  onPressed: onFit,
                  icon: const Icon(Icons.fit_screen_outlined),
                ),
              ],
            ),
            SizedBox(
              height: 66,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _DateChip(
                    middle: 'All',
                    bottom: '${plan.stops.length} waiting',
                    selected: selected == null,
                    onTap: () => onPick(null),
                  ),
                  // One chip per CSWS pickup weekday (Mon to Fri). A
                  // weekday opens its next run: the soonest date with that
                  // weekday in the plan (today counts).
                  for (final wd in (rules.days.toList()..sort()))
                    () {
                      final d = plan.dates
                          .where((x) => x.weekday == wd)
                          .firstOrNull;
                      final run = plan.runOn(d);
                      return _DateChip(
                        middle: pickupDayShort[wd - 1],
                        bottom: run == null
                            ? '–'
                            : '${run.stopIds.length} · ${run.fullness}%',
                        selected: sameDay(d, selected),
                        faded: run == null,
                        today: sameDay(d, plan.today),
                        onTap: d == null ? null : () => onPick(d),
                      );
                    }(),
                ],
              ),
            ),
            Gaps.v4,
            Text(
              'Pickup hours: ${pickupHoursLabel(rules)} · stops · '
              '${plan.vehicle.name.toLowerCase()} fullness',
              textAlign: TextAlign.center,
              style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (far > 0) ...[
              Gaps.v4,
              Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: AppColors.danger,
                  ),
                  Gaps.h4,
                  Expanded(
                    child: Text(
                      '$far pickup${far == 1 ? ' is' : 's are'} more than '
                      '${plan.maxKm.round()} km from the CSWS office',
                      style: t.labelMedium?.copyWith(color: AppColors.danger),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  final String? top;
  final String middle;
  final String bottom;
  final bool selected;
  final bool faded;
  final bool today;
  final VoidCallback? onTap;

  const _DateChip({
    this.top,
    required this.middle,
    required this.bottom,
    required this.selected,
    required this.onTap,
    this.faded = false,
    this.today = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final fg = selected
        ? cs.onPrimary
        : faded
        ? cs.onSurfaceVariant.withValues(alpha: 0.6)
        : cs.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Semantics(
        button: true,
        selected: selected,
        label:
            '${top == null ? '' : '$top '}$middle, $bottom'
            '${today ? ', today' : ''}',
        excludeSemantics: true,
        child: Material(
          color: selected ? cs.primary : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(Radii.md),
            side: BorderSide(
              color: selected
                  ? cs.primary
                  : today
                  ? cs.primary.withValues(alpha: 0.7)
                  : cs.outlineVariant,
              width: today && !selected ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 58,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (top != null)
                    Text(
                      top!,
                      style: t.labelSmall?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  Text(
                    middle,
                    style: t.titleMedium?.copyWith(
                      color: fg,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    bottom,
                    style: t.labelSmall?.copyWith(color: fg, fontSize: 10),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A short plain-words summary of the chosen day's run.
class _Briefing extends StatelessWidget {
  final PlanRun run;
  final PlanVehicle vehicle;
  const _Briefing({required this.run, required this.vehicle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final lines = [
      '${run.stopIds.length} stop${run.stopIds.length == 1 ? '' : 's'}, '
          '${run.donations} donation${run.donations == 1 ? '' : 's'}; the '
          '${vehicle.name.toLowerCase()} ends about ${run.fullness}% full.',
      if (run.heavyStops > 0)
        '${run.heavyStops} stop${run.heavyStops == 1 ? ' has' : 's have'} '
            'sacks or gallon containers: load those first.',
      if (run.uncertainStops > 0)
        '${run.uncertainStops} stop${run.uncertainStops == 1 ? '' : 's'} '
            'marked "?" (size uncertain): leave some room.',
    ];
    return Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final l in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Text(l, style: t.bodyMedium),
            ),
        ],
      ),
    );
  }
}

/// One stop in the list under the map, with Navigate on the row.
class _StopRow extends StatelessWidget {
  final PlanStop stop;
  final int? number;
  final bool selected;
  final VoidCallback onTap;

  const _StopRow({
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
    final far = s.status == 'far';
    final color = far ? const Color(0xFF6B7280) : sizeColor(s.sizeClass);
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
              child: Text(
                number != null ? '$number' : (far ? '!' : s.sizeClass),
                style: t.labelLarge?.copyWith(
                  color: far ? Colors.white : sizeInk(s.sizeClass),
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            Gaps.h12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          s.landmark.isEmpty ? 'No landmark' : s.landmark,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: t.titleSmall,
                        ),
                      ),
                      Gaps.h4,
                      SizeBadge(s.sizeClass, uncertain: s.uncertain),
                    ],
                  ),
                  if (s.address.isNotEmpty)
                    Text(
                      s.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  Gaps.v4,
                  Text(
                    [
                      s.sizeLine,
                      if (s.fullnessAfter != null)
                        'about ${s.fullnessAfter}% full after',
                      if (number == null && s.plannedDate != null)
                        planDateLabel(s.plannedDate!),
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
                              color: const Color(0xFF8A6100),
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
                        icon: const Icon(Icons.directions, size: 18),
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
class _FollowUpRow extends StatelessWidget {
  final PlanDonation d;
  final VoidCallback? onOpen;
  const _FollowUpRow({required this.d, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      padding: const EdgeInsets.all(Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  d.landmark.isEmpty ? 'No landmark' : d.landmark,
                  style: t.titleSmall,
                ),
              ),
              SizeBadge(
                d.sizeClass,
                uncertain: d.items.any((i) => i.confidence == 'uncertain'),
              ),
            ],
          ),
          if (d.address.isNotEmpty)
            Text(
              d.address,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
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
                  icon: const Icon(Icons.directions),
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
                label: const Text('Show that day'),
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
                        '${i + 1}. ${stops[i].area} · size ${stops[i].sizeClass}',
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
