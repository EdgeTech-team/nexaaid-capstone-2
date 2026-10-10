import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'records_screens.dart' show DonationRecordsScreen;
import 'widgets.dart';
import 'batch_sheet.dart';
import 'inventory_view.dart';
import 'donation_entries_view.dart' show DonationEntryCard;
import 'receive_filters.dart';
export 'batch_sheet.dart' show openDonationByQr, BatchSheet;

/// Camera QR scanner. Returns the scanned text (e.g. DON-1A2B3C...).
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool done = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Scan donation QR')),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (done) return;
              final code = capture.barcodes
                  .map((b) => b.rawValue)
                  .whereType<String>()
                  .firstOrNull;
              if (code == null) return;
              done = true;
              Navigator.of(context).pop(code);
            },
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera not available (${error.errorCode.name}).\n'
                  'Go back and type the reference instead.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          const Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'Point the camera at the donor\'s QR code',
                style: TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Donation details as declared by the donor, plus the Receive action.
class DonationSheet extends StatelessWidget {
  final Map<String, dynamic> d;
  const DonationSheet(this.d, {super.key});

  Future<void> _receive(BuildContext context) async {
    final v = await formDialog(
      context,
      title: 'Receive ${d['qr_reference']}',
      message:
          'Declared: ${d['quantity']} ${d['unit']} ${d['item_name']}. '
          'Record what was actually accepted.',
      fields: [
        DialogField(
          'qty',
          'Actual quantity received (${d['unit']})',
          number: true,
          initial: '${d['quantity']}',
        ),
        const DialogField('notes', 'Notes (optional)', required: false),
      ],
      confirm: 'Receive into inventory',
    );
    if (v == null || !context.mounted) return;
    final r = await act(
      context,
      () => api.post(
        '/donations/receive',
        body: {
          'donation_id': d['donation_id'],
          'actual_quantity': int.parse(v['qty']!),
          'notes': v['notes']!.isEmpty ? null : v['notes'],
        },
      ),
      success: '${d['qr_reference']} received and added to inventory',
    );
    if (r.ok && context.mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    Widget row(String k, dynamic v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(k, style: const TextStyle(color: Brand.muted)),
          ),
          Expanded(child: Text('${v ?? '-'}')),
        ],
      ),
    );
    final pending = d['status'] == 'Pending';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${d['qr_reference']}',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              Badge2.status('${d['status']}'),
            ],
          ),
          const SizedBox(height: 10),
          row('Item', '${d['item_name']}'),
          row('Declared quantity', '${d['quantity']} ${d['unit']}'),
          row('Packaging', d['packaging']),
          row(
            'Estimated value',
            d['estimated_value'] == null ? null : 'PHP ${d['estimated_value']}',
          ),
          row('Handover', d['handover_method']),
          if (d['pickup_address'] != null)
            row('Pickup at', d['pickup_address']),
          row('Donor', d['donor']),
          row('For report', d['report_label']),
          if (d['actual_quantity_received'] != null)
            row('Received', '${d['actual_quantity_received']} ${d['unit']}'),
          const SizedBox(height: 16),
          if (pending)
            FilledButton.icon(
              onPressed: () => _receive(context),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              icon: const Icon(Icons.move_to_inbox),
              label: const Text('Receive goods'),
            )
          else
            Text(
              'Already ${d['status']}.',
              style: const TextStyle(color: Brand.muted),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CM1 Handle physical donations
// ---------------------------------------------------------------------------
class ReceiveScreen extends StatefulWidget {
  const ReceiveScreen({super.key});

  @override
  State<ReceiveScreen> createState() => _ReceiveScreenState();
}

class _ReceiveScreenState extends State<ReceiveScreen> {
  final searchC = TextEditingController();
  String search = '';
  String view = 'pending';
  int _loads = 0;

  // Concerns2.txt 5.2: filter and sort by barangay and report, remembered
  // on this phone. Priority comes from the validated reports (Module 3).
  ReceiveFilters filters = const ReceiveFilters();
  Map<int, String?> priorities = {};

  @override
  void initState() {
    super.initState();
    _restoreFilters();
    _loadPriorities();
  }

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  Future<void> _restoreFilters() async {
    final f = await ReceiveFilters.load();
    if (mounted) setState(() => filters = f);
  }

  /// Priority per report for "Most urgent" and the report headers. If this
  /// fails, the screen still works; reports just have no priority shown.
  Future<void> _loadPriorities() async {
    final r = await api.get('/reports/validated', query: {'limit': '200'});
    if (!mounted || !r.ok || r.json is! List) return;
    setState(() {
      priorities = {
        for (final x in (r.json as List).cast<Map>())
          (x['report_id'] as num).toInt(): x['priority_level'] as String?,
      };
    });
  }

  void _setFilters(ReceiveFilters f) {
    setState(() => filters = f);
    f.save();
  }

  void _showAll() {
    final f = filters.cleared();
    searchC.clear();
    setState(() {
      search = '';
      filters = f;
    });
    f.save();
  }

  /// Opens an entry; when its sheet closes, the pending list and the
  /// inventory reload (after a receive they have changed).
  Future<void> _open(String reference) async {
    await openDonationByQr(context, reference);
    if (mounted) setState(() => _loads++);
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (code != null && mounted) await _open(code);
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      key: ValueKey(_loads),
      load: [
        () => api.get('/donations/entries', query: {'pending_only': 'true'}),
        () => api.get('/donations/inventory'),
        // 5.2 Received tab: one record per donation entry (one QR).
        () => api.get('/donations/records'),
      ],
      builder: (context, data) {
        final allReports = ((data[0] as Map)['reports'] as List).cast<Map>();
        final inventory = (data[1] as List).cast<Map>();
        final records = (data[2] as List).cast<Map>();
        final receivedAll = records
            .where((e) => e['status'] != 'Pending')
            .toList();

        // Choices come from every tab, so the lists are the same everywhere.
        final everything = <Map>[...allReports, ...receivedAll, ...inventory];
        final barangays = barangayOptions(everything);
        final reportChoices = reportOptions(everything, filters.barangay);

        // Report -> its pending entries (one per QR / batch_reference),
        // filtered and in the chosen order.
        final reports = filterPendingReports(
          allReports,
          filters,
          search: search,
          priorities: priorities,
        );
        final pendingTotal = allReports.fold<int>(
          0,
          (n, r) => n + (r['entries'] as List).length,
        );
        final pendingCount = reports.fold<int>(
          0,
          (n, r) => n + (r['entries'] as List).length,
        );
        final received = filterReceivedEntries(
          records,
          filters,
          search: search,
          priorities: priorities,
        );
        final stock = filterInventoryRows(inventory, filters);
        // Inventory is linked to specific reports (Inventory module rules).
        final reportCount = stock.map((i) => i['report_id']).toSet().length;
        final hiding = filters.narrowed || search.isNotEmpty;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const PageHeader(
              'Handle Physical Donations',
              subtitle:
                  'Scan the donor\'s QR code (or search the reference), check '
                  'the goods, and record the actual quantity received.',
            ),
            FilledButton.icon(
              onPressed: _scan,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
            ),
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
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: searchC,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Or type the QR reference, donor or item',
                      hintText: 'DON-...',
                    ),
                    onChanged: (v) => setState(() => search = v.trim()),
                    onSubmitted: _open,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: () => _open(searchC.text),
                  child: const Text('Find'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SegmentedButton<String>(
              segments: [
                ButtonSegment(
                  value: 'pending',
                  label: Text('Pending ($pendingCount)'),
                ),
                ButtonSegment(
                  value: 'received',
                  label: Text('Received (${received.length})'),
                ),
                ButtonSegment(
                  value: 'inventory',
                  label: Text('Inventory ($reportCount)'),
                ),
              ],
              selected: {view},
              onSelectionChanged: (s) => setState(() => view = s.first),
            ),
            const SizedBox(height: 12),
            ReceiveFilterBar(
              key: ValueKey('filters-$view'),
              filters: filters,
              onChanged: _setFilters,
              onShowAll: _showAll,
              barangays: barangays,
              reports: reportChoices,
              received: view == 'received',
              compact: view == 'inventory',
              searching: search.isNotEmpty,
              shown: switch (view) {
                'received' => received.length,
                'inventory' => stock.length,
                _ => pendingCount,
              },
              total: switch (view) {
                'received' => receivedAll.length,
                'inventory' => inventory.length,
                _ => pendingTotal,
              },
              noun: view == 'inventory' ? 'items in stock' : 'entries',
            ),
            const SizedBox(height: 12),
            if (view == 'pending') ...[
              if (reports.isEmpty)
                ReceiveEmpty(
                  hiding: hiding,
                  nothingText: 'Nothing waiting to be received.',
                  onShowAll: _showAll,
                ),
              for (final r in reports)
                PendingReportCard(
                  report: r,
                  onOpen: _open,
                  priority: r['priority_level'] as String?,
                  showWaiting: true,
                ),
            ] else if (view == 'received') ...[
              if (received.isEmpty)
                ReceiveEmpty(
                  hiding: hiding,
                  nothingText: 'No goods received yet.',
                  onShowAll: _showAll,
                ),
              for (final e in received)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DonationEntryCard(
                    entry: e,
                    onTap: () => _open('${e['batch_reference']}'),
                  ),
                ),
            ] else if (stock.isEmpty && inventory.isNotEmpty)
              ReceiveEmpty(
                hiding: true,
                nothingText: 'Inventory is empty.',
                onShowAll: _showAll,
              )
            else
              InventoryView(
                // New key when the barangay/report changes, so its own
                // report list starts fresh.
                key: ValueKey('inv-${filters.barangay}-${filters.reportId}'),
                rows: stock,
              ),
          ],
        );
      },
    );
  }
}

