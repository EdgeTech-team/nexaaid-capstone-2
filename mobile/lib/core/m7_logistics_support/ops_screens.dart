import 'dart:async';

import 'package:flutter/material.dart';

import '../shared/api.dart' show ApiResult, Roles;
import '../notifications/realtime.dart';
import '../m4_donation_management/records_screens.dart' show SupportRecordsScreen;
import '../m8_delivery_tracking/delivery_widgets.dart';
import '../shared/input_formatters.dart' show pesos;
import '../m8_delivery_tracking/trip_screens.dart';
import '../shared/widgets.dart';
import 'logistics_cards.dart';
import '../m4_donation_management/paged_donation_entries.dart' show searchDebounce;
import '../shared/paginated_list.dart';
import '../m5_inventory/receipt_count_dialog.dart';
import '../m8_delivery_tracking/acknowledgment_screen.dart';
import '../m8_delivery_tracking/handover_code.dart';
import '../m2_disaster_reporting/report_summary_card.dart' show NeedChips;
import '../shared/home_nav.dart';
import '../m8_delivery_tracking/scheduled_deliveries.dart';
import '../m8_delivery_tracking/short_deliveries_screen.dart' show openShortDeliveries;
import '../shared/item_amounts.dart';

const _deliverySteps = ['Preparing', 'In Transit', 'Delivered', 'Confirmed'];

/// Preparing -> In Transit -> Delivered -> Confirmed, as a dot stepper.
class DeliveryStepper extends StatelessWidget {
  final String status;

  /// When each step was reached (`status_times` from the delivery list,
  /// Oct 2026), shown under the step.
  final Map? times;
  const DeliveryStepper(this.status, {super.key, this.times});

  /// "Oct 23" over "2:15 PM", narrow enough for four steps on a phone.
  static String _short(dynamic iso) {
    final full = niceWhen(iso); // "Fri, Oct 23 · 2:15 PM"
    final cut = full.indexOf(', ');
    return (cut < 0 ? full : full.substring(cut + 2)).replaceAll(' · ', '\n');
  }

  @override
  Widget build(BuildContext context) {
    final at = _deliverySteps.indexOf(status);
    final on = Theme.of(context).colorScheme.primary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _deliverySteps.length; i++) ...[
          // Flexible: on a narrow phone or with large text the labels wrap
          // instead of running off the card.
          Flexible(
            flex: 2,
            child: Column(
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
                  // "Received by barangay" on two lines so four steps fit.
                  deliveryWord(_deliverySteps[i]).replaceFirst(' by ', ' by\n'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: i == at ? FontWeight.w700 : FontWeight.normal,
                  ),
                ),
                if (times?[_deliverySteps[i]] != null)
                  Text(
                    _short(times![_deliverySteps[i]]),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (i < _deliverySteps.length - 1)
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(top: 10), // level with the dots
                color: i < at ? on : Colors.black12,
              ),
            ),
        ],
      ],
    );
  }
}

/// Timeline of a delivery (who, when), in a pop-out with the X
/// (problema_napud 2.1).
Future<void> showDeliveryHistory(BuildContext context, int deliveryId) async {
  final r = await api.get('/deliveries/$deliveryId/history');
  if (!context.mounted || !r.ok) return;
  showDetailPopout<void>(
    context,
    title: 'Delivery #$deliveryId',
    child: DeliveryTimeline(deliveryId, first: r.json as Map),
  );
}

/// Table 37 in staff words: Being packed -> Truck assigned -> On the way ->
/// Arrived -> Received by barangay, each with when and who (GET
/// /deliveries/{id}/history "timeline"). Reloads by itself when a delivery
/// or DRRMO request changes (live updates). The full record is underneath.
class DeliveryTimeline extends StatefulWidget {
  final int deliveryId;
  final Map first; // the history already loaded when the pop-out opened
  const DeliveryTimeline(this.deliveryId, {super.key, required this.first});

  @override
  State<DeliveryTimeline> createState() => _DeliveryTimelineState();
}

class _DeliveryTimelineState extends State<DeliveryTimeline> {
  late Map _data = widget.first;

  @override
  void initState() {
    super.initState();
    Realtime.instance.logistics.addListener(_reload);
  }

  @override
  void dispose() {
    Realtime.instance.logistics.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final r = await api.get('/deliveries/${widget.deliveryId}/history');
    if (mounted && r.ok && r.json is Map) setState(() => _data = r.json as Map);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final steps = ((_data['timeline'] as List?) ?? const []).cast<Map>();
    final history = ((_data['history'] as List?) ?? const []).cast<Map>();
    // The next step to happen is highlighted.
    final next = steps.indexWhere((s) => s['done'] != true);
    // Phase 7: a wrong tap can be taken back for 10 minutes (the server
    // checks it is the same person and the barangay has not confirmed).
    final last = history.isEmpty ? null : history.last;
    final lastAt = DateTime.tryParse('${last?['at'] ?? ''}');
    final canUndo =
        last != null &&
        last['action'] == 'UPDATE DELIVERY STATUS' &&
        lastAt != null &&
        DateTime.now().difference(lastAt.toLocal()).inMinutes < 10 &&
        api.role != Roles.barangay;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // J2 / NF-015: the Acknowledgment Receipt once the barangay confirmed.
        if (_data['status'] == 'Confirmed' && canSeeReceipt(api.role))
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => openAcknowledgment(context, widget.deliveryId),
              icon: const Icon(Icons.receipt_long_outlined),
              label: const Text('View receipt'),
            ),
          ),
        if (canUndo)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () async {
                await act(
                  context,
                  () => api.post('/deliveries/${widget.deliveryId}/undo'),
                  success: 'Last step undone',
                );
                _reload();
              },
              icon: const Icon(Icons.undo),
              label: const Text('Undo last step'),
            ),
          ),
        for (var i = 0; i < steps.length; i++)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  Icon(
                    steps[i]['key'] == 'cancelled'
                        ? Icons.cancel
                        : steps[i]['done'] == true
                        ? Icons.check_circle
                        : i == next
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: steps[i]['key'] == 'cancelled'
                        ? cs.error
                        : steps[i]['done'] == true || i == next
                        ? cs.primary
                        : cs.outline,
                  ),
                  if (i < steps.length - 1)
                    Container(
                      width: 2,
                      height: 34,
                      color: steps[i]['done'] == true
                          ? cs.primary
                          : cs.outlineVariant,
                    ),
                ],
              ),
              Gaps.h12,
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${steps[i]['label']}',
                        style: t.titleSmall?.copyWith(
                          fontWeight: i == next || steps[i]['done'] == true
                              ? FontWeight.w700
                              : FontWeight.normal,
                          color: steps[i]['done'] == true || i == next
                              ? null
                              : cs.onSurfaceVariant,
                        ),
                      ),
                      if (steps[i]['at'] != null)
                        Text(
                          [
                            niceWhen(steps[i]['at']),
                            if (steps[i]['by'] != null) '${steps[i]['by']}',
                          ].join(' · '),
                          style: t.bodySmall,
                        ),
                      if (steps[i]['detail'] != null)
                        Text('${steps[i]['detail']}', style: t.bodySmall),
                    ],
                  ),
                ),
              ),
            ],
          ),
        if (history.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('Full record (${history.length})', style: t.titleSmall),
            children: [
              for (final e in history)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.schedule, color: Brand.pink),
                  title: Text(
                    e['new']?['status'] != null
                        ? '${e['action']}: ${deliveryWord(e['new']['status'])}'
                        : '${e['action']}',
                  ),
                  subtitle: Text('${niceDate(e['at'])} · ${e['by']}'),
                ),
            ],
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CM2 release & delivery tracking (CSWS) and UC-B1 receive & acknowledge
// (Barangay Receiving Representative)
// ---------------------------------------------------------------------------
class DeliveriesScreen extends StatefulWidget {
  final bool barangay;

