import 'package:flutter/material.dart';

import 'widgets.dart';

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
  const DeliveriesScreen({super.key, this.barangay = false});

  Future<void> _requestTransport(BuildContext context, Map d) async {
    final v = await formDialog(
      context,
      title: 'Request DRRMO logistics support',
      message: 'For delivery #${d['delivery_id']}.',
      fields: const [
        DialogField(
          'notes',
          'What is needed',
          hint: 'e.g. 1 truck, 2 volunteers',
          required: false,
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
          'notes': v['notes']!.isEmpty ? null : v['notes'],
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
      floatingActionButton: barangay
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
                barangay ? 'Incoming Aid' : 'Release & Delivery Tracking',
                subtitle: barangay
                    ? 'Aid for your assigned barangay. Confirm receipt when it '
                          'arrives, then acknowledge it.'
                    : 'Prepare goods from a report\'s inventory, then move the '
                          'status one step at a time.',
              ),
              if (rows.isEmpty)
                EmptyState(
                  barangay
                      ? 'No deliveries to your barangay yet.'
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
                    Badge2.status(reqStage == 'Pending' ? 'Pending' : reqStage),
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
                    (status == 'Preparing' || status == 'In Transit') &&
                    (request == null ||
                        reqStage == 'Declined' ||
                        reqStage == 'Completed'))
                  OutlinedButton.icon(
                    onPressed: () => _requestTransport(context, d),
                    icon: const Icon(Icons.fire_truck_outlined),
                    label: const Text('Request transport'),
                  ),
                if (!barangay && next != null)
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

class _NewDeliveryScreenState extends State<NewDeliveryScreen> {
  final _form = GlobalKey<FormState>();
  String? reportId, brgyId, itemId;
  List<Map> stock = const [];
  bool loadingStock = false;
  final qty = TextEditingController();
  String? date;
  bool busy = false;

  Future<void> _loadStock(String? rid, Names names) async {
    setState(() {
      reportId = rid;
      itemId = null;
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

  Map? get _chosen {
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
            {'item_id': int.parse(itemId!), 'quantity': int.parse(qty.text)},
          ],
        },
      ),
      success: 'Delivery prepared',
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (r.ok) Navigator.pop(context);
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
          final chosen = _chosen;
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
                DropdownButtonFormField<String>(
                  key: ValueKey('stock-$reportId-${stock.length}'),
                  initialValue: itemId,
                  isExpanded: true,
                  items: [
                    for (final s in stock)
                      DropdownMenuItem(
                        value: '${s['item_id']}',
                        child: Text(
                          '${s['item_name']} (${s['quantity']} ${s['unit'] ?? ''} available)',
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => itemId = v),
                  validator: (v) => v == null ? 'Choose an item' : null,
                  decoration: InputDecoration(
                    labelText: 'Item from this report\'s inventory',
                    helperText:
                        reportId != null && !loadingStock && stock.isEmpty
                        ? 'No stock for this report yet. Receive donations first.'
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: qty,
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
      ],
      builder: (context, data) {
        final dash = data[0] as Map;
        final pending = (data[1] as List).cast<Map>();
        final confirmed = (data[2] as List).cast<Map>();
        final perReport = (dash['per_report'] as List).cast<Map>();
        final rows = view == 'pending' ? pending : confirmed;
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
              ),
              StatTile(
                'On hold',
                '${dash['on_hold']}',
                Icons.pause_circle_outline,
              ),
              StatTile(
                'Pending review',
                '${dash['pending_review']}',
                Icons.rate_review_outlined,
              ),
              StatTile(
                'Officially confirmed',
                '${dash['confirmed']}',
                Icons.verified,
                color: const Color(0xFF2E7D32),
              ),
            ]),
            const SizedBox(height: 14),
            SegmentedButton<String>(
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
              onSelectionChanged: (s) => setState(() => view = s.first),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty)
              EmptyState(
                view == 'pending'
                    ? 'No donations waiting for confirmation.'
                    : 'No confirmed donations yet.',
              ),
            for (final d in rows) _donationCard(d),
            const SectionTitle('Donation summary per report'),
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
    final date = await pickDateTime(context);
    if (date == null || !mounted) return;
    final v = await formDialog(
      context,
      title: 'Logistics details',
      fields: const [
        DialogField(
          'notes',
          'Vehicle / team (optional)',
          hint: 'e.g. Truck 2, 3 personnel',
          required: false,
        ),
      ],
      confirm: 'Schedule',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.patch(
        '/drrmo/requests/${r['request_id']}/accept',
        body: {
          'scheduled_date': date,
          if (v['notes']!.isNotEmpty) 'notes': v['notes'],
        },
      ),
      success: 'Scheduled for ${niceDate(date)}',
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
          'Accepted': 'Scheduled',
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
                'Scheduled',
                '${dash['scheduled']}',
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
                              icon: const Icon(Icons.event),
                              label: const Text('Accept & schedule'),
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
