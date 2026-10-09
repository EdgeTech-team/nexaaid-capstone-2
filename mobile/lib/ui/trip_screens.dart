import 'package:flutter/material.dart';

import '../api.dart' show ApiResult, Roles;
import 'ops_screens.dart' show niceDay, showDeliveryHistory;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Delivery trips: several reports on one truck (backend: api/v1/trips.py).
//
// Example: 3 Banilad reports and 2 reports in nearby barangays go out in one
// run. Each report still gets its own delivery, so stock, the barangay's
// receipt confirmation and fulfillment work per report as before.
//
//   1. Plan       choose reports -> what to send -> when / which truck
//   2. Start      one tap: every delivery goes "In Transit"
//   3. Arrived    one tap per barangay stop: its deliveries become "Delivered"
//   4. Barangay   the rep confirms receipt (all of theirs in one tap)
//   5. Completed  automatically when every delivery is confirmed
// ---------------------------------------------------------------------------

/// Plain words for each trip status (same colors as delivery statuses).
const tripStatusLabels = {
  'Preparing': 'Being prepared',
  'In Transit': 'On the road',
  'Delivered': 'Waiting for barangay confirmation',
  'Completed': 'Completed',
};

bool get _canManageTrips =>
    api.role == Roles.cswsMain || api.role == Roles.admin;

class TripStatusChip extends StatelessWidget {
  final String status;
  const TripStatusChip(this.status, {super.key});

  @override
  Widget build(BuildContext context) =>
      StatusChip(status, label: tripStatusLabels[status] ?? status);
}

// ===========================================================================
// Trips list
// ===========================================================================
const _tripSorts = {
  'newest': 'Newest first',
  'oldest': 'Oldest first',
  'date_soonest': 'Trip date: soonest',
  'date_latest': 'Trip date: latest',
};

class TripsScreen extends StatefulWidget {
  const TripsScreen({super.key});

  @override
  State<TripsScreen> createState() => _TripsScreenState();
}

