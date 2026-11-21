import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_routes.dart';
import '../realtime.dart';
import 'needs_action.dart';
import 'records_screens.dart' show DonationRecordsScreen;
import 'home_nav.dart';
import 'paginated_list.dart';
import 'paged_donation_entries.dart' show searchDebounce;
import 'widgets.dart';
import 'batch_sheet.dart';
import 'inventory_view.dart';
import 'input_formatters.dart' show pesos;
import 'donation_entries_view.dart' show DonationEntryCard;
import 'receive_filters.dart';
import 'ops_screens.dart' show showDeliveryHistory;
import 'scheduled_deliveries.dart';
import 'item_amounts.dart';
export 'batch_sheet.dart' show openDonationByQr, BatchSheet;

/// Camera QR scanner. Returns the scanned text (e.g. DON-1A2B3C...).
class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool done = false;
  bool _reading = false;
  final _camera = MobileScannerController();

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _found(BarcodeCapture? capture) {
    if (done || capture == null) return;
    final code = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (code == null) return;
    done = true;
    Navigator.of(context).pop(code);
  }

  /// Daniel (Oct 10): donors can save their QR as a picture and send it,
  /// e.g. by chat. Read the QR from that picture instead of the camera.
  Future<void> _fromPhoto() async {
    final messenger = ScaffoldMessenger.of(context);
    final photo = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (photo == null || !mounted) return;
    setState(() => _reading = true);
    BarcodeCapture? capture;
    String? problem;
    try {
      capture = await _camera.analyzeImage(
        photo.path,
        formats: const [BarcodeFormat.qrCode],
      );
      if (capture == null || capture.barcodes.isEmpty) {
        problem = 'No QR code found in that picture. Try a clearer one.';
      }
    } on UnsupportedError {
      problem =
          'Reading a QR from a picture does not work on this device. '
          'Type the reference instead.';
    } catch (_) {
      problem = 'Could not read that picture. Type the reference instead.';
    }
    if (!mounted) return;
    setState(() => _reading = false);
    if (problem != null) {
      messenger.showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    _found(capture);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: const Text('Scan donation QR')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _camera,
            onDetect: _found,
            errorBuilder: (context, error) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Camera not available (${error.errorCode.name}).\n'
                  'Use "Scan from a photo", or go back and type the reference.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FilledButton.tonalIcon(
                onPressed: _reading ? null : _fromPhoto,
                icon: _reading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.photo_library_outlined),
                label: const Text('Scan from a photo'),
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
              DonationStatusChip('${d['status']}'),
            ],
          ),
          const SizedBox(height: 10),
          row('Item', '${d['item_name']}'),
          row('Declared quantity', '${d['quantity']} ${d['unit']}'),
          row('Packaging', d['packaging']),
          // G-002 (D8)
          row('Amount', itemAmount(d)),
          if (d['counted_quantity'] != null)
            row('Counted by CSWS', '${d['counted_quantity']} ${d['unit']}'),
          if (d['barangay_received_quantity'] != null)
            row(
              'Received by barangay',
              '${d['barangay_received_quantity']} ${d['unit']}',
            ),
          row('Estimated value', pesos(d['estimated_value'])),
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

