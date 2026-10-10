import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import 'location_picker.dart' show PickupRules;
import 'pickup_actions.dart' show copyText, openNavigation;
import 'pickup_days.dart';
import 'pickup_route.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Pickup map (CSWS Disaster Unit; Oct 10 notes, "Very libog" section).
//
// Every Door to Door donation still waiting to be collected, as a numbered
// pin at the landmark the donor chose. Above the map: the days the donors
// are home (M / T / W / Th ...) and the landmarks, so the team can see who
// is near whom on a given day. The pins are numbered in a suggested
// one-way order (nearest next stop, pickup_route.dart). Tapping a pin shows
// its landmark and address inside the pin's bubble.
//
// The Disaster Unit can then ask DRRMO for logistics support for that run
// (trucks, volunteers, pushcarts), like CSWS Main Office does for
// deliveries. CSWS Main Office opens the same map from its Pickups tab
// (view only).
// ---------------------------------------------------------------------------

const _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _appId = 'nexaaid.mandauecity.app';

/// One Door to Door donation on the map.
class _Stop {
  final Map<String, dynamic> b;
  final LatLng? point;
  final Set<int> days;
  final String landmark; // full landmark text
  final String area; // short landmark name used by the filter chips

  _Stop(this.b, this.point, this.days, this.landmark, this.area);

  String get ref => '${b['batch_reference']}';
  String get address => '${b['pickup_address'] ?? ''}'.trim();
  Map? get run => b['pickup_request'] as Map?;

  factory _Stop.of(Map<String, dynamic> b) {
    final lat = (b['pickup_lat'] as num?)?.toDouble();
    final lng = (b['pickup_lng'] as num?)?.toDouble();
    var days = pickupDaysOf(b['pickup_days']);
    // Older entries: one preferred time, so one day.
    final at = DateTime.tryParse('${b['preferred_pickup_at'] ?? ''}');
    if (days.isEmpty && at != null) {
      days = {at.toUtc().add(const Duration(hours: 8)).weekday};
    }
    final landmark = '${b['pickup_landmark'] ?? ''}'.trim();
    var area = landmark.split(',').first.trim();
    if (area.isEmpty) area = 'No landmark';
    if (area.length > 28) area = '${area.substring(0, 27)}…';
    return _Stop(
      b,
      lat != null && lng != null ? LatLng(lat, lng) : null,
      days,
      landmark,
      area,
    );
  }
}

enum _Order { route, landmark }

