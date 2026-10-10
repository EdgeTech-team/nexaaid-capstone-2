import 'package:flutter/material.dart';

import '../api.dart' show ApiResult, Roles;
import 'records_screens.dart' show DonationRecordsScreen, SupportRecordsScreen;
import 'delivery_widgets.dart';
import 'trip_screens.dart';
import 'widgets.dart';
import 'entry_report_views.dart' show EntrySummaryList;

const _deliverySteps = ['Preparing', 'In Transit', 'Delivered', 'Confirmed'];

/// Preparing -> In Transit -> Delivered -> Confirmed, as a dot stepper.
class DeliveryStepper extends StatelessWidget {
  final String status;
  const DeliveryStepper(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final at = _deliverySteps.indexOf(status);
    final on = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        for (var i = 0; i < _deliverySteps.length; i++) ...[
          Column(
            children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: i <= at ? on : Colors.black12,
                child: i < at || (i == at && i == _deliverySteps.length - 1)
                    ? const Icon(Icons.check, size: 14, color: Colors.white)
                    : Text(
                        '${i + 1}',
                        style: TextStyle(
                          fontSize: 11,
                          color: i <= at ? Colors.white : Colors.black54,
                        ),
                      ),
              ),
              const SizedBox(height: 3),
              Text(
                _deliverySteps[i],
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: i == at ? FontWeight.w700 : FontWeight.normal,
                ),
              ),
            ],
          ),
          if (i < _deliverySteps.length - 1)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(bottom: 14),
                color: i < at ? on : Colors.black12,
              ),
            ),
        ],
      ],
    );
  }
}

/// Timeline of a delivery's status changes (who, when).
Future<void> showDeliveryHistory(BuildContext context, int deliveryId) async {
  final r = await api.get('/deliveries/$deliveryId/history');
  if (!context.mounted || !r.ok) return;
  final h = (r.json['history'] as List).cast<Map>();
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (_) => ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Text(
          'Delivery #$deliveryId history',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (final e in h)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.schedule, color: Brand.pink),
            title: Text(
              e['new']?['status'] != null
                  ? '${e['action']}: ${e['new']['status']}'
                  : '${e['action']}',
            ),
            subtitle: Text('${niceDate(e['at'])} · ${e['by']}'),
          ),
      ],
    ),
  );
}

// ---------------------------------------------------------------------------
// UC-CM2 release & delivery tracking (CSWS) and UC-B1 receive & acknowledge
// (Barangay Receiving Representative)
// ---------------------------------------------------------------------------
class DeliveriesScreen extends StatefulWidget {
  final bool barangay;

  /// Appendix H 8.5 View delivery records only (Administrator, DRRMO).
  final bool readOnly;
  const DeliveriesScreen({
    super.key,
    this.barangay = false,
    this.readOnly = false,
  });

feature/donation-expiry-delivery-trips
feature/donation-expiry-delivery-trips
copy-develop
  @override
  State<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

/// Sort options shown as plain words (backend: services/delivery_views.py).
const _deliverySorts = {
  'newest': 'Newest first',
  'oldest': 'Oldest first',
  'date_soonest': 'Delivery date: soonest',
  'date_latest': 'Delivery date: latest',
  'status': 'Needs action first',
};

class _DeliveriesScreenState extends State<DeliveriesScreen> {
  bool get barangay => widget.barangay;
  bool get readOnly => widget.readOnly;

  // Filters (all optional). Changing one reloads the list.
  String? status;
  String sort = 'newest';
  String search = '';
  DateTimeRange? dates;
  final searchC = TextEditingController();

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, String> get _query => {
    'sort': sort,
    'limit': '200',
    if (status != null) 'status': status!,
    if (search.trim().isNotEmpty) 'q': search.trim(),
    if (dates != null) 'date_from': _ymd(dates!.start),
    if (dates != null) 'date_to': _ymd(dates!.end),
  };

  bool get _filtered =>
      status != null || search.trim().isNotEmpty || dates != null;

  void _clearFilters() => setState(() {
    status = null;
    search = '';
    searchC.clear();
    dates = null;
  });

  Future<void> _pickDates() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: dates,
      helpText: 'Show deliveries between',
    );
    if (picked != null) setState(() => dates = picked);
  }

feature/donation-expiry-delivery-trips
copy-develop
  