class _ReceiveScreenState extends State<ReceiveScreen>
    with HomeTargetListener<ReceiveScreen> {
  final searchC = TextEditingController();
  String search = ''; // typed
  String _searchSent = ''; // what the list was loaded for
  Timer? _typing;
  String view = 'pending';

  // Concerns2.txt 5.2: filter and sort by barangay and report, remembered
  // on this phone.
  ReceiveFilters filters = const ReceiveFilters();

  // Inventory tab: its own item search and sort (as InventoryView had).
  final _itemC = TextEditingController();
  String _itemSearch = '';
  InventorySort _inventorySort = InventorySort.itemAz;

  /// NF-003: each tab 20 rows per page, filtered and sorted by the server
  /// (GET /donations/receive-queue, services/receive_queue.py). It used to
  /// download every pending entry, every record and the whole inventory.
  late final PagedController _list = PagedController(fetch: _fetch());

  /// Tab counts, "shown of total" and the Barangay / Report choices.
  Map? _summary;
  int _summaryAsked = 0;

  static const _sortParam = {
    ReceiveSort.urgent: 'urgent',
    ReceiveSort.waitingLongest: 'waiting_longest',
    ReceiveSort.newest: 'newest',
    ReceiveSort.barangayAz: 'barangay_az',
  };
  static const _inventorySortParam = {
    InventorySort.itemAz: 'item_az',
    InventorySort.quantityHigh: 'quantity_high',
    InventorySort.quantityLow: 'quantity_low',
    InventorySort.lastUpdated: 'last_updated',
  };

  /// The filters both the list and the summary use.
  Map<String, String> get _filters => {
    'barangay': ?filters.barangay,
    if (filters.reportId != null) 'report_id': '${filters.reportId}',
    'handover': ?filters.handover,
    if (view == 'received') 'status': ?filters.status,
    'when': filters.when.name,
    // "Today" / "Last 7 days" in this phone's time zone.
    'tz': '${DateTime.now().timeZoneOffset.inMinutes}',
    if (view == 'inventory' && _itemSearch.trim().isNotEmpty)
      'q': _itemSearch.trim()
    else if (view != 'inventory' && _searchSent.isNotEmpty)
      'q': _searchSent,
  };

  PageFetch _fetch() {
    final q = {
      ..._filters,
      'tab': view,
      'sort': _sortParam[filters.sort]!,
      'inventory_sort': _inventorySortParam[_inventorySort]!,
    };
    return (offset, limit) => api.get(
      '/donations/receive-queue',
      query: {...q, 'limit': '$limit', 'offset': '$offset'},
    );
  }

  /// A filter, the tab or the search changed: page 1 and new counts.
  void _reload() {
    _list.refresh(fetch: _fetch());
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    final asked = ++_summaryAsked;
    final f = _filters..remove('q');
    final r = await api.get(
      '/donations/receive-queue/summary',
      query: {...f, if (_searchSent.isNotEmpty) 'q': _searchSent},
    );
    if (!mounted || asked != _summaryAsked || !r.ok || r.json is! Map) return;
    setState(() => _summary = r.json as Map);
  }

  /// After a receive (or any change elsewhere) the counts follow.
  void _changedElsewhere() {
    if (mounted) _loadSummary();
  }

  @override
  void initState() {
    super.initState();
    _restoreFilters();
    _loadSummary();
    api.addListener(_changedElsewhere);
  }

  @override
  void dispose() {
    api.removeListener(_changedElsewhere);
    _typing?.cancel();
    _list.dispose();
    searchC.dispose();
    _itemC.dispose();
    super.dispose();
  }

  @override
  String get homeTab => 'Receive';

  /// "Mark picked up" on the Pickups tab opens this tab with the scanner
  /// (HomeTarget('Receive', view: 'scan')): scan the donor's QR, check the
  /// goods and enter the actual quantity, like any other receipt.
  @override
  void applyHomeTarget(HomeTarget target) {
    // NF-002: /csws/receive/received, /csws/receive/inventory.
    if (const {'pending', 'received', 'inventory'}.contains(target.view)) {
      if (target.view != view) {
        view = target.view!;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _reload();
        });
      }
    }
    if (target.view == 'scan') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scan();
      });
    }
  }

  Future<void> _restoreFilters() async {
    final f = await ReceiveFilters.load();
    if (!mounted) return;
    setState(() => filters = f);
    _reload();
  }

  void _setFilters(ReceiveFilters f) {
    setState(() => filters = f);
    f.save();
    _reload();
  }

  void _showAll() {
    final f = filters.cleared();
    searchC.clear();
    _itemC.clear();
    setState(() {
      search = '';
      _searchSent = '';
      _itemSearch = '';
      filters = f;
    });
    f.save();
    _reload();
  }

  void _onSearch(String v, {bool items = false}) {
    setState(() {
      if (!items) search = v.trim();
    });
    _typing?.cancel();
    _typing = Timer(searchDebounce, () {
      if (!mounted) return;
      setState(() => items ? _itemSearch = v : _searchSent = v.trim());
      _reload();
    });
  }

  /// Opens an entry; when its sheet closes, the page on screen and the
  /// counts reload (after a receive they have changed).
  Future<void> _open(String reference) async {
    await openDonationByQr(context, reference);
    if (!mounted) return;
    _list.reloadQuietly();
    _loadSummary();
  }

  Future<void> _scan() async {
    final code = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const ScannerPage()));
    if (code != null && mounted) await _open(code);
  }

  int _n(String tab, String key) =>
      ((_summary?[tab] as Map?)?[key] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    final s = _summary;
    final barangays = ((s?['barangays'] as List?) ?? const [])
        .map((b) => '$b')
        .toList();
    final reports = {
      for (final r in ((s?['reports'] as List?) ?? const []).cast<Map>())
        (r['report_id'] as num).toInt(): '${r['report_label']}',
    };
    final hiding =
        filters.narrowed || search.isNotEmpty || _itemSearch.isNotEmpty;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return PagedListView(
      controller: _list,
      onRefresh: () async => _reload(),
      header: [
        const PageHeader(
          'Handle Physical Donations',
          subtitle:
              'Scan the donor\'s QR code (or search the reference), check '
              'the goods, and record the actual quantity received.',
        ),
        FilledButton.icon(
          onPressed: _scan,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
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
                onChanged: _onSearch,
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
              label: Text('Pending (${_n('pending', 'shown')})'),
            ),
            ButtonSegment(
              value: 'received',
              label: Text('Received (${_n('received', 'shown')})'),
            ),
            ButtonSegment(
              value: 'inventory',
              label: Text('Inventory (${_n('inventory', 'reports')})'),
            ),
          ],
          selected: {view},
          onSelectionChanged: (sel) {
            setState(() => view = sel.first);
            AppRoutes.instance.viewChanged(homeTab, view);
            _reload();
          },
        ),
        const SizedBox(height: 12),
        ReceiveFilterBar(
          key: ValueKey('filters-$view'),
          filters: filters,
          onChanged: _setFilters,
          onShowAll: _showAll,
          barangays: barangays,
          reports: reports,
          received: view == 'received',
          compact: view == 'inventory',
          searching: search.isNotEmpty,
          shown: _n(view, 'shown'),
          total: _n(view, 'total'),
          noun: view == 'inventory' ? 'items in stock' : 'entries',
        ),
        if (view == 'inventory') ...[
          const SizedBox(height: 12),
          AppTextField(
            controller: _itemC,
            label: 'Search item',
            icon: Icons.search,
            onChanged: (v) => _onSearch(v, items: true),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<InventorySort>(
            key: const ValueKey('inventory-sort'),
            initialValue: _inventorySort,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Sort by'),
            items: [
              for (final s in InventorySort.values)
                DropdownMenuItem(value: s, child: Text(s.label)),
            ],
            onChanged: (v) {
              if (v == null || v == _inventorySort) return;
              setState(() => _inventorySort = v);
              _reload();
            },
          ),
        ],
        const SizedBox(height: 12),
      ],
      empty: ReceiveEmpty(
        hiding: hiding,
        nothingText: switch (view) {
          'received' => 'No goods received yet.',
          'inventory' => 'Inventory is empty.',
          _ => 'Nothing waiting to be received.',
        },
        onShowAll: _showAll,
      ),
      itemBuilder: (context, row) {
        // Rows of one report come together; its heading goes above the
        // first of them on this page.
        final i = _list.items.indexOf(row);
        final prev = i > 0 ? _list.items[i - 1] : null;
        final first = prev == null || prev['report_id'] != row['report_id'];
        return switch (view) {
          'received' => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: DonationEntryCard(
              entry: row,
              onTap: () => _open('${row['batch_reference']}'),
            ),
          ),
          'inventory' => _StockRow(row: row, heading: first, t: t, cs: cs),
          _ => PendingEntryRow(entry: row, heading: first, onOpen: _open),
        };
      },
    );
  }
}