  /// Appendix H 8.5 View delivery records only (Administrator, DRRMO).
  /// NF-003: these records load one page at a time.
  final bool readOnly;

  /// NF-001: the Administrator's disaster type filter (records screen).
  final int? disasterTypeId;
  final String? disasterTypeName;
  const DeliveriesScreen({
    super.key,
    this.barangay = false,
    this.readOnly = false,
    this.disasterTypeId,
    this.disasterTypeName,
  });

  @override
  State<DeliveriesScreen> createState() => _DeliveriesScreenState();
}

/// Sort options shown as plain words (backend: core/m8_delivery_tracking/delivery_views.py).
const _deliverySorts = {
  'newest': 'Newest first',
  'oldest': 'Oldest first',
  'date_soonest': 'Delivery date: soonest',
  'date_latest': 'Delivery date: latest',
  'status': 'Needs action first',
  'priority': 'Most urgent first', // 3.11 priority of the report
};

class _DeliveriesScreenState extends State<DeliveriesScreen>
    with HomeTargetListener<DeliveriesScreen> {
  bool get barangay => widget.barangay;
  bool get readOnly => widget.readOnly;

  @override
  String get homeTab => barangay ? 'Incoming aid' : 'Deliveries';

  /// The delivery a notification or "Needs your action" points at: shown
  /// first and outlined (Phase 6).
  int? _focus;

  @override
  void applyHomeTarget(HomeTarget target) {
    status = target.view; // null = every status
    search = '';
    searchC.clear();
    dates = null;
    _focus = target.id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFocus());
  }

  /// NF-003: the delivery a notification points at, loaded on its own (it
  /// may be on another page) and shown first.
  Map? _focused;

  Future<void> _loadFocus() async {
    final id = _focus;
    if (id == null) {
      if (_focused != null && mounted) setState(() => _focused = null);
      return;
    }
    final r = await api.get('/deliveries/$id');
    if (!mounted || _focus != id) return;
    setState(() => _focused = r.ok && r.json is Map ? r.json as Map : null);
  }

  // Filters (all optional). Changing one reloads the list.
  String? status;
  // Phase 6: Critical reports first, as on DRRMO's list (drrmo_router).
  String sort = 'priority';
  String search = '';
  DateTimeRange? dates;
  final searchC = TextEditingController();

  @override
  void dispose() {
    searchC.dispose();
    _pager?.removeListener(_pageChanged);
    _pager?.dispose();
    super.dispose();
  }

  // NF-001 / NF-003: the list arrives 10 at a time (numbered pages) with
  // the filters (and the disaster type, records screen) applied on the
  // server. One controller per set of filters; a new set starts at page 1.
  PagedController? _pager;
  String? _pagerFor;
  int _extras = 0;

  Map<String, String> get _pageQuery => {
    ...Map.of(_query)..remove('limit'),
    if (widget.disasterTypeId != null)
      'disaster_type_id': '${widget.disasterTypeId}',
  };

  PagedController _pagerOf(Map<String, String> query) {
    final key = query.toString();
    if (_pager == null || _pagerFor != key) {
      final old = _pager;
      old?.removeListener(_pageChanged);
      _pager = PagedController(
        fetch: (offset, limit) => api.get(
          '/deliveries/',
          query: {...query, 'limit': '$limit', 'offset': '$offset'},
        ),
      )..addListener(_pageChanged);
      _pagerFor = key;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    }
    return _pager!;
  }

  /// NF-003: the logistics request of each delivery on the page on screen,
  /// asked for those deliveries only (it used to be every request there is).
  Map<dynamic, Map> _requests = {};
  int _requestsAsked = 0;

  Future<void> _pageChanged() async {
    final p = _pager;
    if (p == null || barangay || p.isLoading) return;
    final ids = [for (final d in p.items) d['delivery_id']].join(',');
    final asked = ++_requestsAsked;
    if (ids.isEmpty) {
      if (_requests.isNotEmpty && mounted) setState(() => _requests = {});
      return;
    }
    final r = await api.get(
      api.role == Roles.drrmo ? '/drrmo/requests' : '/logistics/requests',
      query: {'delivery_ids': ids},
    );
    if (!mounted || asked != _requestsAsked || !r.ok || r.json is! List) {
      return;
    }
    final byDelivery = <dynamic, Map>{};
    for (final x in (r.json as List).cast<Map>().reversed) {
      byDelivery[x['delivery_id']] = x; // latest request per delivery
    }
    setState(() => _requests = byDelivery);
  }

  /// Appendix H 8.5 (Administrator, DRRMO): the same cards and filters,
  /// one page of 10 at a time.
  Widget _records(BuildContext context) {
    final query = _pageQuery;
    final pager = _pagerOf(query);
    return Loader(
      key: ValueKey('records-$query-$_extras'),
      load: [
        api.lookupsResult,
        () => api.get(
          '/deliveries/counts',
          query: {
            if (widget.disasterTypeId != null)
              'disaster_type_id': '${widget.disasterTypeId}',
          },
        ),
      ],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[0] as Map));
        final type = widget.disasterTypeName;
        return PagedListView(
          controller: pager,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          onRefresh: () async {
            setState(() => _extras++);
            await pager.refresh();
          },
          header: [
            const PageHeader(
              'Delivery Records',
              subtitle: 'Every delivery with its tracking status and history.',
            ),
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
              ],
            ),
            _filters(context, data[1] as Map),
          ],
          empty: EmptyState(
            _filtered
                ? 'No deliveries match these filters.'
                : type != null
                ? 'No deliveries for $type yet.'
                : 'No deliveries yet.',
          ),
          itemBuilder: (context, d) =>
              _card(context, d, names, false, _requests[d['delivery_id']]),
        );
      },
    );
  }

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Map<String, String> get _query => {
    'sort': sort,
    'limit': '200',
    'status': ?status,
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

  Future<void> _delete(BuildContext context, Map d) async {
    final v = await formDialog(
      context,
      title: 'Delete delivery #${d['delivery_id']}?',
      message:
          'It is removed from this list. Its record, receipt and the '
          'report\'s fulfillment stay as they are.',
      fields: const [],
      confirm: 'Delete',
    );
    if (v == null || !context.mounted) return;
    await act(
      context,
      () => api.delete('/deliveries/${d['delivery_id']}'),
      success: 'Delivery #${d['delivery_id']} deleted',
    );
  }

  /// UC-CM2 alt 3a. [previous] is a declined or cancelled request: Table 36
  /// alt 3a "Ask DRRMO again" starts from what was asked the last time.
  Future<void> _requestTransport(
    BuildContext context,
    Map d, {
    Map? previous,
  }) async {
    // I4: pick the numbers, no typing. Appendix H 7.1 (Oct 10 notes): no
    // driver count (a truck comes with its driver); each need can be None.
    String none(int i) => i == 0 ? 'None' : '$i';
    int before(String word) {
      final m = RegExp('(\\d+) $word')
          .firstMatch('${previous?['needs'] ?? ''}');
      return m == null ? 0 : int.parse(m.group(1)!);
    }

    final again = previous != null;
    final reason = previous?['reason'];
    final v = await formDialog(
      context,
      title: again ? 'Ask DRRMO again' : 'Request DRRMO logistics support',
      message:
          '${again && reason != null ? 'Last time DRRMO said: $reason\n\n' : ''}'
          'For delivery #${d['delivery_id']}, planned for '
          '${niceWhen(d['delivery_date'])}. Choose what is needed.',
      fields: [
        DialogField(
          'trucks',
          'Trucks needed',
          initial: again ? none(before('truck')) : '1',
          options: [for (var i = 0; i <= 10; i++) none(i)],
        ),
        DialogField(
          'volunteers',
          'Manpower (volunteers)',
          initial: none(before('volunteer')),
          options: [for (var i = 0; i <= 20; i++) none(i)],
        ),
        DialogField(
          'pushcarts',
          'Pushcarts',
          initial: none(before('pushcart')),
          options: [for (var i = 0; i <= 10; i++) none(i)],
        ),
      ],
      confirm: again ? 'Ask again' : 'Send request',
    );
    if (v == null || !context.mounted) return;
    int n(String key) => int.tryParse(v[key] ?? '') ?? 0;
    if (n('trucks') + n('volunteers') + n('pushcarts') == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Choose at least one: a truck, volunteers or a pushcart.',
          ),
        ),
      );
      return;
    }
    await act(
      context,
      () => api.post(
        '/logistics/requests',
        body: {
          'delivery_id': d['delivery_id'],
          'trucks': n('trucks'),
          'volunteers': n('volunteers'),
          'pushcarts': n('pushcarts'),
        },
      ),
      success: 'Logistics request sent to DRRMO',
    );
  }

  /// CSWS moves its own delivery one step, after a confirm (Phase 6).
  Future<void> _advance(BuildContext context, Map d, String next) async {
    final v = await formDialog(
      context,
      title: 'Mark delivery #${d['delivery_id']} ${deliveryWord(next)}?',
      message: next == 'In Transit'
          ? 'The barangay and the donors will see it is on the way.'
          : 'The barangay will be asked to confirm receipt.',
      fields: const [],
      confirm: 'Yes, ${deliveryWord(next)}',
    );
    if (v == null || !context.mounted) return;
    final nav = Navigator.of(context, rootNavigator: true);
    ApiResult? result;
    await stepWithUndo(
      context,
      () async =>
          result = await api.post('/deliveries/${d['delivery_id']}/advance'),
      deliveryId: d['delivery_id'] as int,
      success: 'Delivery #${d['delivery_id']} is now ${deliveryWord(next)}',
    );
    // J2 / NF-015: arriving gives CSWS Main Office the handover code, once.
    final body = result?.json;
    final code = body is Map ? body['handover_code'] : null;
    if (code != null && nav.mounted) {
      await showHandoverCode(
        nav.context,
        code: '$code',
        where: '${d['destination_barangay_name'] ?? 'the barangay'}',
      );
    }
  }

  /// Phase 6: CSWS sends several packed deliveries at once. Only deliveries
  /// CSWS sends itself (no DRRMO request open); those due today or earlier
  /// start ticked. Same rules as one by one, all or nothing.
  Widget _batchButton(BuildContext context, List<Map> rows, Map requests) {
    bool open(Map d) {
      final r = requests[d['delivery_id']];
      return r != null &&
          (r['status'] == 'Pending' || r['status'] == 'Accepted');
    }

    final ready = rows
        .where((d) => d['status'] == 'Preparing' && !open(d))
        .toList();
    if (ready.length < 2) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: OutlinedButton.icon(
          onPressed: () => _sendMany(context, ready),
          icon: const Icon(Icons.local_shipping_outlined),
          label: const Text('Mark several as On the way'),
        ),
      ),
    );
  }

  Future<void> _sendMany(BuildContext context, List<Map> ready) async {
    final today = DateTime.now();
    final picked = <int>{
      for (final d in ready)
        if (!(DateTime.tryParse('${d['delivery_date']}')?.toLocal() ?? today)
            .isAfter(DateTime(today.year, today.month, today.day, 23, 59)))
          d['delivery_id'] as int,
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Mark as On the way'),
          content: SizedBox(
            width: 420,
            child: ListView(
              shrinkWrap: true,
              children: [
                const Text(
                  'Tick the deliveries leaving now. If one cannot go yet, '
                  'none are changed and you are told which.',
                ),
                for (final d in ready)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: picked.contains(d['delivery_id']),
                    onChanged: (v) => set(
                      () => v == true
                          ? picked.add(d['delivery_id'] as int)
                          : picked.remove(d['delivery_id']),
                    ),
                    title: Text(
                      '#${d['delivery_id']} to '
                      '${d['destination_barangay_name'] ?? 'barangay'}',
                    ),
                    subtitle: Text(niceWhen(d['delivery_date'])),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: Text('Mark ${picked.length} On the way'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await act(
      context,
      () => api.post(
        '/deliveries/advance-batch',
        body: {'delivery_ids': picked.toList()},
      ),
      success: '${picked.length} deliveries are on the way',
    );
  }

  /// UC-B1, J1 / NF-009 and J2 / NF-015: the rep counts every item that
  /// arrived (the count fields start empty; a difference needs a reason),
  /// types the handover code the staff on site shows, their name and
  /// position, and signs. The form stays open until the server accepts it.
  /// This is also the barangay's acknowledgement of the aid.
  Future<void> _confirmReceipt(BuildContext context, Map d) async {
    final id = d['delivery_id'] as int;
    ApiResult? sent;
    final counted = await showReceiptCountDialog(
      context,
      title: 'Count and confirm receipt',
      message:
          'Count what arrived for delivery #$id and enter the number for '
          'every item. Then enter the handover code the CSWS staff shows '
          'you, your name and position, and sign. Confirming is also your '
          'barangay\'s acknowledgement of the aid.',
      deliveries: [CountTarget.fromDelivery(d)],
      submit: (c) async => sent = await sendWithProof(
        c,
        (proof) => api.post(
          '/deliveries/$id/confirm-receipt',
          body: {...c.deliveryBody(id), ...proof},
        ),
      ),
    );
    if (counted == null || sent == null || !context.mounted) return;
    final done = sent!;
    await act(
      context,
      () async => done,
      success: counted.hasDifference
          ? 'Receipt confirmed with differences. CSWS Main Office was told.'
          : 'Receipt confirmed and aid acknowledged. Fulfillment updated.',
    );
  }

  /// Barangay rep: count every delivery of a trip that arrived here, then
  /// confirm them together with one handover code and one signature for
  /// the stop (J1 / NF-009, J2 / NF-015: all or nothing). [n] is the number
  /// shown on the trip card; the list is loaded fresh.
  Future<void> _confirmTrip(BuildContext context, int tripId, int n) async {
    final r = await api.get(
      '/deliveries/',
      query: {
        'trip_id': '$tripId',
        'status': 'Delivered',
        'limit': '100',
        'offset': '0',
      },
    );
    if (!context.mounted) return;
    if (!r.ok) {
      await act(context, () async => r, success: '');
      return;
    }
    final rows = (r.json as List).cast<Map>();
    if (rows.isEmpty) return;
    ApiResult? sent;
    final counted = await showReceiptCountDialog(
      context,
      title: 'Count trip #$tripId',
      message:
          'Trip #$tripId brought ${rows.length} deliveries to your barangay. '
          'Count every item of each one, then enter the handover code, your '
          'name and position, and sign once for all of them. They are '
          'confirmed together: if one count is not accepted, none is saved.',
      deliveries: [for (final d in rows) CountTarget.fromDelivery(d)],
      submit: (c) async => sent = await sendWithProof(
        c,
        (proof) => api.post(
          '/trips/$tripId/confirm-receipt',
          body: {...c.tripBody(), ...proof},
        ),
      ),
    );
    if (counted == null || sent == null || !context.mounted) return;
    final done = sent!;
    await act(
      context,
      () async => done,
      success: counted.hasDifference
          ? '${rows.length} deliveries confirmed with differences. '
                'CSWS Main Office was told.'
          : '${rows.length} deliveries confirmed and acknowledged. '
                'Fulfillment updated.',
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
    String chip(String? s) => s == null
        ? 'All (${counts['total'] ?? 0})'
        : '${deliveryWord(s)} (${counts[s] ?? 0})';
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
            // J5 / NF-010: short deliveries (CSWS Main Office reviews,
            // the Administrator only reads).
            if (!barangay &&
                (api.role == Roles.cswsMain || api.role == Roles.admin))
              ActionChip(
                avatar: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('Short deliveries'),
                onPressed: () => openShortDeliveries(context),
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
    // NF-003: delivery records (8.5) are paged; the other modes stay as they are.
    if (readOnly) return Scaffold(body: _records(context));
    final pager = _pagerOf(_pageQuery);
    return Scaffold(
      floatingActionButton: barangay
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _prepare(context),
              icon: const Icon(Icons.add),
              label: const Text('Prepare delivery'),
            ),
      body: Loader(
        // Live: a delivery or DRRMO request changed (Realtime).
        refresh: Realtime.instance.logistics,
        load: [
          api.lookupsResult,
          () => api.get('/deliveries/counts'),
          if (barangay) () => api.get('/dashboard/barangay'),
          // Barangay: deliveries waiting for confirmation on every page,
          // so a whole trip can be confirmed in one tap.
          if (barangay)
            () => api.get(
              '/deliveries/',
              query: {'status': 'Delivered', 'limit': '100', 'offset': '0'},
            ),
        ],
        builder: (context, data) {
          final names = Names(Map<String, dynamic>.from(data[0] as Map));
          final counts = data[1] as Map;
          final acked = barangay && data.length > 2
              ? ((data[2] as Map)['acknowledged_deliveries'] as List).toSet()
              : <dynamic>{};
          // Barangay: trips that brought several deliveries that are now
          // waiting for confirmation, so they can confirm them in one tap.
          final waitingByTrip = <int, int>{};
          if (barangay && data.length > 3) {
            for (final d in (data[3] as List).cast<Map>()) {
              if (d['trip_id'] != null && d['status'] == 'Delivered') {
                final id = d['trip_id'] as int;
                waitingByTrip[id] = (waitingByTrip[id] ?? 0) + 1;
              }
            }
            waitingByTrip.removeWhere((_, n) => n < 2);
          }
          final focused = _focused;
          Widget outlined(Map d) => Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            ),
            child: _card(
              context,
              d,
              names,
              acked.contains(d['delivery_id']),
              _requests[d['delivery_id']],
            ),
          );
          return PagedListView(
            controller: pager,
            refresh: Realtime.instance.logistics,
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            header: [
              PageHeader(
                barangay ? 'Incoming Aid' : 'Release & Delivery Tracking',
                subtitle: barangay
                    ? 'Aid for your assigned barangay. Confirm receipt when it '
                          'arrives, then acknowledge it.'
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
              // Phase 6: several deliveries leave together (all or nothing),
              // from the deliveries on this page.
              if (!barangay)
                ListenableBuilder(
                  listenable: pager,
                  builder: (context, _) =>
                      _batchButton(context, pager.items, _requests),
                ),
              // The delivery a notification points at comes first.
              if (focused != null) outlined(focused),
            ],
            empty: focused != null
                ? const SizedBox.shrink()
                : EmptyState(
                    _filtered
                        ? 'No deliveries match these filters.'
                        : barangay
                        ? 'No deliveries to your barangay yet.'
                        : 'No deliveries yet. Tap "Prepare delivery".',
                  ),
            itemBuilder: (context, d) =>
                focused != null && d['delivery_id'] == focused['delivery_id']
                ? const SizedBox.shrink()
                : _card(
                    context,
                    d,
                    names,
                    acked.contains(d['delivery_id']),
                    _requests[d['delivery_id']],
                  ),
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
          // G-002 (D8): plus what the barangay counted (J1), when known.
          (it) => deliveredLine(
            it,
            name:
                '${it['item_name'] ?? names.of('items', it['item_id'], fallback: 'item')}',
          ),
        )
        .toList();
    final reqStage = request?['stage'] as String?;
    // Testing (Oct 27): with a DRRMO request open, DRRMO moves the delivery
    // (In Transit on pickup, Delivered on arrival); CSWS waits.
    final reqOpen =
        request != null &&
        (request['status'] == 'Pending' || request['status'] == 'Accepted') &&
        (status == 'Preparing' || status == 'In Transit');
    final drrmo = api.role == Roles.drrmo;
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
                StatusChip(status, label: deliveryWord(status)),
              ],
            ),
            const SizedBox(height: 6),
            // Testing (Oct 27): the goods stand out, like the donate form.
            if (items.isEmpty) const Text('No items') else NeedChips(items),
            // J1 / NF-009: what the barangay counted differently.
            if (d['has_discrepancy'] == true) ReceiptDifferences(d),
            const SizedBox(height: 6),
            Text(
              '${reportName(d['report_label'] ?? names.of('reports', d['report_id'], fallback: 'Report'))}'
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
                    StatusChip(
                      reqStage ?? 'Pending',
                      label: reqStage == 'In Transit' ? 'On the way' : null,
                    ),
                  ],
                ),
              ),
            // UC-DR1 step 5 / Table 36 alt 4a: when DRRMO comes, and with what.
            if (request != null &&
                request['scheduled_by'] == 'DRRMO' &&
                status == 'Preparing' &&
                (reqStage == 'Accepted' || reqStage == 'Completed'))
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'DRRMO arriving ${niceWhen(request['scheduled_date'])}'
                  '${vehicleAndDriver(request) != null ? '\n${vehicleAndDriver(request)}' : ''}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            // Table 36 alt 3a: why DRRMO said no, so CSWS can decide quickly.
            if (request != null &&
                (reqStage == 'Declined' || reqStage == 'Cancelled') &&
                request['reason'] != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${reqStage == 'Declined' ? 'DRRMO said' : 'Cancelled'}: '
                  '${request['reason']}',
                  style: TextStyle(
                    fontSize: 12,
                    color: reqStage == 'Declined'
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
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
              DeliveryStepper(status, times: d['status_times'] as Map?),
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
                // Testing (Oct 27): finished deliveries can be cleared from
                // the list (kept on record, see DELETE /deliveries/{id}).
                if (!barangay &&
                    !readOnly &&
                    (status == 'Cancelled' || status == 'Confirmed'))
                  TextButton.icon(
                    onPressed: () => _delete(context, d),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                // Unexpected problems: new date, truck came back, cancel,
                // or no longer need DRRMO (delivery_widgets.dart).
                // Team, Nov 4: not while DRRMO has it (the Administrator
                // can still step in).
                if (!barangay &&
                    !readOnly &&
                    (!reqOpen || api.role == Roles.admin) &&
                    (status == 'Preparing' || status == 'In Transit'))
                  TextButton.icon(
                    onPressed: () =>
                        showDeliveryProblems(context, d, request: request),
                    icon: const Icon(Icons.edit_outlined),
                    label: const Text('Edit'),
                  ),
                // Testing feedback (Oct 20): transport is asked for before
                // the truck leaves, so only while Preparing.
                if (!barangay &&
                    !readOnly &&
                    status == 'Preparing' &&
                    (request == null ||
                        reqStage == 'Declined' ||
                        reqStage == 'Cancelled' ||
                        reqStage == 'Completed'))
                  OutlinedButton.icon(
                    onPressed: () => _requestTransport(
                      context,
                      d,
                      previous:
                          reqStage == 'Declined' || reqStage == 'Cancelled'
                          ? request
                          : null,
                    ),
                    icon: const Icon(Icons.fire_truck_outlined),
                    // Table 36 alt 3a: after a decline, ask again in one tap.
                    label: Text(
                      reqStage == 'Declined'
                          ? 'Ask DRRMO again'
                          : 'Request transport',
                    ),
                  ),
                // Advisor (Oct 24) + testing (Oct 27): with a DRRMO request
                // open, DRRMO moves it; CSWS sees who has it.
                if (!barangay && !readOnly && reqOpen)
                  Chip(
                    avatar: const Icon(Icons.fire_truck_outlined, size: 18),
                    label: Text(
                      request['status'] == 'Pending'
                          ? 'With DRRMO · waiting for them to accept'
                          : 'With DRRMO · only DRRMO updates it',
                    ),
                  )
                else if (drrmo && reqOpen && request['status'] == 'Pending')
                  const Chip(
                    avatar: Icon(Icons.info_outline, size: 18),
                    label: Text('Accept the request in Logistics first'),
                  )
                else if (drrmo && reqOpen && request['mine'] != true)
                  Chip(
                    avatar: const Icon(Icons.person_outline, size: 18),
                    label: Text(
                      'Accepted by ${request['assigned_to'] ?? 'a teammate'}',
                    ),
                  )
                else if (drrmo && reqOpen)
                  FilledButton.icon(
                    onPressed: () => moveDrrmoDelivery(context, request),
                    icon: Icon(
                      status == 'Preparing'
                          ? Icons.local_shipping
                          : Icons.where_to_vote_outlined,
                    ),
                    label: Text(
                      status == 'Preparing'
                          ? 'Picked up · mark On the way'
                          : 'Mark Arrived',
                    ),
                  )
                else if (!barangay && !readOnly && next != null)
                  FilledButton.icon(
                    onPressed: () => _advance(context, d, next),
                    icon: const Icon(Icons.arrow_forward),
                    label: Text('Mark ${deliveryWord(next)}'),
                  ),
                // J2 / NF-015: a new handover code for the staff on site
                // (CSWS Main Office, or the DRRMO user who carried it).
                if (status == 'Delivered' &&
                    (api.role == Roles.cswsMain ||
                        (drrmo && request != null && request['mine'] == true)))
                  OutlinedButton.icon(
                    onPressed: () => newHandoverCode(
                      context,
                      d['delivery_id'] as int,
                      where: '$barangayName',
                    ),
                    icon: const Icon(Icons.pin_outlined),
                    label: const Text('Handover code'),
                  ),
                // J2 / NF-015: the Acknowledgment Receipt once confirmed.
                if (status == 'Confirmed' &&
                    (barangay ||
                        api.role == Roles.cswsMain ||
                        api.role == Roles.admin))
                  TextButton.icon(
                    onPressed: () =>
                        openAcknowledgment(context, d['delivery_id'] as int),
                    icon: const Icon(Icons.receipt_long_outlined),
                    label: const Text('View receipt'),
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
  /// Phase 6: opened from a report ("Prepare delivery"), that report is
  /// already chosen, with its barangay and the goods ready for it.
  final int? reportId;
  const NewDeliveryScreen({super.key, this.reportId});

  @override
  State<NewDeliveryScreen> createState() => _NewDeliveryScreenState();
}

class _NewDeliveryScreenState extends State<NewDeliveryScreen> {
  final _form = GlobalKey<FormState>();
  late Future<List<ApiResult>> _load = _fetch();
  Map? report; // row from /trips/candidates (with its items)
  String? brgyId; // destination; defaults to the report's barangay
  bool changeBrgy = false;
  bool _preset = false; // widget.reportId was applied

  /// "Needs DRRMO transport?" (UC-CM2 alt 3a): asked in the same save.
  bool transport = false;
  int trucks = 1, volunteers = 0, pushcarts = 0;

  /// What the report still needs, per item (GET /reports/{id}/needs).
  List<Map>? stillNeeded;

  Future<void> _loadNeeds(int reportId) async {
    final r = await api.get('/reports/$reportId/needs');
    if (!mounted || !r.ok || r.json is! Map) return;
    setState(() {
      stillNeeded = [
        for (final n in ((r.json as Map)['needs'] as List? ?? const []))
          if (((n as Map)['needed'] as num? ?? 0) >
              (n['delivered'] as num? ?? 0))
            n,
      ];
    });
  }

  void _pick(Map r) {
    report = r;
    brgyId = '${r['barangay_id']}';
    changeBrgy = false;
    chosen = null;
    stillNeeded = null;
    _loadNeeds(r['report_id'] as int);
  }

  /// Oct 15: the ticked donation entries (each goes whole); null = loading.
  Set<String>? chosen;
  int get ready => chosen?.length ?? 0;
  String? date; // ISO, UTC
  bool tried = false;
  bool busy = false;

  Future<List<ApiResult>> _fetch() =>
      Future.wait([api.get('/trips/candidates'), api.lookupsResult()]);

  Future<void> _chooseReport(Map candidates) async {
    final r = await pickReportWithStock(context, candidates);
    if (r == null || !mounted) return;
    setState(() => _pick(r));
  }

  Future<void> _submit() async {
    setState(() => tried = true);
    if (report == null) return;
    if (!_form.currentState!.validate()) return;
    if (ready == 0 || date == null) return;
    if (transport && trucks + volunteers + pushcarts == 0) return;
    setState(() => busy = true);
    final r = await act(
      context,
      () => api.post(
        '/deliveries/',
        body: {
          'report_id': report!['report_id'],
          'destination_barangay_id': int.parse(brgyId!),
          'delivery_date': date,
          // Oct 15: the ticked donation entries, each one whole.
          'batch_references': chosen!.toList(),
          if (transport)
            'transport': {
              'trucks': trucks,
              'volunteers': volunteers,
              'pushcarts': pushcarts,
            },
        },
      ),
      success: transport
          ? 'Delivery prepared and DRRMO asked for transport'
          : 'Delivery prepared',
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
          if (widget.reportId != null && !_preset) {
            // Opened from a report: choose it (if it has goods ready).
            _preset = true;
            final hit = [
              for (final g in (candidates['barangays'] as List).cast<Map>())
                ...(g['reports'] as List).cast<Map>(),
            ].where((r) => r['report_id'] == widget.reportId);
            if (hit.isNotEmpty) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() => _pick(hit.first));
              });
            }
          }
          final noReports =
              (candidates['barangays'] as List).isEmpty &&
              ((candidates['not_acknowledged_reports'] as List?) ?? const [])
                  .isEmpty;

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
                  // Phase 6: what the report still needs, to choose by.
                  if (stillNeeded != null && stillNeeded!.isNotEmpty) ...[
                    Text('Still needed for this report', style: t.titleSmall),
                    Gaps.v4,
                    NeedChips([
                      for (final n in stillNeeded!)
                        '${(n['needed'] as num) - ((n['delivered'] as num?) ?? 0)} '
                                '${n['unit'] ?? ''} ${n['item_name'] ?? ''}'
                            .replaceAll(RegExp(r'\s+'), ' ')
                            .trim(),
                    ]),
                    Gaps.v12,
                  ],
                  ReadyDonations(
                    key: ValueKey('ready-${report!['report_id']}'),
                    reportId: report!['report_id'] as int,
                    onChanged: (refs) {
                      if (mounted) setState(() => chosen = refs);
                    },
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
                  // 4. Transport (UC-CM2 alt 3a), asked in the same save.
                  Gaps.v16,
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: transport,
                    onChanged: (v) => setState(() => transport = v),
                    title: const Text('Needs DRRMO transport?'),
                    subtitle: const Text(
                      'DRRMO is asked for this date and picks up the goods.',
                    ),
                  ),
                  if (transport) ...[
                    Row(
                      children: [
                        for (final (label, value, max, set)
                            in <(String, int, int, void Function(int))>[
                              ('Trucks', trucks, 10, (v) => trucks = v),
                              (
                                'Volunteers',
                                volunteers,
                                20,
                                (v) => volunteers = v,
                              ),
                              (
                                'Pushcarts',
                                pushcarts,
                                10,
                                (v) => pushcarts = v,
                              ),
                            ])
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: DropdownButtonFormField<int>(
                                initialValue: value,
                                decoration: InputDecoration(labelText: label),
                                items: [
                                  for (var i = 0; i <= max; i++)
                                    DropdownMenuItem(
                                      value: i,
                                      child: Text(i == 0 ? 'None' : '$i'),
                                    ),
                                ],
                                onChanged: (v) => setState(() => set(v ?? 0)),
                              ),
                            ),
                          ),
                      ],
                    ),
                    if (tried && trucks + volunteers + pushcarts == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Choose at least one: a truck, volunteers or a pushcart.',
                          style: TextStyle(color: cs.error),
                        ),
                      ),
                  ],
                  Gaps.v24,
                  if (ready > 0)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Sending $ready '
                        '${ready == 1 ? 'donation' : 'donations'}'
                        '${date == null ? '' : ' on ${niceWhen(date)}'}.',
                        style: t.bodyMedium,
                      ),
                    ),
                  FilledButton.icon(
                    onPressed: busy || ready == 0 ? null : _submit,
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
// UC-C1 / UC-C2 City donation acknowledgement (CMO Representative).
// Oct 11 notes (Dave): the word is "Acknowledge", and the CMO decides per
// donation entry (one QR, all its items), not per item. The donor's status
// becomes "Acknowledged by CMO" by itself.
// ---------------------------------------------------------------------------
/// problema_napud 4.1: a CMO notification ("Donation ... was received by
/// CSWS") opens the whole entry in a pop-out with only Acknowledge and
/// Close. Acknowledging refreshes the Acknowledge tab underneath.
Future<void> showCmoEntryPopout(BuildContext context, int donationId) async {
  final r = await api.get('/cmo/entries/by-donation/$donationId');
  if (!context.mounted) return;
  if (!r.ok || r.json is! Map) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r.status == 404
              ? 'This donation is not waiting for the CMO.'
              : 'Could not open this donation. Check your connection.',
        ),
      ),
    );
    return;
  }
  final e = Map<String, dynamic>.from(r.json as Map);
  final done = e['acknowledged'] == true;
  var busy = false; // set while Acknowledge is being sent
  await showDetailPopout<void>(
    context,
    title: 'Donation entry',
    child: CmoEntryDetails(e),
    actions: [
      Builder(
        builder: (ctx) => AppButton(
          'Close',
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: () => Navigator.of(ctx).pop(),
        ),
      ),
      if (!done)
        // Disabled while it is sent, so a double tap never acknowledges twice.
        StatefulBuilder(
          builder: (ctx, setBusy) {
            return AppButton(
              'Acknowledge',
              icon: Icons.verified,
              expand: true,
              loading: busy,
              onPressed: () async {
                if (busy) return;
                setBusy(() => busy = true);
                final res = await act(
                  ctx,
                  () => api.post(
                    '/cmo/entries/${Uri.encodeComponent('${e['batch_reference']}')}/decide',
                    body: {'status': 'Acknowledged', 'notes': null},
                  ),
                  success: '${e['batch_reference']} acknowledged',
                );
                if (!ctx.mounted) return;
                if (!res.ok) {
                  setBusy(() => busy = false);
                  return;
                }
                Navigator.of(ctx).pop();
                HomeNav.go(
                  context,
                  const HomeTarget('Acknowledge', view: 'pending'),
                );
              },
            );
          },
        ),
    ],
  );
}