class _TripsScreenState extends State<TripsScreen> {
  String? status;
  String sort = 'newest';
  String search = '';
  final searchC = TextEditingController();

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  Map<String, String> get _query => {
    'sort': sort,
    if (status != null) 'status': status!,
    if (search.trim().isNotEmpty) 'q': search.trim(),
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Trips')),
      floatingActionButton: _canManageTrips
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const TripPlannerScreen()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Plan a trip'),
            )
          : null,
      body: Loader(
        key: ValueKey(_query.toString()),
        load: [() => api.get('/trips/', query: _query)],
        builder: (context, data) {
          final trips = (data[0] as List).cast<Map>();
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              const PageHeader(
                'Trips',
                subtitle:
                    'Several reports on one truck. Each report still gets its '
                    'own delivery and its own receipt confirmation.',
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in <String?>[null, ...tripStatusLabels.keys])
                      Padding(
                        padding: const EdgeInsets.only(right: Space.xs),
                        child: ChoiceChip(
                          label: Text(
                            s == null ? 'All' : tripStatusLabels[s]!,
                          ),
                          selected: status == s,
                          onSelected: (_) => setState(() => status = s),
                        ),
                      ),
                  ],
                ),
              ),
              Gaps.v12,
              TextField(
                controller: searchC,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  labelText: 'Search barangay, vehicle or trip no.',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: search.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            search = '';
                            searchC.clear();
                          }),
                        ),
                ),
                onSubmitted: (v) => setState(() => search = v),
              ),
              Gaps.v8,
              Align(
                alignment: Alignment.centerLeft,
                child: PopupMenuButton<String>(
                  tooltip: 'Sort',
                  initialValue: sort,
                  onSelected: (v) => setState(() => sort = v),
                  itemBuilder: (_) => [
                    for (final e in _tripSorts.entries)
                      PopupMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  child: Chip(
                    avatar: const Icon(Icons.sort, size: 18),
                    label: Text(_tripSorts[sort]!),
                  ),
                ),
              ),
              Gaps.v12,
              if (trips.isEmpty)
                EmptyState(
                  status != null || search.isNotEmpty
                      ? 'No trips match these filters.'
                      : 'No trips yet. Tap "Plan a trip" to send several '
                            'reports on one truck.',
                  icon: Icons.local_shipping_outlined,
                ),
              for (final trip in trips)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppCard(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            TripDetailScreen(tripId: trip['trip_id'] as int),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${trip['title']} · ${niceDate(trip['trip_date'])}',
                                style: t.titleMedium,
                              ),
                            ),
                            TripStatusChip('${trip['status']}'),
                          ],
                        ),
                        Gaps.v4,
                        Text(
                          [
                            for (final s in (trip['stops'] as List))
                              '${(s as Map)['barangay_name']}',
                          ].join(' → '),
                          style: t.bodyMedium,
                        ),
                        Text(
                          '${trip['total_stops']} '
                          '${trip['total_stops'] == 1 ? 'stop' : 'stops'} · '
                          '${trip['total_reports']} reports · '
                          '${trip['total_quantity']} items'
                          '${trip['vehicle_details'] != null ? ' · ${trip['vehicle_details']}' : ''}',
                          style: t.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

// ===========================================================================
// Trip detail: start, arrived at each stop, undo
// ===========================================================================
class TripDetailScreen extends StatelessWidget {
  final int tripId;
  const TripDetailScreen({super.key, required this.tripId});

  Future<void> _start(BuildContext context, Map trip) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Start the trip?'),
        content: Text(
          'Do this when the truck leaves. All ${trip['delivery_counts']['Preparing']} '
          'deliveries become "In Transit" and the barangays are notified.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Start trip'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await act(
      context,
      () => api.post('/trips/$tripId/start'),
      success: 'Trip #$tripId is on the road',
    );
  }

  Future<void> _arrived(BuildContext context, Map stop) async {
    final n = (stop['deliveries'] as List)
        .where((d) => (d as Map)['status'] == 'In Transit')
        .length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Arrived at ${stop['barangay_name']}?'),
        content: Text(
          '$n ${n == 1 ? 'delivery becomes' : 'deliveries become'} '
          '"Delivered". The barangay representative is asked to confirm '
          'receipt in their app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Yes, we arrived'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    await act(
      context,
      () => api.post('/trips/$tripId/stops/${stop['barangay_id']}/arrived'),
      success: 'Marked as delivered in ${stop['barangay_name']}',
    );
  }

  Future<void> _undo(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Undo this trip?'),
        content: const Text(
          'Its deliveries are removed and every item goes back to its '
          'report\'s stock. Use this only if the trip was prepared by '
          'mistake. The history keeps a record of the undo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep trip'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Undo trip'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final r = await act(
      context,
      () => api.delete('/trips/$tripId'),
      success: 'Trip undone. The goods are back in stock.',
    );
    if (r.ok && context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final manage = _canManageTrips;
    return Scaffold(
      appBar: AppBar(title: Text('Trip #$tripId')),
      body: Loader(
        load: [() => api.get('/trips/$tripId')],
        builder: (context, data) {
          final trip = data[0] as Map;
          final stops = (trip['stops'] as List).cast<Map>();
          final counts = trip['delivery_counts'] as Map;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text('${trip['title']}', style: t.titleLarge),
                        ),
                        TripStatusChip('${trip['status']}'),
                      ],
                    ),
                    Gaps.v8,
                    Text('Leaves: ${niceDate(trip['trip_date'])}'),
                    if (trip['vehicle_details'] != null)
                      Text('Vehicle: ${trip['vehicle_details']}'),
                    if (trip['notes'] != null) Text('Notes: ${trip['notes']}'),
                    Gaps.v8,
                    Text(
                      '${trip['total_stops']} '
                      '${trip['total_stops'] == 1 ? 'stop' : 'stops'} · '
                      '${trip['total_reports']} reports · '
                      '${trip['total_quantity']} items · '
                      '${counts['Confirmed']} of '
                      '${stops.fold<int>(0, (n, s) => n + (s['deliveries'] as List).length)} '
                      'confirmed by the barangays',
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (manage && trip['can_start'] == true) ...[
                Gaps.v12,
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () => _start(context, trip),
                  icon: const Icon(Icons.local_shipping),
                  label: const Text('Start trip (the truck is leaving)'),
                ),
              ],
              if (trip['status'] == 'Completed') ...[
                Gaps.v12,
                const AppCard(
                  child: Row(
                    children: [
                      Icon(Icons.task_alt, color: AppColors.success),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Every barangay confirmed receipt. This trip is done.',
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              for (final stop in stops) ...[
                SectionHeader(
                  'Stop ${stop['stop_order']} · ${stop['barangay_name']}',
                  action: TripStatusChip('${stop['status']}'),
                ),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final d in (stop['deliveries'] as List).cast<Map>())
                        _StopDelivery(d),
                      if (manage && stop['can_mark_arrived'] == true) ...[
                        Gaps.v8,
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            minimumSize: const Size.fromHeight(48),
                          ),
                          onPressed: () => _arrived(context, stop),
                          icon: const Icon(Icons.where_to_vote_outlined),
                          label: Text('Arrived at ${stop['barangay_name']}'),
                        ),
                      ],
                      if (stop['status'] == 'Delivered')
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Waiting for the ${stop['barangay_name']} '
                            'representative to confirm receipt in their app.',
                            style: t.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
              if (manage && trip['can_undo'] == true) ...[
                Gaps.v24,
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  onPressed: () => _undo(context),
                  icon: const Icon(Icons.undo),
                  label: const Text('Undo trip (prepared by mistake)'),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StopDelivery extends StatelessWidget {
  final Map d;
  const _StopDelivery(this.d);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final items = (d['items'] as List)
        .cast<Map>()
        .map(
          (i) => '${i['quantity']} ${i['unit'] ?? ''} ${i['item_name'] ?? ''}'
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim(),
        )
        .join(', ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Delivery #${d['delivery_id']} · ${d['report_label'] ?? 'Report #${d['report_id']}'}',
                  style: t.titleSmall,
                ),
                Text(items, style: t.bodyMedium),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () =>
                      showDeliveryHistory(context, d['delivery_id'] as int),
                  child: const Text('History'),
                ),
              ],
            ),
          ),
          StatusChip('${d['status']}'),
        ],
      ),
    );
  }
}

