import 'package:flutter/material.dart';

import '../api.dart' show Roles;
import 'records_screens.dart' show SupportRecordsScreen;
import 'widgets.dart';
import 'donation_entries_view.dart' show EntrySummaryList;

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
class DeliveriesScreen extends StatelessWidget {
  final bool barangay;

  /// Appendix H 8.5 View delivery records only (Administrator, DRRMO).
  final bool readOnly;
  const DeliveriesScreen({
    super.key,
    this.barangay = false,
    this.readOnly = false,
  });

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: barangay || readOnly
          ? null
          : FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NewDeliveryScreen()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Prepare delivery'),
            ),
      body: Loader(
        load: [
          () => api.get('/deliveries/'),
          api.lookupsResult,
          barangay
              ? () => api.get('/dashboard/barangay')
              : api.role == Roles.drrmo
              ? () => api.get('/drrmo/requests')
              : () => api.get('/logistics/requests'),
        ],
        builder: (context, data) {
          final names = Names(Map<String, dynamic>.from(data[1] as Map));
          final rows = (data[0] as List).cast<Map>();
          final acked = barangay
              ? ((data[2] as Map)['acknowledged_deliveries'] as List).toSet()
              : <dynamic>{};
          final requests = <dynamic, Map>{};
          if (!barangay) {
            for (final r in (data[2] as List).cast<Map>().reversed) {
              requests[r['delivery_id']] = r; // latest request per delivery
            }
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
              if (!barangay && !readOnly)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
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
                ),
              if (rows.isEmpty)
                EmptyState(
                  barangay
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
              '${it['quantity']} × ${names.of('items', it['item_id'], fallback: 'item')}',
        )
        .join(', ');
    final reqStage = request?['stage'] as String?;
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
                    'Delivery #${d['delivery_id']} to '
                    '${names.of('barangays', d['destination_barangay_id'])}',
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
              '${names.of('reports', d['report_id'], fallback: 'Report #${d['report_id']}')}'
              ' · ${niceDate(d['delivery_date'])}',
              style: Theme.of(context).textTheme.bodySmall,
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
            const SizedBox(height: 12),
            DeliveryStepper(status),
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
                if (!barangay &&
                    !readOnly &&
                    (status == 'Preparing' || status == 'In Transit') &&
                    (request == null ||
                        reqStage == 'Declined' ||
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

/// Prepare goods for release from a validated report's inventory.
class NewDeliveryScreen extends StatefulWidget {
  const NewDeliveryScreen({super.key});

  @override
  State<NewDeliveryScreen> createState() => _NewDeliveryScreenState();
}

/// One item line of a delivery: an item from the report's stock + quantity.
class _DeliveryLine {
  String? itemId;
  final qty = TextEditingController();
}

class _NewDeliveryScreenState extends State<NewDeliveryScreen> {
  final _form = GlobalKey<FormState>();
  String? reportId, brgyId;
  List<Map> stock = const [];
  bool loadingStock = false;
  // 5.1.4: several item lines, each any item with stock in this report.
  final List<_DeliveryLine> lines = [_DeliveryLine()];
  String? date;
  bool busy = false;

  @override
  void dispose() {
    for (final l in lines) {
      l.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _loadStock(String? rid, Names names) async {
    setState(() {
      reportId = rid;
      for (final l in lines) {
        l.itemId = null;
      }
      stock = const [];
      loadingStock = true;
      // The report's own barangay is the usual destination.
      for (final r in names.rows('validated_reports')) {
        if ('${r['id']}' == rid) brgyId = '${r['barangay_id']}';
      }
    });
    final r = await api.get(
      '/donations/inventory',
      query: {'report_id': rid ?? ''},
    );
    if (!mounted) return;
    setState(() {
      loadingStock = false;
      stock = r.ok
          ? (r.json as List)
                .cast<Map>()
                .where((i) => i['quantity'] > 0)
                .toList()
          : const [];
    });
  }

  Map? _stockOf(String? itemId) {
    for (final s in stock) {
      if ('${s['item_id']}' == itemId) return s;
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (date == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Pick a delivery date')));
      return;
    }
    setState(() => busy = true);
    final r = await act(
      context,
      () => api.post(
        '/deliveries/',
        body: {
          'report_id': int.parse(reportId!),
          'destination_barangay_id': int.parse(brgyId!),
          'delivery_date': date,
          'items': [
            for (final l in lines)
              {
                'item_id': int.parse(l.itemId!),
                'quantity': int.parse(l.qty.text.trim()),
              },
          ],
        },
      ),
      success: 'Delivery prepared',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) Navigator.pop(context);
  }

  Widget _lineFields(int i) {
    final line = lines[i];
    final chosen = _stockOf(line.itemId);
    // An item already picked on another line is not offered again.
    final taken = {
      for (final l in lines)
        if (l != line && l.itemId != null) l.itemId,
    };
    return Padding(
      key: ObjectKey(line),
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              key: ValueKey(
                'stock-$reportId-${stock.length}-$i-${lines.length}',
              ),
              initialValue: line.itemId,
              isExpanded: true,
              items: [
                for (final s in stock)
                  if (!taken.contains('${s['item_id']}'))
                    DropdownMenuItem(
                      value: '${s['item_id']}',
                      child: Text(
                        '${s['item_name']} (${s['quantity']} ${s['unit'] ?? ''} available)',
                      ),
                    ),
              ],
              onChanged: (v) => setState(() => line.itemId = v),
              validator: (v) => v == null ? 'Choose an item' : null,
              decoration: InputDecoration(
                labelText: i == 0
                    ? 'Item from this report\'s inventory'
                    : 'Item ${i + 1}',
                helperText:
                    i == 0 && reportId != null && !loadingStock && stock.isEmpty
                    ? 'No stock for this report yet. Receive donations first.'
                    : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: line.qty,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Quantity',
                suffixText: chosen?['unit'] as String?,
              ),
              validator: (v) {
                final n = int.tryParse(v?.trim() ?? '') ?? 0;
                if (n <= 0) return 'Enter a number above 0';
                if (chosen != null && n > (chosen['quantity'] as num)) {
                  return 'Only ${chosen['quantity']} available';
                }
                return null;
              },
            ),
          ),
          if (lines.length > 1)
            IconButton(
              tooltip: 'Remove item',
              onPressed: () => setState(() {
                lines.removeAt(i).qty.dispose();
              }),
              icon: const Icon(Icons.remove_circle_outline),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Prepare delivery')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: api.lookups(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final names = Names(snap.data!);
          return Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                LookupDropdown(
                  list: 'validated_reports',
                  label: 'For which validated report?',
                  value: reportId,
                  names: names,
                  onChanged: (v) => _loadStock(v, names),
                ),
                const SizedBox(height: 12),
                LookupDropdown(
                  key: ValueKey('brgy-$brgyId'),
                  list: 'barangays',
                  label: 'Destination barangay',
                  value: brgyId,
                  names: names,
                  onChanged: (v) => setState(() => brgyId = v),
                ),
                const SizedBox(height: 12),
                if (loadingStock) const LinearProgressIndicator(),
                for (var i = 0; i < lines.length; i++) _lineFields(i),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: reportId == null || lines.length >= stock.length
                        ? null
                        : () => setState(() => lines.add(_DeliveryLine())),
                    icon: const Icon(Icons.add),
                    label: const Text('Add item'),
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () async {
                    final d = await pickDateTime(context);
                    if (d != null) setState(() => date = d);
                  },
                  icon: const Icon(Icons.event),
                  label: Text(
                    date == null ? 'Pick delivery date' : niceDate(date),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: busy ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(50),
                  ),
                  icon: const Icon(Icons.inventory),
                  label: const Text('Prepare delivery'),
                ),
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
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