/// Everything about one donation entry the CMO acknowledges: reference,
/// status, report, handover, each item and the estimated value.
class CmoEntryDetails extends StatelessWidget {
  final Map e;
  const CmoEntryDetails(this.e, {super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final done = e['acknowledged'] == true;
    final items = ((e['items'] as List?) ?? const []).cast<Map>();
    final value = (e['estimated_value'] as num?) ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.qr_code_2, color: cs.primary),
            Gaps.h8,
            Expanded(
              child: Text(
                '${e['batch_reference']}',
                style: t.titleMedium?.copyWith(fontFamily: 'monospace'),
              ),
            ),
            if (done)
              const StatusChip('Confirmed', label: 'Acknowledged')
            else
              StatusChip(
                e['cmo_decision'] as String? ?? 'Received',
                label: e['cmo_decision'] == null
                    ? 'Waiting'
                    : '${e['cmo_decision']}',
              ),
          ],
        ),
        Gaps.v8,
        // The report by disaster and barangay, without its number (Oct 23).
        Text(
          'For ${'${e['report_label'] ?? 'report'}'.replaceFirst(RegExp(r'^#\d+\s*'), '').replaceAll(' - ', ' · ')}',
        ),
        Text(
          'Handover: ${e['handover_method'] ?? '-'} · Received by CSWS',
          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SectionTitle('Items'),
        for (final i in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 16,
                  color: cs.onSurfaceVariant,
                ),
                Gaps.h8,
                Expanded(
                  // G-002 (D8): readable amount, packaging, quantities.
                  child: Text(
                    '${i['item_name']} · ${itemAmount(i)}\n${itemQuantities(i)}',
                  ),
                ),
              ],
            ),
          ),
        Gaps.v8,
        Text(
          '${e['total_items']} item(s) · ${e['total_quantity']} in all'
          '${value > 0 ? ' · Estimated value ${pesos(value)}' : ''}',
          style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        if (e['hold_reason'] != null && !done) ...[
          Gaps.v8,
          Text(
            'On hold: ${e['hold_reason']}',
            style: t.bodyMedium?.copyWith(color: AppColors.danger),
          ),
        ],
        if (done) ...[
          Gaps.v8,
          Text('Already acknowledged.', style: t.bodySmall),
        ],
      ],
    );
  }
}