// ===========================================================================
// Trip planner: 1 choose reports -> 2 what to send -> 3 when and which truck
// ===========================================================================
class TripPlannerScreen extends StatefulWidget {
  const TripPlannerScreen({super.key});

  @override
  State<TripPlannerScreen> createState() => _TripPlannerScreenState();
}

class _TripPlannerScreenState extends State<TripPlannerScreen> {
  late Future<ApiResult> _candidates = api.get('/trips/candidates');
  int step = 0;
  bool busy = false;
  String search = '';

  /// report_id -> report (from GET /trips/candidates)
  final Map<int, Map> reports = {};

  /// Chosen reports, in the order they were ticked.
  final List<int> chosen = [];

  /// Barangays in the order the truck visits them (staff can reorder).
  final List<int> stopOrder = [];

  /// report_id -> item_id -> quantity field
  final Map<int, Map<int, TextEditingController>> qty = {};

  final _sendForm = GlobalKey<FormState>();
  final vehicle = TextEditingController();
  final notes = TextEditingController();
  String? date;

  @override
  void dispose() {
    for (final m in qty.values) {
      for (final c in m.values) {
        c.dispose();
      }
    }
    vehicle.dispose();
    notes.dispose();
    super.dispose();
  }

  int _brgy(int reportId) => reports[reportId]!['barangay_id'] as int;