/// One report on the Pending tab with its pending donation entries
/// ("Donation 1 · 3 items · donor · handover"). Tapping an entry opens it.
class PendingReportCard extends StatelessWidget {
  final Map report;
  final Future<void> Function(String batchReference) onOpen;

  /// 5.2: report priority in words ("Critical"), shown in the header.
  final String? priority;

  /// 5.2: "Waiting 4 days" under each entry.
  final bool showWaiting;
  const PendingReportCard({
    super.key,
    required this.report,
    required this.onOpen,
    this.priority,
    this.showWaiting = false,
  });

  @override
  Widget build(BuildContext context) {
    final entries = (report['entries'] as List).cast<Map>();
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const CircleAvatar(child: Icon(Icons.assignment_outlined)),
            title: Text(
              '${report['report_label'] ?? 'Report #${report['report_id']}'}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              '${priority != null ? '$priority priority · ' : ''}'
              '${entries.length} '
              '${entries.length == 1 ? 'entry' : 'entries'} waiting',
            ),
            trailing: priority == null ? null : Badge2.priority(priority),
          ),
          const Divider(height: 1),
          for (final e in entries)
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(
                'Donation ${e['entry_no']} · ${e['total_items']} '
                '${e['total_items'] == 1 ? 'item' : 'items'}',
              ),
              subtitle: Text(
                [
                  if (e['donor'] != null) '${e['donor']}',
                  '${e['handover_method']}',
                  if (e['pending_items'] != e['total_items'])
                    '${e['pending_items']} still pending',
                  if (showWaiting && waitingText(e['created_at']).isNotEmpty)
                    waitingText(e['created_at']),
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen('${e['batch_reference']}'),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CM3 / manuscript 7.1 CSWS Main Office dashboard
// ---------------------------------------------------------------------------
class CswsMainDashboard extends StatelessWidget {
  const CswsMainDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/dashboard/csws-main')],
      builder: (context, data) {
        final m = data[0] as Map;
        final inv = (m['inventory_summary'] as List).cast<Map>();
        final entries = (m['donation_entries'] as List).cast<Map>();
        final logs = (m['recent_activity'] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader('CSWS Main Office Dashboard', subtitle: roleLine()),
            StatGrid([
              StatTile(
                'Pending donations',
                '${m['pending_donations']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
              ),
              // Donation expiry: what needs attention before it lapses.
              StatTile(
                'Due within 3 days',
                '${m['due_soon_donations'] ?? 0}',
                Icons.timer_outlined,
                color: StatusColors.base('On Hold'),
              ),
              StatTile(
                'Expired or cancelled',
                '${(m['expired_donations'] ?? 0) + (m['cancelled_donations'] ?? 0)}',
                Icons.timer_off_outlined,
                color: StatusColors.base('Expired'),
              ),
              StatTile(
                'Entries received',
                '${m['entries_received']}',
                Icons.move_to_inbox_outlined,
              ),
              StatTile(
                'Total quantity received',
                '${m['total_quantity_received']}',
                Icons.inventory_2_outlined,
              ),
              StatTile(
                'Deliveries made',
                '${m['deliveries_made']}',
                Icons.local_shipping_outlined,
              ),
              StatTile(
                'Total quantity distributed',
                '${m['total_quantity_distributed']}',
                Icons.outbox_outlined,
                color: const Color(0xFF2E7D32),
              ),
            ]),
            const SectionTitle('Inventory summary'),
            if (inv.isEmpty) const EmptyState('Inventory is empty.'),
            Card(
              child: Column(
                children: [
                  for (final i in inv)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.warehouse_outlined),
                      title: Text('${i['item']}'),
                      trailing: Text(
                        '${i['quantity']} ${i['unit']}',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ),
            ),
            const SectionTitle('Donation entries'),
            if (entries.isEmpty) const EmptyState('No donations yet.'),
            for (final d in entries)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(
                    '${d['declared_quantity']} ${d['unit']} ${d['item_name']} · ${d['packaging']}',
                  ),
                  subtitle: Text(
                    '${d['qr_reference']} · ${d['handover_method']}'
                    '${d['estimated_value'] != null ? ' · PHP ${d['estimated_value']}' : ''}'
                    '\n${d['report_label'] ?? ''}',
                  ),
                  isThreeLine: true,
                  trailing: Badge2.status('${d['status']}'),
                ),
              ),
            const SectionTitle('Recent activity'),
            ActivityList(logs),
          ],
        );
      },
    );
  }
}

/// Activity log rows (audit_logs).
class ActivityList extends StatelessWidget {
  final List<Map> logs;
  const ActivityList(this.logs, {super.key});

  @override
  Widget build(BuildContext context) {
    if (logs.isEmpty) return const EmptyState('No activity yet.');
    return Card(
      child: Column(
        children: [
          for (final l in logs)
            ListTile(
              dense: true,
              leading: const Icon(Icons.history, size: 20),
              title: Text(
                '${l['action']}'
                '${l['entity_id'] != null ? ' #${l['entity_id']}' : ''}',
              ),
              subtitle: Text(
                '${l['user'] ?? l['by']} · ${niceDate(l['timestamp'] ?? l['at'])}',
              ),
            ),
        ],
      ),
    );
  }
}