/// Phase 7: a delivery step, then a success message with "Undo" (the
/// server allows it for 10 minutes, to the same person, never after the
/// barangay confirmed). Uses the navigator's context, which outlives the
/// card that is rebuilt when the list reloads.
Future<void> stepWithUndo(
  BuildContext context,
  Future<ApiResult> Function() call, {
  required int deliveryId,
  required String success,
}) async {
  // The overlay is looked up now: the card that was tapped may be rebuilt
  // away when the list reloads. (Before Nov 4 it used the navigator's own
  // context, which sits above the overlay, so no message ever showed and a
  // refused step looked like a dead button.)
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  String why(ApiResult r) =>
      r.status == 0 ? 'Cannot reach the server' : r.errorText;
  final r = await call();
  if (overlay == null || !overlay.mounted) return;
  if (!r.ok) {
    AppToast.showOn(overlay, why(r), kind: ToastKind.error);
    return;
  }
  AppToast.showOn(
    overlay,
    success,
    kind: ToastKind.success,
    duration: const Duration(seconds: 10),
    action: ToastAction('Undo', () async {
      final u = await api.post('/deliveries/$deliveryId/undo');
      if (!overlay.mounted) return;
      AppToast.showOn(
        overlay,
        u.ok ? 'Last step undone' : why(u),
        kind: u.ok ? ToastKind.success : ToastKind.error,
      );
    }),
  );
}