/// NF-003: one pending entry on a page of the Pending tab. The first entry
/// of a report on the page carries the report's heading (label, priority,
/// how many of its entries are waiting).
class PendingEntryRow extends StatelessWidget {
  final Map entry;
  final bool heading;
  final Future<void> Function(String batchReference) onOpen;
  const PendingEntryRow({
    super.key,
    required this.entry,
    required this.heading,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final priority = e['report_priority'] as String?;
    final waiting = (e['report_waiting'] as num?)?.toInt() ?? 0;
    return Padding(
      padding: EdgeInsets.only(top: heading ? Space.sm : 0),
      child: Card(
        margin: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (heading) ...[
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.assignment_outlined),
                ),
                title: Text(
                  '${e['report_label'] ?? 'Report #${e['report_id']}'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${priority != null ? '$priority priority · ' : ''}'
                  '$waiting ${waiting == 1 ? 'entry' : 'entries'} waiting',
                ),
                trailing: priority == null ? null : Badge2.priority(priority),
              ),
              const Divider(height: 1),
            ],
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
                  if (waitingText(e['created_at']).isNotEmpty)
                    waitingText(e['created_at']),
                ].join(' · '),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen('${e['batch_reference']}'),
            ),
          ],
        ),
      ),
    );
  }
}

/// NF-003: one stock row of the Inventory tab; the first row of a report on
/// the page carries the report's name.
class _StockRow extends StatelessWidget {
  final Map row;
  final bool heading;
  final TextTheme t;
  final ColorScheme cs;
  const _StockRow({
    required this.row,
    required this.heading,
    required this.t,
    required this.cs,
  });