copy-develop
  Future<void> _requestTransport(BuildContext context, Map d) async {
    // I4: pick the numbers, no typing.
    final v = await formDialog(
      context,
      title: 'Request DRRMO logistics support',
      message: 'For delivery #${d['delivery_id']}. Choose what is needed.',
      fields: [
        DialogField(
          'trucks',
          'Trucks needed',
          initial: '1',
          options: [for (var i = 1; i <= 10; i++) '$i'],
        ),
        DialogField(
          'drivers',
          'Drivers needed',
          initial: '1',
          options: [for (var i = 0; i <= 10; i++) '$i'],
        ),
        DialogField(
          'volunteers',
          'Volunteers needed',
          initial: '0',
          options: [for (var i = 0; i <= 20; i++) '$i'],
        ),
      ],
      confirm: 'Send request',
    );
    if (v == null || !context.mounted) return;
    await act(
      context,
      () => api.post(
        '/logistics/requests',
        body: {
          'delivery_id': d['delivery_id'],
          'trucks': int.parse(v['trucks']!),
          'drivers': int.parse(v['drivers']!),
          'volunteers': int.parse(v['volunteers']!),
        },
      ),
      success: 'Logistics request sent to DRRMO',
    );
  }

  Future<void> _confirmReceipt(BuildContext context, Map d) async {
    final v = await formDialog(
      context,
      title: 'Confirm receipt',
      message:
          'Confirm that delivery #${d['delivery_id']} arrived. If it is '
          'incomplete you can wait until it is resolved (UC-B1 4a).',
      fields: const [
        DialogField(
          'remarks',
          'Remarks (optional)',
          required: false,
          multiline: true,
        ),
      ],
      confirm: 'Confirm receipt',
    );
    if (v == null || !context.mounted) return;
    await act(
      context,
      () => api.post(
        '/deliveries/${d['delivery_id']}/confirm-receipt',
        body: {'remarks': v['remarks']!.isEmpty ? null : v['remarks']},
      ),
      success: 'Receipt confirmed. Fulfillment updated.',
    );
  }

  /// Barangay rep: one tap for every delivery of a trip that arrived here.
  Future<void> _confirmTrip(BuildContext context, int tripId, int n) async {
    final v = await formDialog(
      context,
      title: 'Confirm all $n deliveries?',
      message:
          'Trip #$tripId brought $n deliveries to your barangay. Confirm only '
          'if everything arrived. If something is missing, confirm the '
          'deliveries one by one instead.',
      fields: const [
        DialogField(
          'remarks',
          'Remarks (optional)',
          required: false,
          multiline: true,
        ),
      ],
      confirm: 'Confirm all',
    );
    if (v == null || !context.mounted) return;
    await act(
      context,
      () => api.post(
        '/trips/$tripId/confirm-receipt',
        body: {'remarks': v['remarks']!.isEmpty ? null : v['remarks']},
      ),
      success: '$n deliveries confirmed. Fulfillment updated.',
    );
  }

  /// "Prepare delivery": one report, or several reports on one truck.
  void _prepare(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'What are you sending?',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              Gaps.v12,
              AppCard(
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NewDeliveryScreen(),
                    ),
                  );
                },
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.inventory, size: 32),
                  title: Text('Goods for one report'),
                  subtitle: Text('One delivery to one barangay.'),
                  trailing: Icon(Icons.chevron_right),
                ),
              ),
              Gaps.v8,
              AppCard(
                onTap: () {
                  Navigator.pop(ctx);
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const TripPlannerScreen(),
                    ),
                  );
                },
                child: const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.local_shipping, size: 32),
                  title: Text('Several reports on one truck'),
                  subtitle: Text(
                    'Plan a trip, e.g. 3 Banilad reports and 2 nearby '
                    'barangays in one go.',
                  ),
                  trailing: Icon(Icons.chevron_right),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filters(BuildContext context, Map counts) {
    final t = Theme.of(context).textTheme;
    String chip(String? s) =>
        s == null ? 'All (${counts['total'] ?? 0})' : '$s (${counts[s] ?? 0})';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final s in <String?>[null, ..._deliverySteps, 'Cancelled'])
                Padding(
                  padding: const EdgeInsets.only(right: Space.xs),
                  child: ChoiceChip(
                    label: Text(chip(s)),
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
            labelText: 'Search barangay, item or delivery no.',
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
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            PopupMenuButton<String>(
              tooltip: 'Sort',
              initialValue: sort,
              onSelected: (v) => setState(() => sort = v),
              itemBuilder: (_) => [
                for (final e in _deliverySorts.entries)
                  PopupMenuItem(value: e.key, child: Text(e.value)),
              ],
              child: Chip(
                avatar: const Icon(Icons.sort, size: 18),
                label: Text(_deliverySorts[sort]!),
              ),
            ),
            InputChip(
              avatar: const Icon(Icons.date_range, size: 18),
              label: Text(
                dates == null
                    ? 'Any date'
                    : '${niceDay(dates!.start)} – ${niceDay(dates!.end)}',
              ),
              onPressed: _pickDates,
              onDeleted: dates == null
                  ? null
                  : () => setState(() => dates = null),
            ),
            if (_filtered)
              TextButton(
                onPressed: _clearFilters,
                child: Text('Clear filters', style: t.labelLarge),
              ),
          ],
        ),
        Gaps.v12,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: barangay || readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _prepare(context),
              icon: const Icon(Icons.add),
              label: const Text('Prepare delivery'),
            ),
      body: Loader(
        // A new key reloads the list whenever a filter changes.
        key: ValueKey(_query.toString()),
        load: [
          () => api.get('/deliveries/', query: _query),
          api.lookupsResult,
          barangay
              ? () => api.get('/dashboard/barangay')
              : api.role == Roles.drrmo
              ? () => api.get('/drrmo/requests')
              : () => api.get('/logistics/requests'),
          () => api.get('/deliveries/counts'),
        ],
        builder: (context, data) {
          final names = Names(Map<String, dynamic>.from(data[1] as Map));
          final rows = (data[0] as List).cast<Map>();
          final counts = data[3] as Map;
          final acked = barangay
              ? ((data[2] as Map)['acknowledged_deliveries'] as List).toSet()
              : <dynamic>{};
          final requests = <dynamic, Map>{};
          if (!barangay) {
            for (final r in (data[2] as List).cast<Map>().reversed) {
              requests[r['delivery_id']] = r; // latest request per delivery
            }
          }
          // Barangay: trips that brought several deliveries that are now
          // waiting for confirmation, so they can confirm them in one tap.
          final waitingByTrip = <int, int>{};
          if (barangay) {
            for (final d in rows) {
              if (d['trip_id'] != null && d['status'] == 'Delivered') {
                final id = d['trip_id'] as int;
                waitingByTrip[id] = (waitingByTrip[id] ?? 0) + 1;
              }
            }
            waitingByTrip.removeWhere((_, n) => n < 2);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            children: [
              PageHeader(
                barangay
                    ? 'Incoming Aid'
                    : readOnly
                    ? 'Delivery Records'
                    : 'Release & Delivery Tracking',
                subtitle: barangay
                    ? 'Aid for your assigned barangay. Confirm receipt when it '
                          'arrives, then acknowledge it.'
                    : readOnly
                    ? 'Every delivery with its tracking status and history.'
                    : 'Prepare goods from a report\'s inventory, then move the '
                          'status one step at a time.',
              ),
              if (!barangay)
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Space.xs,
                  children: [
                    TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const TripsScreen()),
                      ),
                      icon: const Icon(Icons.local_shipping_outlined),
                      label: const Text('Trips'),
                    ),
                    if (!readOnly)
                      TextButton.icon(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => Scaffold(
                              appBar: AppBar(
                                title: const Text('Logistics support records'),
                              ),
                              body: const SupportRecordsScreen(),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.fire_truck_outlined),
                        label: const Text('Logistics support records'),
                      ),
                  ],
                ),
              _filters(context, counts),
              for (final e in waitingByTrip.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: AppCard(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    child: Row(
                      children: [
                        const Icon(Icons.local_shipping, size: 28),
                        Gaps.h12,
                        Expanded(
                          child: Text(
                            'Trip #${e.key} arrived with ${e.value} deliveries '
                            'for your barangay.',
                          ),
                        ),
                        Gaps.h8,
                        FilledButton(
                          onPressed: () =>
                              _confirmTrip(context, e.key, e.value),
                          child: const Text('Confirm all'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (rows.isEmpty)
                EmptyState(
                  _filtered
                      ? 'No deliveries match these filters.'
                      : barangay
                      ? 'No deliveries to your barangay yet.'
                      : readOnly
                      ? 'No deliveries yet.'
                      : 'No deliveries yet. Tap "Prepare delivery".',
                ),
              for (final d in rows)
                _card(
                  context,
                  d,
                  names,
                  acked.contains(d['delivery_id']),
                  requests[d['delivery_id']],
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _card(
    BuildContext context,
    Map d,
    Names names,
    bool acknowledged,
    Map? request,
  ) {
    final status = '${d['status']}';
    final i = _deliverySteps.indexOf(status);
    final next = i >= 0 && i < 2 ? _deliverySteps[i + 1] : null;
    final items = (d['items'] as List? ?? const [])
        .map(
          (it) =>
              '${it['quantity']} ${it['unit'] ?? ''} '
                      '${it['item_name'] ?? names.of('items', it['item_id'], fallback: 'item')}'
                  .replaceAll(RegExp(r'\s+'), ' '),
        )
        .join(', ');
    final reqStage = request?['stage'] as String?;
    final barangayName =
        d['destination_barangay_name'] ??
        names.of('barangays', d['destination_barangay_id']);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Delivery #${d['delivery_id']} to $barangayName',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Badge2.status(status),
              ],
            ),
            const SizedBox(height: 4),
            Text(items.isEmpty ? 'No items' : items),
            Text(
              '${d['report_label'] ?? names.of('reports', d['report_id'], fallback: 'Report #${d['report_id']}')}'
              ' · ${niceDate(d['delivery_date'])}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (d['trip_id'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ActionChip(
                  avatar: const Icon(Icons.local_shipping_outlined, size: 18),
                  label: Text(
                    'Trip #${d['trip_id']}'
                    '${d['stop_order'] != null ? ' · Stop ${d['stop_order']}' : ''}',
                  ),
                  onPressed: barangay
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                TripDetailScreen(tripId: d['trip_id'] as int),
                          ),
                        ),
                ),
              ),
            if (request != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    const Icon(Icons.fire_truck_outlined, size: 16),
                    const SizedBox(width: 4),
                    const Text('DRRMO: ', style: TextStyle(fontSize: 12)),
                    Badge2.status(reqStage ?? 'Pending'),
                    if (request['scheduled_date'] != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        niceDate(request['scheduled_date']),
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            if (acknowledged)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(Icons.verified, size: 16, color: Color(0xFF2E7D32)),
                    SizedBox(width: 4),
                    Text(
                      'Acknowledged by the barangay',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            if (status == 'Cancelled')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Cancelled${d['cancelled_at'] != null ? ' on ${niceDate(d['cancelled_at'])}' : ''}'
                  '${d['cancel_reason'] != null ? ': ${d['cancel_reason']}' : ''}. '
                  'The goods went back to the report\'s stock.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              )
            else ...[
              const SizedBox(height: 12),
              DeliveryStepper(status),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 6,
              children: [
                TextButton.icon(
                  onPressed: () =>
                      showDeliveryHistory(context, d['delivery_id'] as int),
                  icon: const Icon(Icons.history),
                  label: const Text('History'),
                ),
                // Unexpected problems: new date, truck came back, cancel,
                // or no longer need DRRMO (delivery_widgets.dart).
                if (!barangay &&
                    !readOnly &&
                    (status == 'Preparing' || status == 'In Transit'))
                  TextButton.icon(
                    onPressed: () =>
                        showDeliveryProblems(context, d, request: request),
                    icon: const Icon(Icons.report_problem_outlined),
                    label: const Text('Something went wrong?'),
                  ),
                if (!barangay &&
                    !readOnly &&
                    (status == 'Preparing' || status == 'In Transit') &&
                    (request == null ||
                        reqStage == 'Declined' ||
                        reqStage == 'Cancelled' ||
                        reqStage == 'Completed'))
                  OutlinedButton.icon(
                    onPressed: () => _requestTransport(context, d),
                    icon: const Icon(Icons.fire_truck_outlined),
                    label: const Text('Request transport'),
                  ),
                if (!barangay && !readOnly && next != null)
                  FilledButton.icon(
                    onPressed: () => act(
                      context,
                      () => api.post('/deliveries/${d['delivery_id']}/advance'),
                      success: 'Delivery #${d['delivery_id']} is now $next',
                    ),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text('Mark $next'),
                  ),
                if (barangay && status == 'Delivered')
                  FilledButton.icon(
                    onPressed: () => _confirmReceipt(context, d),
                    icon: const Icon(Icons.task_alt),
                    label: const Text('Confirm receipt'),
                  ),
                if (barangay && status == 'Confirmed' && !acknowledged)
                  FilledButton.icon(
                    onPressed: () => act(
                      context,
                      () => api.post(
                        '/deliveries/${d['delivery_id']}/acknowledge',
                      ),
                      success: 'Aid acknowledged',
                    ),
                    icon: const Icon(Icons.verified_outlined),
                    label: const Text('Acknowledge'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// "Oct 12" for compact chips.
String niceDay(DateTime d) {
  const m = [
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
  return '${m[d.month - 1]} ${d.day}';
}

/// Prepare goods for release from ONE validated report's inventory
/// (UC-CM2 step 3). For several reports on one truck use TripPlannerScreen.
///
/// Built for staff in a hurry:
///   1. Pick the report from a searchable list (only reports with stock).
///   2. The destination is the report's own barangay, shown as text. "Change"
///      is there for the rare case the goods go somewhere else.
///   3. Every item in stock is a row with a quantity box (no dropdowns, so
///      it still works with many items). Empty box = not sent.
///   4. Pick the date and time, then Prepare delivery.
class NewDeliveryScreen extends StatefulWidget {
  const NewDeliveryScreen({super.key});

  @override
  State<NewDeliveryScreen> createState() => _NewDeliveryScreenState();
}

class _NewDeliveryScreenState extends State<NewDeliveryScreen> {
  final _form = GlobalKey<FormState>();
  late Future<List<ApiResult>> _load = _fetch();
  Map? report; // row from /trips/candidates (with its items)
  String? brgyId; // destination; defaults to the report's barangay
  bool changeBrgy = false;
  final Map<int, TextEditingController> qty = {};
  String? date; // ISO, UTC
  bool tried = false;
  bool busy = false;

  Future<List<ApiResult>> _fetch() =>
      Future.wait([api.get('/trips/candidates'), api.lookupsResult()]);

  @override
  void dispose() {
    for (final c in qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctrl(int itemId) =>
      qty.putIfAbsent(itemId, () => TextEditingController());

  List<Map> get _items =>
      report == null ? const [] : (report!['items'] as List).cast<Map>();

  Future<void> _chooseReport(Map candidates) async {
    final r = await pickReportWithStock(context, candidates);
    if (r == null || !mounted) return;
    setState(() {
      report = r;
      brgyId = '${r['barangay_id']}';
      changeBrgy = false;
      for (final c in qty.values) {
        c.clear();
      }
    });
  }

  Future<void> _submit() async {
    setState(() => tried = true);
    if (report == null) return;
    if (!_form.currentState!.validate()) return;
    final lines = linesFrom(_items, _ctrl);
    if (lines.isEmpty || date == null) return;
    setState(() => busy = true);
    final r = await act(
      context,
      () => api.post(
        '/deliveries/',
        body: {
          'report_id': report!['report_id'],
          'destination_barangay_id': int.parse(brgyId!),
          'delivery_date': date,
          'items': lines,
        },
      ),
      success: 'Delivery prepared',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) {
      Navigator.pop(context);
    } else if (r.status == 409) {
      // Stock changed meanwhile: reload the numbers.
      setState(() {
        report = null;
        _load = _fetch();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Prepare delivery')),
      body: FutureBuilder<List<ApiResult>>(
        future: _load,
        builder: (context, snap) {
          if (!snap.hasData) return const SkeletonList();
          final bad = snap.data!.where((r) => !r.ok).toList();
          if (bad.isNotEmpty) {
            return ErrorView.forStatus(
              bad.first.status,
              bad.first.errorText,
              onRetry: () => setState(() => _load = _fetch()),
            );
          }
          final candidates = snap.data![0].json as Map;
          final names = Names(
            Map<String, dynamic>.from(snap.data![1].json as Map),
          );
          final lines = linesFrom(_items, _ctrl);
          final noReports = (candidates['barangays'] as List).isEmpty;
          return Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: [
                // 1. Report
                Text('1. Which report?', style: t.titleMedium),
                Gaps.v8,
                if (noReports)
                  const EmptyView(
                    compact: true,
                    icon: Icons.inventory_2_outlined,
                    title: 'Nothing to send yet',
                    message:
                        'No report has goods in stock. Receive donations '
                        'first (Receive tab).',
                  )
                else
                  InkWell(
                    onTap: () => _chooseReport(candidates),
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Report',
                        prefixIcon: const Icon(Icons.assignment_outlined),
                        suffixIcon: const Icon(Icons.search),
                        errorText: tried && report == null
                            ? 'Choose a report'
                            : null,
                      ),
                      child: Text(
                        report == null
                            ? 'Tap to choose (search by number or barangay)'
                            : '${report!['report_label']}',
                        style: report == null
                            ? TextStyle(color: cs.onSurfaceVariant)
                            : null,
                      ),
                    ),
                  ),
                if (report != null) ...[
                  // Destination: the report's barangay unless changed.
                  Gaps.v8,
                  if (!changeBrgy)
                    Row(
                      children: [
                        Icon(Icons.place_outlined, color: cs.primary),
                        Gaps.h8,
                        Expanded(
                          child: Text(
                            'Delivering to ${names.of('barangays', brgyId, fallback: '${report!['barangay_name']}')}',
                            style: t.bodyLarge,
                          ),
                        ),
                        TextButton(
                          onPressed: () => setState(() => changeBrgy = true),
                          child: const Text('Change'),
                        ),
                      ],
                    )
                  else
                    LookupDropdown(
                      list: 'barangays',
                      label: 'Deliver to which barangay?',
                      value: brgyId,
                      names: names,
                      onChanged: (v) => setState(() => brgyId = v),
                    ),
                  // 2. Items
                  Gaps.v24,
                  Text('2. What to send', style: t.titleMedium),
                  Gaps.v8,
                  StockQuantities(
                    key: ValueKey('items-${report!['report_id']}'),
                    items: _items,
                    controllerFor: _ctrl,
                    onChanged: () => setState(() {}),
                  ),
                  if (tried && lines.isEmpty)
                    Text(
                      'Enter a quantity for at least one item.',
                      style: TextStyle(color: cs.error),
                    ),
                  // 3. When
                  Gaps.v24,
                  Text('3. When will it leave?', style: t.titleMedium),
                  Gaps.v8,
                  DateField(
                    label: 'Delivery date and time',
                    value: date,
                    error: tried && date == null
                        ? 'Pick a date and time'
                        : null,
                    onTap: () async {
                      final d = await pickDeliveryDateTime(
                        context,
                        current: date,
                      );
                      if (d != null) setState(() => date = d);
                    },
                  ),
                  Gaps.v24,
                  if (lines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Sending ${lines.length} '
                        '${lines.length == 1 ? 'item' : 'items'}'
                        '${date == null ? '' : ' on ${niceWhen(date)}'}.',
                        style: t.bodyMedium,
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: busy ? null : _submit,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    icon: const Icon(Icons.inventory),
                    label: const Text('Prepare delivery'),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-C1 / UC-C2 City donation confirmation (CMO Representative)
// ---------------------------------------------------------------------------
class CmoScreen extends StatefulWidget {
  const CmoScreen({super.key});

  @override
  State<CmoScreen> createState() => _CmoScreenState();
}

class _CmoScreenState extends State<CmoScreen> {
  String view = 'pending';

  /// 5.1: null = all pending; 'On Hold' / 'Pending Review' = only those.
  String? decision;
  final _listKey = GlobalKey();

  /// 5.1: a tile was tapped. Filter the list and scroll down to it.
  void _show(String v, [String? d]) {
    setState(() {
      view = v;
      decision = d;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _listKey.currentContext;
      if (c != null) {
        Scrollable.ensureVisible(
          c,
          duration: const Duration(milliseconds: 300),
        );
      }
    });
  }

  Future<void> _decide(Map d, String decision) async {
    String? notes;
    if (decision != 'Confirmed') {
      final v = await formDialog(
        context,
        title: decision == 'On Hold' ? 'Put on hold' : 'Keep for review',
        fields: const [DialogField('notes', 'Reason', multiline: true)],
      );
      if (v == null) return;
      notes = v['notes'];
    }
    if (!mounted) return;
    await act(
      context,
      () => api.post(
        '/cmo/donations/${d['donation_id']}/confirm',
        body: {'status': decision, 'notes': notes},
      ),
      success: decision == 'Confirmed'
          ? '${d['qr_reference']} officially confirmed'
          : '${d['qr_reference']} marked $decision',
    );
  }

  Widget _donationCard(Map d) {
    final confirmed = d['officially_recognized'] == true;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${d['quantity']} ${d['unit']} ${d['item_name']}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (confirmed)
                  const Badge2(
                    'City confirmed',
                    Color(0xFF2E7D32),
                    icon: Icons.verified,
                  )
                else
                  Badge2.status(d['cmo_decision'] as String? ?? 'Received'),
              ],
            ),
            Text('${d['qr_reference']} · ${d['packaging']}'),
            Text(
              'For ${d['report_label'] ?? 'report'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (d['cmo_notes'] != null && !confirmed)
              Text(
                'Note: ${d['cmo_notes']}',
                style: const TextStyle(fontSize: 12, color: Brand.muted),
              ),
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: confirmed
                  ? [
                      OutlinedButton.icon(
                        onPressed: () => act(
                          context,
                          () => api.post(
                            '/cmo/donations/${d['donation_id']}/revert',
                          ),
                          success: 'Confirmation reversed',
                        ),
                        icon: const Icon(Icons.undo),
                        label: const Text('Revert'),
                      ),
                    ]
                  : [
                      TextButton(
                        onPressed: () => _decide(d, 'Pending Review'),
                        child: const Text('Review'),
                      ),
                      OutlinedButton(
                        onPressed: () => _decide(d, 'On Hold'),
                        child: const Text('Hold'),
                      ),
                      FilledButton.icon(
                        onPressed: () => _decide(d, 'Confirmed'),
                        icon: const Icon(Icons.verified),
                        label: const Text('Confirm'),
                      ),
                    ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/cmo/dashboard'),
        () => api.get('/cmo/donations/pending'),
        () => api.get('/cmo/donations/confirmed'),
        () => api.get('/donations/entries'),
      ],
      builder: (context, data) {
        final dash = data[0] as Map;
        final pending = (data[1] as List).cast<Map>();
        final confirmed = (data[2] as List).cast<Map>();
        final perReport = (dash['per_report'] as List).cast<Map>();
        final rows = view == 'pending'
            ? pending
                  .where(
                    (d) => decision == null || d['cmo_decision'] == decision,
                  )
                  .toList()
            : confirmed;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader('City Donation Confirmation', subtitle: roleLine()),
            // Appendix H 4.4 / 4.5: the CMO also views donation records.
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => Scaffold(
                      appBar: AppBar(title: const Text('Donation records')),
                      body: const DonationRecordsScreen(header: false),
                    ),
                  ),
                ),
                icon: const Icon(Icons.folder_open_outlined),
                label: const Text('All donation records'),
              ),
            ),
            StatGrid([
              StatTile(
                'Pending city confirmation',
                '${dash['pending_confirmation']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
                onTap: () => _show('pending'),
              ),
              StatTile(
                'On hold',
                '${dash['on_hold']}',
                Icons.pause_circle_outline,
                onTap: () => _show('pending', 'On Hold'),
              ),
              StatTile(
                'Pending review',
                '${dash['pending_review']}',
                Icons.rate_review_outlined,
                onTap: () => _show('pending', 'Pending Review'),
              ),
              StatTile(
                'Officially confirmed',
                '${dash['confirmed']}',
                Icons.verified,
                color: const Color(0xFF2E7D32),
                onTap: () => _show('confirmed'),
              ),
            ]),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              key: _listKey,
              segments: [
                ButtonSegment(
                  value: 'pending',
                  label: Text('Pending (${pending.length})'),
                ),
                ButtonSegment(
                  value: 'confirmed',
                  label: Text('Confirmed (${confirmed.length})'),
                ),
              ],
              selected: {view},
              onSelectionChanged: (s) => setState(() {
                view = s.first;
                decision = null;
              }),
            ),
            if (view == 'pending' && decision != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: InputChip(
                    label: Text('Only: $decision'),
                    onDeleted: () => setState(() => decision = null),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              EmptyState(
                view == 'pending'
                    ? 'No donations waiting for confirmation.'
                    : 'No confirmed donations yet.',
              ),
            for (final d in rows) _donationCard(d),
            const SectionTitle('Donation entries per report'),
            EntrySummaryList(data[3] as Map),
            const SectionTitle('City confirmation per report'),
            if (perReport.isEmpty) const EmptyState('No donations yet.'),
            for (final r in perReport)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${r['report_label']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      if (r['priority_level'] != null)
                        Text(
                          'Priority: ${r['priority_level']}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      const SizedBox(height: 4),
                      Text(
                        '${r['confirmed_count']} confirmed '
                        '(${r['confirmed_quantity']} units'
                        '${(r['confirmed_value'] as num) > 0 ? ', PHP ${(r['confirmed_value'] as num).toStringAsFixed(0)}' : ''}'
                        ') · ${r['pending_count']} pending',
                      ),
                      const SizedBox(height: 8),
                      Progress(
                        delivered: 0,
                        needed: 0,
                        percent: r['fulfillment_percentage'] as num,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// UC-DR1 / UC-DR2 Logistics support (DRRMO)
// ---------------------------------------------------------------------------
class DrrmoScreen extends StatefulWidget {
  const DrrmoScreen({super.key});

  @override
  State<DrrmoScreen> createState() => _DrrmoScreenState();
}

class _DrrmoScreenState extends State<DrrmoScreen> {
  String stage = 'Pending';

  Future<void> _accept(Map r) async {
    final v = await formDialog(
      context,
      title: 'Accept request #${r['request_id']}?',
      message:
          '${r['notes'] ?? 'No details'}\n'
          'Destination: ${r['destination'] ?? '-'}',
      fields: const [],
      confirm: 'Accept',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.patch('/drrmo/requests/${r['request_id']}/accept'),
      success: 'Request accepted',
    );
  }

  Future<void> _decline(Map r) async {
    final v = await formDialog(
      context,
      title: 'Decline request #${r['request_id']}',
      message: 'CSWS will see the reason and make other arrangements.',
      fields: const [DialogField('notes', 'Reason', multiline: true)],
      confirm: 'Decline',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.patch(
        '/drrmo/requests/${r['request_id']}/decline',
        body: {'notes': v['notes']},
      ),
      success: 'Request declined',
    );
  }

  /// Accepted, but something changed (truck broke down, sent to an
  /// emergency). CSWS is told and can ask again or find another vehicle.
  Future<void> _withdraw(Map r) async {
    final why = await askReason(
      context,
      title: 'Can no longer do request #${r['request_id']}?',
      message: 'CSWS will be told right away so they can find another vehicle.',
      choices: const [
        'The truck broke down',
        'The truck was sent to an emergency',
        'No driver available',
        'The road is closed or unsafe',
      ],
      confirm: 'Tell CSWS',
      danger: true,
    );
    if (why == null || !mounted) return;
    await act(
      context,
      () => api.post(
        '/drrmo/requests/${r['request_id']}/withdraw',
        body: {'reason': why},
      ),
      success: 'CSWS was told you can no longer help',
    );
  }

  Future<void> _complete(Map r) async {
    final v = await formDialog(
      context,
      title: 'Record logistics assistance',
      message:
          'Goods: ${(r['goods'] as List).join(', ')}\n'
          'Destination: ${r['destination']}',
      fields: const [
        DialogField(
          'summary',
          'Summary of the assistance given',
          hint: 'e.g. Delivered by Truck 2, 2 trips',
          multiline: true,
        ),
      ],
      confirm: 'Mark completed',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.patch(
        '/drrmo/requests/${r['request_id']}/complete',
        body: {'summary': v['summary']},
      ),
      success: 'Logistics support completed',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/drrmo/dashboard'),
        () => api.get('/drrmo/requests'),
      ],
      builder: (context, data) {
        final dash = data[0] as Map;
        final all = (data[1] as List).cast<Map>();
        final rows = all.where((r) => r['stage'] == stage).toList();
        const stages = {
          'Pending': 'New',
          'Accepted': 'Accepted',
          'In Transit': 'In transit',
          'Completed': 'Completed',
          'Declined': 'Declined',
          'Cancelled': 'Cancelled by CSWS',
        };
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader('DRRMO Logistics Support', subtitle: roleLine()),
            StatGrid([
              StatTile(
                'New requests',
                '${dash['pending_requests']}',
                Icons.mark_email_unread_outlined,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Accepted',
                '${dash['Scheduled']}',
                Icons.event_available,
              ),
              StatTile(
                'In transit',
                '${dash['in_transit']}',
                Icons.local_shipping_outlined,
                color: const Color(0xFF1565C0),
              ),
              StatTile(
                'Completed',
                '${dash['completed']}',
                Icons.done_all,
                color: const Color(0xFF2E7D32),
              ),
            ]),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final e in stages.entries)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: Text(
                          '${e.value} (${all.where((r) => r['stage'] == e.key).length})',
                        ),
                        selected: stage == e.key,
                        onSelected: (_) => setState(() => stage = e.key),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty) const EmptyState('No requests here.'),
            for (final r in rows)
              Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Request #${r['request_id']} · to ${r['destination']}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.status('${r['stage']}'),
                        ],
                      ),
                      Text('${r['report_label'] ?? ''}'),
                      Text('Goods: ${(r['goods'] as List).join(', ')}'),
                      if (r['scheduled_date'] != null)
                        Text('Scheduled: ${niceDate(r['scheduled_date'])}'),
                      if (r['notes'] != null)
                        Text(
                          '${r['notes']}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: Brand.muted,
                          ),
                        ),
                      Text(
                        'Requested ${niceDate(r['created_at'])}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 0,
                        runSpacing: 6,
                        children: [
                          if (r['stage'] == 'Pending') ...[
                            OutlinedButton(
                              onPressed: () => _decline(r),
                              child: const Text('Decline'),
                            ),
                            const SizedBox(width: 8),
                            FilledButton.icon(
                              onPressed: () => _accept(r),
                              icon: const Icon(Icons.check),
                              label: const Text('Accept'),
                            ),
                          ],
                          if (r['stage'] == 'Accepted') ...[
                            TextButton(
                              onPressed: () => _withdraw(r),
                              child: const Text('Can no longer do this'),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (r['stage'] == 'Accepted' ||
                              r['stage'] == 'In Transit')
                            FilledButton.icon(
                              onPressed: () => _complete(r),
                              icon: const Icon(Icons.done_all),
                              label: const Text('Mark completed'),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