/// How much of a phone screen the stops sheet covers when the map opens.
const _sheetStart = 0.36;

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
  List<_Stop> _all = [];
  List<Map<String, dynamic>> _runs = [];
  PickupRules _rules = const PickupRules();
  LatLng? _office;

  // Filters above the map.
  Set<int> _days = {};
  String? _area;
  _Order _order = _Order.route;
  Map<String, dynamic>? _focusRun; // "show this request on the map"
  String? _selected; // batch_reference of the tapped pin

  bool get _canRequest => api.role == Roles.cswsUnit;

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
      api.get('/donations/pickups'),
      PickupRules.load().then((r) => r),
      api.get('/donations/drop-off-info'),
      if (_canRequest) api.get('/logistics/requests'),
    ]);
    if (!mounted) return;
    final pickups = results[0] as ApiResult;
    if (!pickups.ok || pickups.json is! List) {
      setState(() {
        _loading = false;
        _error = pickups.errorText;
        _errorStatus = pickups.status;
      });
      return;
    }
    final info = results[2] as ApiResult;
    LatLng? office;
    if (info.ok && info.json is Map) {
      final lat = (info.json['lat'] as num?)?.toDouble();
      final lng = (info.json['lng'] as num?)?.toDouble();
      if (lat != null && lng != null) office = LatLng(lat, lng);
    }
    var runs = <Map<String, dynamic>>[];
    if (_canRequest) {
      final r = results[3] as ApiResult;
      if (r.ok && r.json is List) {
        runs = [
          for (final e in r.json as List) Map<String, dynamic>.from(e as Map),
        ];
      }
    }
    setState(() {
      _loading = false;
      _all = [
        for (final e in pickups.json as List)
          _Stop.of(Map<String, dynamic>.from(e as Map)),
      ];
      _rules = results[1] as PickupRules;
      _office = office;
      _runs = runs;
      _selected = null; // the camera refits, so close any open bubble
      if (_focusRun != null) {
        _focusRun = runs
            .where((r) => r['request_id'] == _focusRun!['request_id'])
            .firstOrNull;
      }
    });
    _fitSoon();
  }

  // ----- filtering and order ------------------------------------------------

  bool _matches(_Stop s) {
    if (_days.isNotEmpty && s.days.intersection(_days).isEmpty) return false;
    if (_area != null && s.area != _area) return false;
    return true;
  }

  /// Stops shown on the map, in the order they are numbered.
  List<_Stop> get _shown {
    if (_focusRun != null) {
      final refs = [
        for (final s in (_focusRun!['stops'] as List? ?? const []))
          '${(s as Map)['batch_reference']}',
      ];
      final byRef = {for (final s in _all) s.ref: s};
      return [
        for (final r in refs)
          if (byRef[r] != null) byRef[r]!,
      ];
    }
    final list = _all.where(_matches).toList();
    if (_order == _Order.landmark) {
      list.sort(
        (a, b) => a.landmark.toLowerCase().compareTo(b.landmark.toLowerCase()),
      );
      return list;
    }
    final pinned = list.where((s) => s.point != null).toList();
    final unpinned = list.where((s) => s.point == null).toList();
    final order = planOneWayRoute([
      for (final s in pinned) s.point!,
    ], start: _office);
    return [for (final i in order) pinned[i], ...unpinned];
  }

  Map<int, int> get _dayCounts {
    final base = _all.where((s) => _area == null || s.area == _area);
    return {
      for (var d = 1; d <= 7; d++)
        d: base.where((s) => s.days.contains(d)).length,
    };
  }

  List<MapEntry<String, int>> get _areas {
    final counts = <String, int>{};
    for (final s in _all) {
      if (_days.isNotEmpty && s.days.intersection(_days).isEmpty) continue;
      counts[s.area] = (counts[s.area] ?? 0) + 1;
    }
    final list = counts.entries.toList()
      ..sort((a, b) {
        final c = b.value.compareTo(a.value);
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return list;
  }

  void _setFilter(VoidCallback change) {
    setState(() {
      change();
      _selected = null;
    });
    _fitSoon();
  }

  // ----- camera --------------------------------------------------------------

  void _fitSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  void _fit() {
    if (!_mapReady || !mounted) return;
    final pts = [
      for (final s in _shown)
        if (s.point != null) s.point!,
      if (_office != null && _order == _Order.route) _office!,
    ];
    if (pts.isEmpty) {
      _map.move(mandaueCenter, 13);
      return;
    }
    if (pts.length == 1) {
      _map.move(pts.first, 16);
      return;
    }
    // Keep the pins clear of the filter card on top and, on phones, of the
    // stops sheet at the bottom.
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= Breakpoints.expanded;
    _map.fitCamera(
      CameraFit.bounds(
        bounds: LatLngBounds.fromPoints(pts),
        padding: EdgeInsets.fromLTRB(
          48,
          wide ? 220 : 250,
          64,
          wide ? 48 : size.height * _sheetStart + 24,
        ),
        maxZoom: 17,
      ),
    );
  }

  void _select(_Stop s) {
    setState(() => _selected = _selected == s.ref ? null : s.ref);
    if (s.point != null && _mapReady) {
      final zoom = _map.camera.zoom < 15 ? 15.0 : _map.camera.zoom;
      // Put the pin a little below the middle so its bubble fits under the
      // filter card (offset moves the pin down by that many pixels).
      final wide = MediaQuery.sizeOf(context).width >= Breakpoints.expanded;
      _map.move(s.point!, zoom, offset: Offset(0, wide ? 60 : 110));
    }
  }

  // ----- DRRMO logistics support -------------------------------------------

  Future<void> _requestSupport(List<_Stop> stops) async {
    final free = stops.where((s) => s.run == null).toList();
    if (free.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Every stop shown is already in a pickup request.'),
        ),
      );
      return;
    }
    final sent = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _RunRequestSheet(
        stops: free,
        skipped: stops.length - free.length,
        rules: _rules,
        preferredDays: _days,
      ),
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
    if (r.ok && mounted) {
      if (_focusRun?['request_id'] == run['request_id']) _focusRun = null;
      await _load();
    }
  }

  // ----- build ---------------------------------------------------------------

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
    if (_loading && _all.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
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
            width: 420,
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

  // The map, with the filter card floating on top.
  Widget _mapView(BuildContext context, List<_Stop> shown) {
    final cs = Theme.of(context).colorScheme;
    final pinned = [
      for (final s in shown)
        if (s.point != null) s,
    ];
    final number = {for (var i = 0; i < shown.length; i++) shown[i].ref: i + 1};
    final route = _order == _Order.route || _focusRun != null;
    final line = [
      if (route && _office != null && _focusRun == null) _office!,
      if (route) ...[for (final s in pinned) s.point!],
    ];
    final selected = pinned.where((s) => s.ref == _selected).firstOrNull;

    return Stack(
      children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: centerOf([for (final s in pinned) s.point!]),
            initialZoom: 13,
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
                if (_office != null)
                  Marker(
                    point: _office!,
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
                for (final s in pinned)
                  Marker(
                    point: s.point!,
                    width: 44,
                    height: 54,
                    alignment: Alignment.topCenter,
                    child: _Pin(
                      number: number[s.ref]!,
                      label: 'Stop ${number[s.ref]}: ${s.area}',
                      selected: s.ref == _selected,
                      inRun: s.run != null,
                      onTap: () => _select(s),
                    ),
                  ),
                if (selected != null)
                  Marker(
                    point: selected.point!,
                    width: 240,
                    height: 128,
                    alignment: const Alignment(0, -2), // just above the pin
                    child: _PinBubble(
                      stop: selected,
                      number: number[selected.ref]!,
                      onClose: () => setState(() => _selected = null),
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
          child: _FilterCard(
            days: _days,
            rules: _rules,
            dayCounts: _dayCounts,
            areas: _areas,
            area: _area,
            order: _order,
            focusRun: _focusRun,
            onDays: (d) => _setFilter(() => _days = d),
            onArea: (a) => _setFilter(() => _area = a),
            onOrder: (o) => _setFilter(() => _order = o),
            onClearRun: () => _setFilter(() => _focusRun = null),
            onFit: _fit,
          ),
        ),
      ],
    );
  }

  // Route summary, the stops in order, and the DRRMO requests.
  Widget _panel(
    BuildContext context,
    List<_Stop> shown,
    ScrollController? scroll, {
    bool handle = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final pinned = [
      for (final s in shown)
        if (s.point != null) s.point!,
    ];
    final path = [
      if (_office != null && _focusRun == null) _office!,
      ...pinned,
    ];
    final km = pathKm(path);
    final unpinned = shown.where((s) => s.point == null).length;
    final routeOrder = _order == _Order.route || _focusRun != null;

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
                      _focusRun != null
                          ? 'Request #${_focusRun!['request_id']}'
                          : shown.isEmpty
                          ? 'No pickups here'
                          : '${shown.length} pickup${shown.length == 1 ? '' : 's'}'
                                '${_days.isEmpty ? '' : ' on ${pickupDaysLabel(_days)}'}',
                      style: t.titleLarge,
                    ),
                    if (pinned.length > 1 && routeOrder)
                      Text(
                        'One way, nearest stop next · about ${niceKm(km)} '
                        'in a straight line',
                        style: t.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      )
                    else if (_order == _Order.landmark)
                      Text(
                        'Sorted by landmark, A to Z',
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
          if (_canRequest && shown.isNotEmpty && _focusRun == null) ...[
            AppButton(
              'Request DRRMO support for this run',
              icon: Icons.fire_truck_outlined,
              expand: true,
              onPressed: () => _requestSupport(shown),
            ),
            Gaps.v4,
            Text(
              'Trucks, volunteers or pushcarts for these stops, like Main '
              'Office asks for deliveries.',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v12,
          ],
          if (_all.isEmpty)
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
                icon: Icons.filter_alt_off_outlined,
                title: 'No pickups match',
                message: 'Try other days or All landmarks.',
              ),
            ),
          for (var i = 0; i < shown.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: _StopTile(
                stop: shown[i],
                number: i + 1,
                fromPrev: _legKm(shown, i),
                selected: shown[i].ref == _selected,
                onTap: () => _select(shown[i]),
              ),
            ),
          if (unpinned > 0)
            Padding(
              padding: const EdgeInsets.only(top: Space.xs),
              child: Text(
                '$unpinned without a pin: the donor typed the landmark '
                'without choosing a suggestion. Use the address.',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ),
          if (_canRequest && _runs.isNotEmpty) ...[
            const SectionHeader('Pickup requests to DRRMO'),
            for (final run in _runs)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.xs),
                child: _RunCard(
                  run: run,
                  focused: _focusRun?['request_id'] == run['request_id'],
                  onShow: () => _setFilter(
                    () => _focusRun =
                        _focusRun?['request_id'] == run['request_id']
                        ? null
                        : run,
                  ),
                  onCancel: () => _cancelRun(run),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// Straight-line distance from the previous pinned stop (or the office).
  double? _legKm(List<_Stop> shown, int i) {
    if (_order != _Order.route && _focusRun == null) return null;
    final p = shown[i].point;
    if (p == null) return null;
    for (var k = i - 1; k >= 0; k--) {
      final q = shown[k].point;
      if (q != null) return kmBetween(q, p);
    }
    return _office != null && _focusRun == null ? kmBetween(_office!, p) : null;
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

/// Days + landmarks + order, floating above the map.
class _FilterCard extends StatelessWidget {
  final Set<int> days;
  final PickupRules rules;
  final Map<int, int> dayCounts;
  final List<MapEntry<String, int>> areas;
  final String? area;
  final _Order order;
  final Map<String, dynamic>? focusRun;
  final ValueChanged<Set<int>> onDays;
  final ValueChanged<String?> onArea;
  final ValueChanged<_Order> onOrder;
  final VoidCallback onClearRun;
  final VoidCallback onFit;

  const _FilterCard({
    required this.days,
    required this.rules,
    required this.dayCounts,
    required this.areas,
    required this.area,
    required this.order,
    required this.focusRun,
    required this.onDays,
    required this.onArea,
    required this.onOrder,
    required this.onClearRun,
    required this.onFit,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    if (focusRun != null) {
      return Card(
        margin: EdgeInsets.zero,
        child: ListTile(
          leading: const Icon(Icons.fire_truck_outlined),
          title: Text('Showing request #${focusRun!['request_id']}'),
          subtitle: Text(
            '${focusRun!['report_label'] ?? ''} · ${focusRun!['status']}',
          ),
          trailing: TextButton(
            onPressed: onClearRun,
            child: const Text('Show all'),
          ),
        ),
      );
    }
    return Card(
      margin: EdgeInsets.zero,
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.sm,
          Space.sm,
          Space.sm,
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
                  child: Text(
                    days.isEmpty
                        ? 'Donors home on any day'
                        : 'Home on ${pickupDaysLabel(days)}',
                    style: t.titleSmall,
                  ),
                ),
                if (days.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => onDays({}),
                    child: const Text('Any day'),
                  ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Show all pins',
                  onPressed: onFit,
                  icon: const Icon(Icons.fit_screen_outlined),
                ),
              ],
            ),
            Gaps.v4,
            PickupDayToggles(
              dense: true,
              selected: days,
              counts: dayCounts,
              onChanged: onDays,
            ),
            Gaps.v4,
            Text(
              'Pickup hours: ${pickupHoursLabel(rules)}',
              textAlign: TextAlign.center,
              style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v8,
            SizedBox(
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                children: [
                  _OrderToggle(order: order, onChanged: onOrder),
                  Gaps.h8,
                  ChoiceChip(
                    avatar: const Icon(Icons.place_outlined, size: 16),
                    label: const Text('All landmarks'),
                    selected: area == null,
                    onSelected: (_) => onArea(null),
                  ),
                  for (final a in areas) ...[
                    Gaps.h4,
                    ChoiceChip(
                      label: Text('${a.key} (${a.value})'),
                      selected: area == a.key,
                      onSelected: (_) => onArea(area == a.key ? null : a.key),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OrderToggle extends StatelessWidget {
  final _Order order;
  final ValueChanged<_Order> onChanged;
  const _OrderToggle({required this.order, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_Order>(
      showSelectedIcon: false,
      style: const ButtonStyle(visualDensity: VisualDensity.compact),
      segments: const [
        ButtonSegment(
          value: _Order.route,
          icon: Icon(Icons.route, size: 16),
          label: Text('Nearest'),
          tooltip: 'Number the pins in a one-way order, nearest stop next',
        ),
        ButtonSegment(
          value: _Order.landmark,
          icon: Icon(Icons.sort_by_alpha, size: 16),
          label: Text('A–Z'),
          tooltip: 'Sort by landmark, A to Z',
        ),
      ],
      selected: {order},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// A numbered map pin.
class _Pin extends StatelessWidget {
  final int number;
  final String label;
  final bool selected;
  final bool inRun;
  final VoidCallback onTap;
  const _Pin({
    required this.number,
    required this.label,
    required this.selected,
    required this.inRun,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = inRun ? AppColors.success : cs.primary;
    return Semantics(
      button: true,
      selected: selected,
      label: inRun ? '$label, in a DRRMO request' : label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedScale(
          duration: Motion.fast,
          scale: selected ? 1.18 : 1,
          alignment: Alignment.bottomCenter,
          child: Stack(
            alignment: Alignment.topCenter,
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.location_on, size: 54, color: color),
              Positioned(
                top: 9,
                child: Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.vest : Colors.white,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$number',
                    style: TextStyle(
                      color: selected ? AppColors.vestInk : color,
                      fontWeight: FontWeight.w800,
                      fontSize: number > 99 ? 9 : 12,
                    ),
                  ),
                ),
              ),
              if (inRun)
                const Positioned(
                  right: 0,
                  top: 0,
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
    );
  }
}

/// The bubble above a tapped pin: landmark and the address text.
class _PinBubble extends StatelessWidget {
  final _Stop stop;
  final int number;
  final VoidCallback onClose;
  const _PinBubble({
    required this.stop,
    required this.number,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Material(
      elevation: 6,
      color: cs.surface,
      borderRadius: BorderRadius.circular(Radii.md),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.sm,
          Space.xs,
          Space.xs,
          Space.xs,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$number. ${stop.landmark.isEmpty ? 'No landmark' : stop.area}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleSmall?.copyWith(color: cs.primary),
                  ),
                ),
                InkWell(
                  onTap: onClose,
                  child: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            Gaps.v4,
            Text(
              stop.address.isEmpty ? 'No address' : stop.address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium,
            ),
            const Spacer(),
            Row(
              children: [
                Icon(
                  Icons.event_available,
                  size: 14,
                  color: cs.onSurfaceVariant,
                ),
                Gaps.h4,
                Expanded(
                  child: Text(
                    stop.days.isEmpty ? 'Any day' : pickupDaysLabel(stop.days),
                    style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
                InkWell(
                  onTap: () => openNavigation(
                    context,
                    lat: stop.point?.latitude,
                    lng: stop.point?.longitude,
                    address: stop.address,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.directions, size: 16, color: cs.primary),
                        Text(
                          ' Go',
                          style: t.labelLarge?.copyWith(color: cs.primary),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One stop in the list under the map.
class _StopTile extends StatelessWidget {
  final _Stop stop;
  final int number;
  final double? fromPrev;
  final bool selected;
  final VoidCallback onTap;
  const _StopTile({
    required this.stop,
    required this.number,
    required this.fromPrev,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final b = stop.b;
    final summary = (b['items_summary'] as List? ?? const [])
        .map((e) => '$e')
        .toList();
    final run = stop.run;
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: [
                CircleAvatar(
                  radius: 15,
                  backgroundColor: stop.point == null
                      ? cs.surfaceContainerHighest
                      : run != null
                      ? AppColors.success
                      : cs.primary,
                  child: Text(
                    stop.point == null ? '–' : '$number',
                    style: t.labelLarge?.copyWith(
                      color: stop.point == null
                          ? cs.onSurfaceVariant
                          : Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (fromPrev != null) ...[
                  Gaps.v4,
                  Text(
                    niceKm(fromPrev!),
                    style: t.labelSmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
            Gaps.h12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stop.landmark.isEmpty ? 'No landmark' : stop.landmark,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleSmall,
                  ),
                  if (stop.address.isNotEmpty)
                    Text(
                      stop.address,
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  Gaps.v8,
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (var d = 1; d <= 7; d++)
                        if (stop.days.contains(d))
                          _DayPill(pickupDayShort[d - 1]),
                      if (stop.days.isEmpty) const _DayPill('Any day'),
                    ],
                  ),
                  if (summary.isNotEmpty) ...[
                    Gaps.v8,
                    Text(
                      summary.take(3).join(' · ') +
                          (summary.length > 3
                              ? ' and ${summary.length - 3} more'
                              : ''),
                      style: t.bodyMedium,
                    ),
                  ],
                  if (run != null) ...[
                    Gaps.v8,
                    Row(
                      children: [
                        const Icon(
                          Icons.fire_truck,
                          size: 16,
                          color: AppColors.success,
                        ),
                        Gaps.h4,
                        Expanded(
                          child: Text(
                            'In DRRMO request #${run['request_id']} '
                            '(${run['status']})',
                            style: t.labelMedium?.copyWith(
                              color: AppColors.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  Gaps.v4,
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${b['batch_reference']} · ${b['report_label'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: t.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Copy address',
                        onPressed: stop.address.isEmpty
                            ? null
                            : () => copyText(context, stop.address, 'Address'),
                        icon: const Icon(Icons.copy, size: 18),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Directions',
                        onPressed: () => openNavigation(
                          context,
                          lat: stop.point?.latitude,
                          lng: stop.point?.longitude,
                          address: stop.address,
                        ),
                        icon: const Icon(Icons.directions, size: 18),
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

class _DayPill extends StatelessWidget {
  final String text;
  const _DayPill(this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: cs.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A pickup request already sent to DRRMO.
class _RunCard extends StatelessWidget {
  final Map<String, dynamic> run;
  final bool focused;
  final VoidCallback onShow;
  final VoidCallback onCancel;
  const _RunCard({
    required this.run,
    required this.focused,
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
                icon: Icon(focused ? Icons.layers_clear : Icons.map_outlined),
                label: Text(focused ? 'Show all pins' : 'Show on map'),
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
// Ask DRRMO for support for a pickup run
// ---------------------------------------------------------------------------

class _RunRequestSheet extends StatefulWidget {
  final List<_Stop> stops; // in route order, none already requested
  final int skipped; // shown stops already in another request
  final PickupRules rules;
  final Set<int> preferredDays;
  const _RunRequestSheet({
    required this.stops,
    required this.skipped,
    required this.rules,
    required this.preferredDays,
  });

  @override
  State<_RunRequestSheet> createState() => _RunRequestSheetState();
}

class _RunRequestSheetState extends State<_RunRequestSheet> {
  late final List<DateTime> _dates = _nextDates();
  DateTime? _date;
  int _trucks = 1;
  int _volunteers = 2;
  int _pushcarts = 0;
  final _notes = TextEditingController();
  bool _busy = false;

  static const _months = [
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

  @override
  void initState() {
    super.initState();
    // Default: the soonest date when the most stops are home.
    var best = 0;
    for (final d in _dates) {
      final n = _homeOn(d).length;
      if (n > best || (n == best && _date == null && n > 0)) {
        best = n;
        _date = d;
      }
    }
    final preferred = _dates
        .where((d) => widget.preferredDays.contains(d.weekday))
        .where((d) => _homeOn(d).length == best)
        .firstOrNull;
    if (preferred != null) _date = preferred;
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  /// CSWS pickup days from today (Philippine time), two weeks ahead.
  List<DateTime> _nextDates() {
    final now = PickupRules.phNow();
    final today = DateTime(now.year, now.month, now.day);
    return [
      for (var i = 0; i < 15; i++)
        if (widget.rules.days.contains(today.add(Duration(days: i)).weekday))
          today.add(Duration(days: i)),
    ];
  }

  List<_Stop> _homeOn(DateTime d) => widget.stops
      .where((s) => s.days.isEmpty || s.days.contains(d.weekday))
      .toList();

  String _label(DateTime d) =>
      '${pickupDayShort[d.weekday - 1]}, ${_months[d.month - 1]} ${d.day}';

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _send() async {
    final day = _date;
    if (day == null) return;
    final stops = _homeOn(day);
    setState(() => _busy = true);
    final r = await act(
      context,
      () => api.post(
        '/logistics/pickup-requests',
        body: {
          'pickup_date': _ymd(day),
          'batch_references': [for (final s in stops) s.ref],
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
    final home = _date == null ? <_Stop>[] : _homeOn(_date!);
    final away = widget.stops.length - home.length;
    final nothing = _trucks == 0 && _volunteers == 0 && _pushcarts == 0;
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
                'For a Door to Door pickup run. DRRMO sees the stops, the '
                'landmarks and what to load, not the donors\' numbers.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v16,
              Text('Pickup day', style: t.titleSmall),
              Gaps.v8,
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  for (final d in _dates)
                    ChoiceChip(
                      label: Text('${_label(d)} · ${_homeOn(d).length}'),
                      selected: _date == d,
                      onSelected: _homeOn(d).isEmpty
                          ? null
                          : (_) => setState(() => _date = d),
                    ),
                ],
              ),
              Gaps.v8,
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
                      _date == null
                          ? 'No donor is home on the next pickup days.'
                          : '${home.length} stop${home.length == 1 ? '' : 's'} '
                                'on ${_label(_date!)}, in this order:',
                      style: t.titleSmall,
                    ),
                    Gaps.v4,
                    for (var i = 0; i < home.length && i < 8; i++)
                      Text(
                        '${i + 1}. ${home[i].landmark.isEmpty ? home[i].address : home[i].area}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    if (home.length > 8) Text('and ${home.length - 8} more'),
                    if (away > 0 || widget.skipped > 0) ...[
                      Gaps.v4,
                      Text(
                        [
                          if (away > 0) '$away not home that day (left out)',
                          if (widget.skipped > 0)
                            '${widget.skipped} already in another request',
                        ].join(' · '),
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
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
                home.isEmpty
                    ? 'Send request'
                    : 'Send request for ${home.length} stop${home.length == 1 ? '' : 's'}',
                icon: Icons.send,
                expand: true,
                loading: _busy,
                onPressed: home.isEmpty || nothing || _busy ? null : _send,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