  String _updated(Map r) {
    final d = DateTime.tryParse('${r['last_updated']}')?.toLocal();
    if (d == null) return '';
    String two(int n) => n.toString().padLeft(2, '0');
    return 'Updated ${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final i = row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (heading) ...[
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(inventoryReportLabel(i), style: t.titleSmall),
          ),
          const Divider(),
        ],
        Padding(
          padding: const EdgeInsets.symmetric(vertical: Space.xxs),
          child: Row(
            children: [
              Icon(
                Icons.warehouse_outlined,
                size: 18,
                color: cs.onSurfaceVariant,
              ),
              Gaps.h8,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${i['item_name']}', style: t.bodyMedium),
                    if (_updated(i).isNotEmpty)
                      Text(
                        _updated(i),
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Text(
                '${i['quantity']} ${i['unit'] ?? ''}'.trim(),
                style: t.titleSmall,
              ),
            ],
          ),
        ),
      ],
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
      // Live: a delivery or DRRMO request changed (Realtime).
      refresh: Realtime.instance.logistics,
      load: [
        () => api.get('/dashboard/csws-main'),
        // Testing #19: deliveries that have not arrived yet.
        () => api.get('/deliveries/', query: scheduledDeliveriesQuery),
      ],
      builder: (context, data) {
        final m = data[0] as Map;
        final scheduled = (data[1] as List).cast<Map>();
        final inv = (m['inventory_summary'] as List).cast<Map>();
        final entries = (m['donation_entries'] as List).cast<Map>();
        final logs = (m['recent_activity'] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            PageHeader('CSWS Main Office Dashboard', subtitle: roleLine()),
            const ResponseTimesCard(), // Phase 7
            StatGrid([
              // Tiles open the tab that lists what they count.
              StatTile(
                'Pending donations',
                '${m['pending_donations']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
                onTap: () => HomeNav.go(context, const HomeTarget('Receive')),
              ),
              // 9.2 (testing, Oct 19): "Due within 3 days" removed. It is
              // not in UC-CM3; expired donations are counted below and are
              // in Records > Expired.
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
                onTap: () => HomeNav.go(context, const HomeTarget('Receive')),
              ),
              StatTile(
                'Total quantity received',
                '${m['total_quantity_received']}',
                Icons.inventory_2_outlined,
                onTap: () => HomeNav.go(context, const HomeTarget('Receive')),
              ),
              StatTile(
                'Deliveries made',
                '${m['deliveries_made']}',
                Icons.local_shipping_outlined,
                onTap: () =>
                    HomeNav.go(context, const HomeTarget('Deliveries')),
              ),
              StatTile(
                'Total quantity distributed',
                '${m['total_quantity_distributed']}',
                Icons.outbox_outlined,
                color: const Color(0xFF2E7D32),
                // What the barangays received (Confirmed deliveries).
                onTap: () => HomeNav.go(
                  context,
                  const HomeTarget('Deliveries', view: 'Confirmed'),
                ),
              ),
            ]),
            ScheduledDeliveriesCard(
              deliveries: scheduled,
              onOpen: (d) =>
                  showDeliveryHistory(context, d['delivery_id'] as int),
              onSeeAll: () =>
                  HomeNav.go(context, const HomeTarget('Deliveries')),
            ),
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
                  // G-002 (D8): "Rice · 10 packs x 5 kg (Sack)".
                  title: Text(
                    '${d['item_name']} · ${itemAmount(d)} (${d['packaging']})',
                  ),
                  subtitle: Text(
                    '${d['qr_reference']} · ${d['handover_method']}'
                    '${d['estimated_value'] != null ? ' · ${pesos(d['estimated_value'])}' : ''}'
                    '\n${d['report_label'] ?? ''}',
                  ),
                  isThreeLine: true,
                  trailing: DonationStatusChip('${d['status']}'),
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