/// Table 36 / 37: DRRMO's next step for the delivery it carries, after a
/// confirm ("Picked up" -> On the way, "Arrived" -> completes the request).
/// [r] is a request row from GET /drrmo/requests.
Future<void> moveDrrmoDelivery(BuildContext context, Map r) async {
  final pickup = r['delivery_status'] == 'Preparing';
  final v = await formDialog(
    context,
    title: pickup
        ? 'Picked up delivery #${r['delivery_id']}?'
        : 'Arrived at ${r['destination'] ?? 'the barangay'}?',
    message: pickup
        ? 'CSWS and the barangay will see it is on the way.'
        : 'CSWS and the barangay will see it arrived, and this request is '
              'completed. The barangay then confirms receipt.',
    fields: const [],
    confirm: pickup ? 'Yes, on the way' : 'Yes, it arrived',
  );
  if (v == null || !context.mounted) return;
  final nav = Navigator.of(context, rootNavigator: true);
  ApiResult? result;
  await stepWithUndo(
    context,
    () async => result = await api.post(
      '/drrmo/requests/${r['request_id']}/${pickup ? 'picked-up' : 'delivered'}',
    ),
    deliveryId: r['delivery_id'] as int,
    success: pickup
        ? 'Delivery #${r['delivery_id']} is on the way'
        : 'Delivery #${r['delivery_id']} arrived. Request completed.',
  );
  // J2 / NF-015: the DRRMO user who carried it gets a handover code to show
  // the barangay representative.
  if (!pickup && result?.ok == true && nav.mounted) {
    await newHandoverCode(
      nav.context,
      r['delivery_id'] as int,
      where: '${r['destination'] ?? 'the barangay'}',
      ask: false,
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

class _DrrmoScreenState extends State<DrrmoScreen>
    with HomeTargetListener<DrrmoScreen> {
  String stage = 'Pending';

  @override
  String get homeTab => 'Logistics';

  /// The request a notification is about (testing, Oct 27): its list opens
  /// at the stage it is in now, with that request first and outlined.
  int? _focus;
  bool _focusPlaced = false;
  int _loads = 0; // a new notice reloads the list, so a new request is in it
  String _q = ''; // search box

  // Testing (Nov 3): the dashboard sits above the request list, so a tile
  // or a "Needs your action" line only changed the list off screen and
  // looked dead. Now the list scrolls into view after such a tap.
  final _scroll = ScrollController();
  final _dashboard = GlobalKey(); // everything above the stage chips
  bool _scrollToList = false;

  @override
  void applyHomeTarget(HomeTarget target) {
    if (target.view != null) stage = target.view!;
    _focus = target.id;
    _focusPlaced = false;
    _loads++;
    _scrollToList = target.id != null || target.view != null;
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadFocus());
  }

  /// Show the requests at [s] (a stat tile, a "Needs your action" line, or
  /// after accepting), with [focus] first and outlined, and scroll to them.
  void _show(String s, {int? focus}) {
    setState(() {
      stage = s;
      _focus = focus;
      _focusPlaced = true;
      _scrollToList = true;
    });
    _loadFocus();
  }

  /// NF-003: the focused request on its own (it may be on a later page of
  /// its stage), loaded again after any change so its buttons stay right.
  Map? _focused;

  Future<void> _loadFocus() async {
    final id = _focus;
    if (id == null) {
      if (_focused != null && mounted) setState(() => _focused = null);
      return;
    }
    final r = await api.get('/drrmo/requests', query: {'request_id': '$id'});
    if (!mounted || _focus != id || !r.ok || r.json is! List) return;
    final hit = (r.json as List).cast<Map>().where(
      (x) => x['request_id'] == id,
    );
    setState(() {
      _focused = hit.isEmpty ? null : hit.first;
      // The request may have moved on since the notice (e.g. accepted).
      if (!_focusPlaced && _focused != null) stage = '${_focused!['stage']}';
      _focusPlaced = true;
    });
  }

  void _refreshFocus() {
    if (_focus != null) _loadFocus();
  }

  @override
  void initState() {
    super.initState();
    api.addListener(_refreshFocus);
    Realtime.instance.logistics.addListener(_refreshFocus);
  }

  /// Bring the stage chips to the top of the screen (or as far as the
  /// list allows), once the list for the new stage is built.
  void _revealList() {
    _scrollToList = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _dashboard.currentContext;
      final box = ctx?.findRenderObject() as RenderBox?;
      if (!mounted || ctx == null || box == null || !_scroll.hasClients) {
        return;
      }
      final view = Scrollable.of(ctx).context.findRenderObject() as RenderBox;
      // Where the dashboard ends, measured from the top of the list.
      final end = box
          .localToGlobal(Offset(0, box.size.height), ancestor: view)
          .dy;
      final p = _scroll.position;
      final target = (p.pixels + end).clamp(0.0, p.maxScrollExtent);
      if (MediaQuery.disableAnimationsOf(context)) {
        _scroll.jumpTo(target);
      } else {
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _accept(Map r) async {
    // UC-DR1 step 5: a delivery request is accepted with DRRMO's time.
    if (r['request_type'] != 'Pickup') {
      final body = await showAcceptDeliveryDialog(context, r);
      if (body == null || !mounted) return;
      final res = await act(
        context,
        () =>
            api.patch('/drrmo/requests/${r['request_id']}/accept', body: body),
        success: 'Accepted. CSWS was told when DRRMO comes.',
      );
      // The request moves to Accepted: follow it there.
      if (res.ok && mounted) _show('Accepted', focus: r['request_id'] as int?);
      return;
    }
    final v = await formDialog(
      context,
      title: 'Accept request #${r['request_id']}?',
      message:
          '${r['needs'] ?? r['notes'] ?? 'No details'}\n'
          '${r['request_type'] == 'Pickup' ? 'Pickup run on ${pickupDay(r['pickup_date'])}: ${r['destination'] ?? '-'}' : 'Destination: ${r['destination'] ?? '-'}'}\n'
          // Testing fix 7.4: CSWS Main Office already set the date.
          '${r['request_type'] != 'Pickup' && r['scheduled_date'] != null ? 'Scheduled by CSWS Main Office: ${niceDate(r['scheduled_date'])}\n' : ''}'
          'Requested ${requestWhen(r['created_at'])}',
      fields: const [],
      confirm: 'Accept',
    );
    if (v == null || !mounted) return;
    final res = await act(
      context,
      () => api.patch('/drrmo/requests/${r['request_id']}/accept'),
      success: 'Request accepted',
    );
    if (res.ok && mounted) _show('Accepted', focus: r['request_id'] as int?);
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

  /// Team, Nov 4: DRRMO manages the delivery it carries, so DRRMO (not
  /// CSWS) moves the pickup time. CSWS, the barangay and donors are told.
  Future<void> _changeTime(Map r) async {
    final when = await pickDeliveryDateTime(
      context,
      current: '${r['scheduled_date'] ?? ''}',
      help: 'When will DRRMO pick up the goods?',
    );
    if (when == null || !mounted) return;
    await act(
      context,
      () => api.post(
        '/deliveries/${r['delivery_id']}/reschedule',
        body: {'delivery_date': when, 'reason': 'New pickup time from DRRMO'},
      ),
      success: 'Pickup moved to ${niceWhen(when)}. CSWS was told.',
    );
  }

  /// The truck came back with the goods: the delivery is Being packed
  /// again and DRRMO picks it up later (or says it can no longer do it).
  Future<void> _cameBack(Map r) async {
    final why = await askReason(
      context,
      title: 'Truck came back',
      message:
          'Delivery #${r['delivery_id']} goes back to "Being packed". '
          'You pick it up again later. Why?',
      choices: const [
        'The truck broke down',
        'The road is closed or unsafe',
        'Nobody was there to receive it',
        'Bad weather',
      ],
      confirm: 'Bring it back',
    );
    if (why == null || !mounted) return;
    await act(
      context,
      () => api.post(
        '/deliveries/${r['delivery_id']}/return-to-office',
        body: {'reason': why},
      ),
      success: 'Delivery #${r['delivery_id']} is back. CSWS was told.',
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

  // NF-003: the requests of the chosen stage (and search), a page at a time
  // from the server. A new stage, search or notice starts again from page 1.
  PagedController? _list;
  String? _listFor;
  Timer? _typing;
  String _query = ''; // the search the list was loaded for (_q is typed)

  PagedController _listOf(String stage) {
    final key = '$stage-$_loads-$_query';
    if (_list == null || _listFor != key) {
      final old = _list;
      final q = _query;
      _list = PagedController(
        fetch: (offset, limit) => api.get(
          '/drrmo/requests',
          query: {
            'stage': stage,
            if (q.isNotEmpty) 'q': q,
            'limit': '$limit',
            'offset': '$offset',
          },
        ),
      );
      _listFor = key;
      if (old != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
      }
    }
    return _list!;
  }

  /// Phase 6 search, sent once typing stops (barangay, report, or request /
  /// delivery number).
  void _search(String v) {
    _q = v;
    _typing?.cancel();
    _typing = Timer(searchDebounce, () {
      if (mounted && v.trim() != _query) setState(() => _query = v.trim());
    });
  }

  @override
  void dispose() {
    api.removeListener(_refreshFocus);
    Realtime.instance.logistics.removeListener(_refreshFocus);
    _typing?.cancel();
    _scroll.dispose();
    _list?.dispose();
    super.dispose();
  }

  Widget _row(BuildContext context, Map r) {
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      key: ValueKey('request-${r['request_id']}'),
      duration: const Duration(milliseconds: 250),
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: r['request_id'] == _focus ? cs.primary : Colors.transparent,
          width: 2,
        ),
      ),
      child: LogisticsRequestCard(
        r,
        // The delivery's timeline (who did each step, when).
        onTap: r['delivery_id'] is int
            ? () => showDeliveryHistory(context, r['delivery_id'] as int)
            : null,
        actions: _actionsFor(r),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey('drrmo-$_loads'),
      refresh: Realtime.instance.logistics, // live: new or changed requests
      load: [
        () => api.get('/drrmo/dashboard'),
        // NF-003: the stage chips are counted on the server.
        () => api.get('/drrmo/requests/counts'),
        // Testing #19: deliveries that have not arrived yet.
        () => api.get('/deliveries/', query: scheduledDeliveriesQuery),
      ],
      builder: (context, data) {
        final dash = data[0] as Map;
        final counts = data[1] as Map;
        final scheduled = (data[2] as List).cast<Map>();
        // The request a notification or tile is about, first in its stage.
        final focused = _focus == null ? null : _focused;
        if (_scrollToList) _revealList();
        final showFocused =
            focused != null && focused['stage'] == stage && _query.isEmpty;
        const stages = {
          'Pending': 'New',
          'Accepted': 'Accepted',
          'In Transit': 'On the way',
          'Completed': 'Completed',
          'Declined': 'Declined',
          'Cancelled': 'Cancelled by CSWS',
        };
        StatTile tile(
          String label,
          Object? value,
          IconData icon,
          String to, {
          Color? color,
        }) => StatTile(
          label,
          '${value ?? 0}',
          icon,
          color: color,
          // Concerns Nov 4: a card with nothing in it is never tinted, so
          // the dashboard does not turn orange when there are no requests.
          selected: stage == to && (num.tryParse('${value ?? 0}') ?? 0) > 0,
          note: stage == to ? 'Showing below' : 'Tap to view',
          onTap: () => _show(to),
        );
        final cs = Theme.of(context).colorScheme;
        final list = _listOf(stage);
        return PagedListView(
          controller: list,
          scrollController: _scroll,
          refresh: Realtime.instance.logistics,
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            Space.md,
            Space.md,
            Space.xl,
          ),
          header: [
            Column(
              key: _dashboard,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PageHeader('DRRMO Logistics Support', subtitle: roleLine()),
                // Defense concerns (Nov 24): no response times for any role.
                // 9.6 (testing): each card shows its requests below.
                StatGrid([
                  tile(
                    'New requests',
                    dash['pending_requests'],
                    Icons.mark_email_unread_outlined,
                    'Pending',
                    color: const Color(0xFFEF6C00),
                  ),
                  tile(
                    'Accepted',
                    dash['scheduled'],
                    Icons.event_available,
                    'Accepted',
                  ),
                  tile(
                    'On the way',
                    dash['in_transit'],
                    Icons.local_shipping_outlined,
                    'In Transit',
                    color: const Color(0xFF1565C0),
                  ),
                  tile(
                    'Completed',
                    dash['completed'],
                    Icons.done_all,
                    'Completed',
                    color: const Color(0xFF2E7D32),
                  ),
                ]),
                ScheduledDeliveriesCard(
                  deliveries: scheduled,
                  onOpen: (d) =>
                      showDeliveryHistory(context, d['delivery_id'] as int),
                ),
                const SectionTitle('Logistics requests'),
              ],
            ),
          ],
          // The stage chips stay at the top while the list scrolls.
          pinned: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Row(
              children: [
                for (final e in stages.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('${e.value} (${counts[e.key] ?? 0})'),
                      selected: stage == e.key,
                      onSelected: (_) => setState(() => stage = e.key),
                    ),
                  ),
              ],
            ),
          ),
          subheader: [
            TextFormField(
              initialValue: _q,
              textInputAction: TextInputAction.search,
              decoration: const InputDecoration(
                labelText: 'Search barangay, report or request no.',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: _search,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
              child: ListenableBuilder(
                listenable: list,
                builder: (context, _) {
                  final n = list.total ?? list.items.length;
                  return Text(
                    '${stages[stage] ?? stage}: $n '
                    'request${n == 1 ? '' : 's'}',
                    style: Theme.of(context).textTheme.labelLarge
                        ?.copyWith(color: cs.onSurfaceVariant),
                  );
                },
              ),
            ),
            if (showFocused) _row(context, focused),
          ],
          empty: showFocused
              ? const SizedBox.shrink()
              : const EmptyState('No requests here.'),
          // The focused request is already on top.
          itemBuilder: (context, r) => r['request_id'] == _focus && showFocused
              ? const SizedBox.shrink()
              : _row(context, r),
        );
      },
    );
  }

  /// The buttons a request card shows (Phase 6: the next allowed action).
  List<Widget> _actionsFor(Map r) => [
    if (r['stage'] == 'Pending') ...[
      OutlinedButton(
        onPressed: () => _decline(r),
        child: const Text('Decline'),
      ),
      FilledButton.icon(
        onPressed: () => _accept(r),
        icon: const Icon(Icons.check),
        label: const Text('Accept'),
      ),
    ],
    if (r['stage'] == 'Accepted')
      TextButton(
        onPressed: () => _withdraw(r),
        child: const Text('Can no longer do this'),
      ),

    // Table 36 / 37: only the DRRMO user who accepted it moves the
    // delivery; teammates see who has it.
    if (r['request_type'] != 'Pickup' &&
        (r['stage'] == 'Accepted' || r['stage'] == 'In Transit') &&
        r['mine'] != true)
      Chip(
        avatar: const Icon(Icons.person_outline, size: 18),
        label: Text('Accepted by ${r['assigned_to'] ?? 'a teammate'}'),
      ),
    // Team, Nov 4: the delivery is DRRMO's now, so DRRMO changes the
    // pickup time and brings it back if the truck returns (not CSWS).
    if (r['stage'] == 'Accepted' &&
        r['request_type'] != 'Pickup' &&
        r['delivery_status'] == 'Preparing' &&
        r['mine'] == true)
      TextButton.icon(
        onPressed: () => _changeTime(r),
        icon: const Icon(Icons.event_repeat),
        label: const Text('Change time'),
      ),
    if (r['stage'] == 'In Transit' &&
        r['request_type'] != 'Pickup' &&
        r['delivery_status'] == 'In Transit' &&
        r['mine'] == true)
      TextButton.icon(
        onPressed: () => _cameBack(r),
        icon: const Icon(Icons.u_turn_left),
        label: const Text('Truck came back'),
      ),
    // Advisor (Oct 24): DRRMO picked the goods up from CSWS.
    if (r['stage'] == 'Accepted' &&
        r['request_type'] != 'Pickup' &&
        r['delivery_status'] == 'Preparing' &&
        r['mine'] == true)
      FilledButton.icon(
        onPressed: () => moveDrrmoDelivery(context, r),
        icon: const Icon(Icons.local_shipping),
        label: const Text('Picked up · mark On the way'),
      ),
    // Testing (Oct 27): DRRMO carried it, so DRRMO marks it Arrived at
    // the barangay; that completes the request.
    if (r['stage'] == 'In Transit' &&
        r['request_type'] != 'Pickup' &&
        r['delivery_status'] == 'In Transit' &&
        r['mine'] == true)
      FilledButton.icon(
        onPressed: () => moveDrrmoDelivery(context, r),
        icon: const Icon(Icons.where_to_vote_outlined),
        label: const Text('Mark Arrived'),
      ),
    // Pickup runs (and requests accepted before Nov 2026) are still
    // completed by hand, once allowed (7.5).
    if (r['can_complete'] == true)
      FilledButton.icon(
        onPressed: () => _complete(r),
        icon: const Icon(Icons.done_all),
        label: const Text('Mark completed'),
      ),
  ];
}