  void _toggle(int reportId, bool on) {
    setState(() {
      if (on && !chosen.contains(reportId)) {
        chosen.add(reportId);
        for (final i in (reports[reportId]!['items'] as List).cast<Map>()) {
          _ctrl(reportId, i['item_id'] as int);
        }
        if (!stopOrder.contains(_brgy(reportId))) {
          stopOrder.add(_brgy(reportId));
        }
      } else if (!on) {
        chosen.remove(reportId);
        if (!chosen.any((r) => _brgy(r) == _brgy(reportId))) {
          stopOrder.remove(_brgy(reportId));
        }
      }
    });
  }

  /// Chosen reports grouped by stop, in visiting order.
  List<MapEntry<int, List<int>>> get _stops => [
    for (final b in stopOrder)
      MapEntry(b, [for (final r in chosen) if (_brgy(r) == b) r]),
  ];

  /// The quantity field for one item of one report (made on first use, so
  /// it also exists for items that appear after the stock is reloaded).
  TextEditingController _ctrl(int reportId, int itemId) => qty
      .putIfAbsent(reportId, () => <int, TextEditingController>{})
      .putIfAbsent(itemId, () => TextEditingController());

  int _qtyOf(int reportId, int itemId) =>
      int.tryParse(qty[reportId]?[itemId]?.text.trim() ?? '') ?? 0;

  int _reportTotal(int reportId) => [
    for (final i in (reports[reportId]!['items'] as List).cast<Map>())
      _qtyOf(reportId, i['item_id'] as int),
  ].fold(0, (a, b) => a + b);

  void _say(String text) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));

  void _next() {
    if (step == 0) {
      if (chosen.isEmpty) {
        _say('Choose at least one report.');
        return;
      }
      setState(() => step = 1);
    } else if (step == 1) {
      if (!_sendForm.currentState!.validate()) return;
      final empty = [for (final r in chosen) if (_reportTotal(r) == 0) r];
      if (empty.isNotEmpty) {
        _say(
          'Enter what to send for ${reports[empty.first]!['report_label']}, '
          'or untick it in step 1.',
        );
        return;
      }
      setState(() => step = 2);
    } else {
      _submit();
    }
  }

  Future<void> _submit() async {
    if (date == null) {
      _say('Pick when the truck leaves.');
      return;
    }
    setState(() => busy = true);
    final body = {
      'trip_date': date,
      'vehicle_details': vehicle.text.trim().isEmpty ? null : vehicle.text.trim(),
      'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
      'reports': [
        for (final stop in _stops)
          for (final r in stop.value)
            {
              'report_id': r,
              'items': [
                for (final i in (reports[r]!['items'] as List).cast<Map>())
                  if (_qtyOf(r, i['item_id'] as int) > 0)
                    {
                      'item_id': i['item_id'],
                      'quantity': _qtyOf(r, i['item_id'] as int),
                    },
              ],
            },
      ],
    };
    final res = await act(
      context,
      () => api.post('/trips/', body: body),
      success: 'Trip prepared. Tap "Start trip" when the truck leaves.',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (res.ok) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) =>
              TripDetailScreen(tripId: (res.json as Map)['trip_id'] as int),
        ),
      );
    } else if (res.status == 409) {
      // Stock changed meanwhile: reload the numbers, keep the choices.
      setState(() => _candidates = api.get('/trips/candidates'));
    }
  }

  // ---- Step 1 --------------------------------------------------------------
  Widget _chooseReports(Map data) {
    final t = Theme.of(context).textTheme;
    final q = search.trim().toLowerCase();
    bool match(Map r) =>
        q.isEmpty ||
        '${r['report_label']}'.toLowerCase().contains(q) ||
        '${r['barangay_name']}'.toLowerCase().contains(q);
    final groups = (data['barangays'] as List).cast<Map>();
    final empty = (data['no_stock_reports'] as List).cast<Map>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Tick every report going on this truck. Reports in the same '
          'barangay are listed together, most urgent first.',
          style: t.bodyMedium,
        ),
        Gaps.v8,
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search barangay or report',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => setState(() => search = v),
        ),
        Gaps.v8,
        if (groups.isEmpty)
          const EmptyState(
            'No report has stock to send yet. Receive donations first.',
            icon: Icons.inventory_2_outlined,
          ),
        for (final g in groups)
          if ((g['reports'] as List).cast<Map>().any(match)) ...[
            Row(
              children: [
                Expanded(
                  child: Text('${g['barangay_name']}', style: t.titleMedium),
                ),
                TextButton(
                  onPressed: () {
                    for (final r in (g['reports'] as List).cast<Map>()) {
                      _toggle(r['report_id'] as int, true);
                    }
                  },
                  child: const Text('Tick all here'),
                ),
              ],
            ),
            for (final r in (g['reports'] as List).cast<Map>().where(match))
              CheckboxListTile(
                value: chosen.contains(r['report_id']),
                onChanged: (v) => _toggle(r['report_id'] as int, v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: Text('${r['report_label']}'),
                subtitle: Text(
                  '${(r['items'] as List).length} '
                  '${(r['items'] as List).length == 1 ? 'item' : 'items'} in stock · '
                  '${(r['fulfillment_percentage'] as num).round()}% fulfilled',
                ),
                secondary: PriorityChip(r['priority_level'] as String?),
              ),
            const Divider(),
          ],
        if (empty.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('No more stock (${empty.length})'),
            subtitle: const Text('These reports have nothing left to send.'),
            children: [
              for (final r in empty)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.remove_shopping_cart_outlined),
                  title: Text('${r['report_label']}'),
                  subtitle: Text('${r['message']}'),
                ),
            ],
          ),
        Gaps.v8,
        Text(
          chosen.isEmpty
              ? 'Nothing ticked yet.'
              : '${chosen.length} ${chosen.length == 1 ? 'report' : 'reports'} '
                    'in ${stopOrder.length} '
                    '${stopOrder.length == 1 ? 'barangay' : 'barangays'} ticked.',
          style: t.titleSmall,
        ),
      ],
    );
  }

  // ---- Step 2 --------------------------------------------------------------
  Widget _whatToSend() {
    final t = Theme.of(context).textTheme;
    return Form(
      key: _sendForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Enter how much of each item to load. Leave an item empty to '
            'skip it.',
            style: t.bodyMedium,
          ),
          for (final stop in _stops)
            for (final rid in stop.value)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${reports[rid]!['report_label']}',
                              style: t.titleSmall,
                            ),
                          ),
                          TextButton(
                            onPressed: () => setState(() {
                              for (final i in (reports[rid]!['items'] as List)
                                  .cast<Map>()) {
                                _ctrl(rid, i['item_id'] as int).text =
                                    '${i['quantity']}';
                              }
                            }),
                            child: const Text('Send everything'),
                          ),
                        ],
                      ),
                      for (final i
                          in (reports[rid]!['items'] as List).cast<Map>())
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: TextFormField(
                            controller: _ctrl(rid, i['item_id'] as int),
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: '${i['item_name']}',
                              helperText:
                                  '${i['quantity']} ${i['unit'] ?? ''} left',
                              suffixText: '${i['unit'] ?? ''}',
                              suffixIcon: TextButton(
                                onPressed: () => setState(
                                  () => _ctrl(rid, i['item_id'] as int).text =
                                      '${i['quantity']}',
                                ),
                                child: const Text('All'),
                              ),
                            ),
                            validator: (v) {
                              final text = v?.trim() ?? '';
                              if (text.isEmpty) return null;
                              final n = int.tryParse(text);
                              if (n == null || n < 0) {
                                return 'Enter a whole number';
                              }
                              if (n > (i['quantity'] as num)) {
                                return 'Only ${i['quantity']} left';
                              }
                              return null;
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
        ],
      ),
    );
  }

  // ---- Step 3 --------------------------------------------------------------
  Widget _whenAndTruck() {
    final t = Theme.of(context).textTheme;
    final stops = _stops;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
          onPressed: () async {
            final d = await pickDateTime(context);
            if (d != null) setState(() => date = d);
          },
          icon: const Icon(Icons.event),
          label: Text(
            date == null ? 'When does the truck leave?' : niceDate(date),
          ),
        ),
        Gaps.v12,
        TextField(
          controller: vehicle,
          decoration: const InputDecoration(
            labelText: 'Vehicle (optional)',
            hintText: 'e.g. City truck, plate ABC 1234',
          ),
        ),
        Gaps.v8,
        TextField(
          controller: notes,
          maxLines: 2,
          decoration: const InputDecoration(labelText: 'Notes (optional)'),
        ),
        Gaps.v16,
        Text('Stops, in visiting order', style: t.titleSmall),
        Text(
          'Use the arrows to change the order.',
          style: t.bodySmall,
        ),
        for (var n = 0; n < stops.length; n++)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(child: Text('${n + 1}')),
            title: Text(
              '${reports[stops[n].value.first]!['barangay_name']}',
            ),
            subtitle: Text(
              '${stops[n].value.length} '
              '${stops[n].value.length == 1 ? 'report' : 'reports'} · '
              '${stops[n].value.fold<int>(0, (a, r) => a + _reportTotal(r))} items',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Visit earlier',
                  onPressed: n == 0
                      ? null
                      : () => setState(() {
                          final b = stopOrder.removeAt(n);
                          stopOrder.insert(n - 1, b);
                        }),
                  icon: const Icon(Icons.arrow_upward),
                ),
                IconButton(
                  tooltip: 'Visit later',
                  onPressed: n == stops.length - 1
                      ? null
                      : () => setState(() {
                          final b = stopOrder.removeAt(n);
                          stopOrder.insert(n + 1, b);
                        }),
                  icon: const Icon(Icons.arrow_downward),
                ),
              ],
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Plan a trip')),
      body: FutureBuilder<ApiResult>(
        future: _candidates,
        builder: (context, snap) {
          if (!snap.hasData) return const SkeletonList();
          final r = snap.data!;
          if (!r.ok) {
            return ErrorView.forStatus(
              r.status,
              r.errorText,
              onRetry: () => setState(
                () => _candidates = api.get('/trips/candidates'),
              ),
            );
          }
          final data = r.json as Map;
          reports
            ..clear()
            ..addAll({
              for (final g in (data['barangays'] as List).cast<Map>())
                for (final rep in (g['reports'] as List).cast<Map>())
                  rep['report_id'] as int: rep,
            });
          // A report that ran out of stock meanwhile drops out of the plan.
          chosen.removeWhere((id) => !reports.containsKey(id));
          stopOrder.removeWhere((b) => !chosen.any((id) => _brgy(id) == b));
          return Stepper(
            currentStep: step,
            onStepTapped: (i) {
              if (i < step) setState(() => step = i);
            },
            onStepContinue: busy ? null : _next,
            onStepCancel: step == 0 ? null : () => setState(() => step -= 1),
            controlsBuilder: (context, details) => Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                children: [
                  FilledButton(
                    onPressed: details.onStepContinue,
                    child: Text(step == 2 ? 'Prepare trip' : 'Next'),
                  ),
                  Gaps.h8,
                  if (step > 0)
                    TextButton(
                      onPressed: details.onStepCancel,
                      child: const Text('Back'),
                    ),
                ],
              ),
            ),
            steps: [
              Step(
                title: const Text('Choose reports'),
                subtitle: chosen.isEmpty
                    ? null
                    : Text('${chosen.length} chosen'),
                isActive: step >= 0,
                state: step > 0 ? StepState.complete : StepState.indexed,
                content: _chooseReports(data),
              ),
              Step(
                title: const Text('What to send'),
                isActive: step >= 1,
                state: step > 1 ? StepState.complete : StepState.indexed,
                content: step >= 1 ? _whatToSend() : const SizedBox.shrink(),
              ),
              Step(
                title: const Text('When and which truck'),
                subtitle: date == null ? null : Text(niceDay(DateTime.parse(date!))),
                isActive: step >= 2,
                content: step >= 2 ? _whenAndTruck() : const SizedBox.shrink(),
              ),
            ],
          );
        },
      ),
    );
  }
}
