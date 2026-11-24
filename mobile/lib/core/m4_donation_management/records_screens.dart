import 'package:flutter/material.dart';

import '../shared/kept_views.dart';
import '../shared/app_routes.dart';
import '../shared/api.dart' show Roles;
import '../m8_delivery_tracking/acknowledgment_screen.dart' show canSeeReceipt, openAcknowledgment;
import 'donation_entries_view.dart';
import 'expiry_widgets.dart';
import '../shared/home_nav.dart';
import '../m7_logistics_support/ops_screens.dart' show DeliveriesScreen;
import 'paged_donation_entries.dart';
import '../shared/paginated_list.dart';
import '../shared/widgets.dart';

// ---------------------------------------------------------------------------
// Appendix H 4.4 View donation records / 4.5 Monitor donation status
// (Administrator, CSWS Main Office, CMO, Barangay Receiving Representative).
// One record per donation entry (one QR), with its items, filters and
// sorting; "Per report" groups them by report, and tapping a report opens
// its records with a status summary on top.
// ---------------------------------------------------------------------------
class DonationRecordsScreen extends StatefulWidget {
  final bool header;

  /// NF-001: the Administrator's disaster type filter (records screen).
  final int? disasterTypeId;
  final String? disasterTypeName;
  const DonationRecordsScreen({
    super.key,
    this.header = true,
    this.disasterTypeId,
    this.disasterTypeName,
  });

  @override
  State<DonationRecordsScreen> createState() => _DonationRecordsScreenState();
}

/// CSWS / Admin can reopen or cancel; the CMO and barangay only view.
bool get _canManageRecords =>
    api.role == Roles.cswsMain || api.role == Roles.admin;

class _DonationRecordsScreenState extends State<DonationRecordsScreen> {
  bool perReport = false;
  final int _loads = 0;

  @override
  Widget build(BuildContext context) {
    final barangay = api.role == Roles.barangay;
    final top = <Widget>[
      if (widget.header)
        PageHeader(
          'Donation Records',
          subtitle: barangay
              ? "Donations for your barangay's reports and where each "
                    'one is in the process.'
              : 'Every donation entry and where it is in the process.',
        ),
      // Defense fixes (Nov 23): no QR scanner in Records; CSWS Main Office
      // scans on its Receive tab.
      SegmentedButton<bool>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(
            value: false,
            icon: Icon(Icons.qr_code_2),
            label: Text('Entries'),
          ),
          ButtonSegment(
            value: true,
            icon: Icon(Icons.article_outlined),
            label: Text('Per report'),
          ),
        ],
        selected: {perReport},
        onSelectionChanged: (v) => setState(() => perReport = v.first),
      ),
      Gaps.v16,
    ];
    // UAT (Nov 14): Entries and Per report stay loaded when switching.
    return KeptViews(
      current: perReport ? 'reports' : 'entries',
      resetKey: _loads,
      builder: (context, v) => v == 'reports'
          // NF-001: reports grouped and paged in SQL, with Expired /
          // Cancelled entries counted. A Barangay Rep only gets its own.
          ? PagedReportRecords(
              header: top,
              disasterTypeId: widget.disasterTypeId,
              disasterTypeName: widget.disasterTypeName,
            )
          // NF-003: entries load 10 at a time; filters, sort and counts come
          // from the server. A Barangay Rep only gets its own (backend).
          : PagedDonationEntries(
              header: top,
              disasterTypeId: widget.disasterTypeId,
              disasterTypeName: widget.disasterTypeName,
              footer: _entryFooter,
              emptyTitle: 'No donations to show.',
              emptyMessage: barangay
                  ? "Donations for your barangay's reports appear here."
                  : 'Donation entries appear here once donors submit them.',
            ),
    );
  }
}

/// NF-001 / NF-003: "Per report" one page at a time
/// (GET /donations/records/per-report): one card per report with its entry
/// count and status mix, newest report first. Tap a report to open its
/// records.
class PagedReportRecords extends StatefulWidget {
  final List<Widget> header;
  final int? disasterTypeId;
  final String? disasterTypeName;
  const PagedReportRecords({
    super.key,
    this.header = const [],
    this.disasterTypeId,
    this.disasterTypeName,
  });

  @override
  State<PagedReportRecords> createState() => _PagedReportRecordsState();
}

class _PagedReportRecordsState extends State<PagedReportRecords> {
  late final controller = PagedController(
    fetch: (offset, limit) => api.get(
      '/donations/records/per-report',
      query: {
        if (widget.disasterTypeId != null)
          'disaster_type_id': '${widget.disasterTypeId}',
        'limit': '$limit',
        'offset': '$offset',
      },
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// "3 entries · 2 Pending · 1 Received".
  static String statusLine(Map r) {
    final n = (r['total_entries'] as num?)?.toInt() ?? 0;
    final by = (r['by_status'] as Map?) ?? const {};
    return [
      '$n ${n == 1 ? 'entry' : 'entries'}',
      for (final s in entryStatuses)
        if (((by[s] as num?) ?? 0) > 0) '${by[s]} ${donationStatusText(s)}',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return PagedListView(
      controller: controller,
      header: widget.header,
      empty: EmptyView(
        icon: Icons.article_outlined,
        title: widget.disasterTypeName != null
            ? 'No donations for ${widget.disasterTypeName} yet.'
            : 'No donations to show.',
        message: 'Reports appear here once they have donations.',
        compact: true,
      ),
      itemBuilder: (context, r) {
        final id = (r['report_id'] as num).toInt();
        final label = '${r['report_label'] ?? 'Report #$id'}';
        return Padding(
          padding: const EdgeInsets.only(bottom: Space.sm),
          child: AppCard(
            key: ValueKey('report-records-$id'),
            // Defense fixes (Nov 23): a summary only, not clickable.
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: t.titleMedium),
                      Gaps.v4,
                      Text(
                        statusLine(r),
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// One card per report with its entry count and status mix. Tap a report
/// to open its records.
class ReportRecordsList extends StatelessWidget {
  final List<Map> entries;
  const ReportRecordsList(this.entries, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final byReport = <int, List<Map>>{};
    for (final e in entries) {
      byReport.putIfAbsent(e['report_id'] as int, () => []).add(e);
    }
    // Newest report first, as on the backend (group_by_report).
    final ids = byReport.keys.toList()..sort((a, b) => b.compareTo(a));
    if (ids.isEmpty) {
      return const EmptyView(
        icon: Icons.article_outlined,
        title: 'No donations to show.',
        message: 'Reports appear here once they have donations.',
        compact: true,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final id in ids)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: AppCard(
              key: ValueKey('report-records-$id'),
              // Defense fixes (Nov 23): a summary only, not clickable.
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entryReportLabel(byReport[id]!.first),
                          style: t.titleMedium,
                        ),
                        Gaps.v4,
                        Text(
                          _statusLine(byReport[id]!),
                          style: t.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// "3 entries · 2 Pending · 1 Received".
  static String _statusLine(List<Map> entries) {
    final parts = [
      '${entries.length} ${entries.length == 1 ? 'entry' : 'entries'}',
      for (final s in entryStatuses)
        if (entries.any((e) => e['status'] == s))
          '${entries.where((e) => e['status'] == s).length} '
              '${donationStatusText(s)}',
    ];
    return parts.join(' · ');
  }
}

/// Reminder 4.4 "Records per report": every donation entry of one report
/// with its status, a status summary on top, and the same status chips,
/// search, handover filter and sort as the other records screens.
void openReportRecords(
  BuildContext context, {
  required int reportId,
  required String title,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ReportRecordsScreen(reportId: reportId, title: title),
    ),
  );
}

class ReportRecordsScreen extends StatelessWidget {
  final int reportId;
  final String title;
  const ReportRecordsScreen({
    super.key,
    required this.reportId,
    required this.title,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      // NF-003: this report's entries a page at a time, with the summary of
      // the whole report on top and the filters on the server.
      body: PagedDonationEntries(
        reportId: reportId,
        footer: _entryFooter,
        emptyTitle: 'No donations for this report yet.',
        emptyMessage: 'Donation entries appear here once donors submit them.',
      ),
    );
  }
}

Widget _entryFooter(Map e) => _EntryActions(e);

/// View receipt (every role that may read receipts); reopen (Expired /
/// Cancelled) or cancel for the donor (still waiting): CSWS Main Office
/// and the Administrator.
class _EntryActions extends StatelessWidget {
  final Map entry;
  const _EntryActions(this.entry);

  @override
  Widget build(BuildContext context) {
    final closed =
        isClosedEntry(entry) ||
        (entry['items'] as List).any(
          (i) =>
              (i as Map)['status'] == 'Expired' || i['status'] == 'Cancelled',
        );
    final waiting = hasWaitingItems(entry) && _canManageRecords;
    final reopen = closed && _canManageRecords;
    // Nov 24: the Acknowledgment Receipt of each delivery the barangay
    // confirmed that carried these goods.
    final receipts = canSeeReceipt(api.role)
        ? ((entry['receipt_deliveries'] as List?) ?? const []).cast<Map>()
        : const <Map>[];
    if (!reopen && !waiting && receipts.isEmpty) return const SizedBox.shrink();
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: Space.xs,
      children: [
        for (final r in receipts)
          TextButton.icon(
            key: ValueKey('view-receipt-${r['delivery_id']}'),
            onPressed: () =>
                openAcknowledgment(context, (r['delivery_id'] as num).toInt()),
            icon: const Icon(Icons.receipt_long_outlined),
            label: Text(
              receipts.length == 1
                  ? 'View receipt'
                  : 'View receipt · Delivery #${r['delivery_id']}',
            ),
          ),
        // Defense fixes (Nov 23): only CSWS Main Office cancels for a donor.
        if (waiting && api.role != Roles.admin)
          TextButton.icon(
            onPressed: () => cancelDonation(context, entry, staff: true),
            icon: const Icon(Icons.block),
            label: const Text('Cancel for donor'),
          ),
        if (reopen)
          FilledButton.icon(
            onPressed: () => reinstateDonation(context, entry),
            icon: const Icon(Icons.restart_alt),
            label: const Text('Reopen'),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Appendix H 6.3 View donation summaries per report (CMO, Administrator).
// NF-001 / NF-003: one page at a time from GET /cmo/report-summaries,
// grouped in SQL and filtered by disaster type.
// ---------------------------------------------------------------------------
class ReportSummariesScreen extends StatefulWidget {
  final int? disasterTypeId;
  final String? disasterTypeName;
  const ReportSummariesScreen({
    super.key,
    this.disasterTypeId,
    this.disasterTypeName,
  });

  @override
  State<ReportSummariesScreen> createState() => _ReportSummariesScreenState();
}

class _ReportSummariesScreenState extends State<ReportSummariesScreen> {
  late final controller = PagedController(
    fetch: (offset, limit) => api.get(
      '/cmo/report-summaries',
      query: {
        if (widget.disasterTypeId != null)
          'disaster_type_id': '${widget.disasterTypeId}',
        'limit': '$limit',
        'offset': '$offset',
      },
    ),
  );

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PagedListView(
      controller: controller,
      empty: EmptyState(
        widget.disasterTypeName != null
            ? 'No received donations for ${widget.disasterTypeName} yet.'
            : 'No received donations under any report yet.',
      ),
      itemBuilder: (context, r) => Card(
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
              const SizedBox(height: 6),
              Text(
                '${r['confirmed_count']} acknowledged '
                '(${r['confirmed_quantity']} units, '
                'PHP ${r['confirmed_value']}) · '
                '${r['pending_count']} waiting for CMO',
              ),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value:
                    ((num.tryParse('${r['fulfillment_percentage']}') ?? 0) /
                            100)
                        .clamp(0, 1)
                        .toDouble(),
              ),
              const SizedBox(height: 4),
              Text(
                'Fulfillment ${r['fulfillment_percentage']}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Appendix H 7.5 Monitor completed support records
// (Administrator, CSWS Main Office, DRRMO). NF-001 / NF-003: the stage chips
// and the disaster type are filters on the server, one page at a time.
// ---------------------------------------------------------------------------
class SupportRecordsScreen extends StatefulWidget {
  final int? disasterTypeId;
  final String? disasterTypeName;
  const SupportRecordsScreen({
    super.key,
    this.disasterTypeId,
    this.disasterTypeName,
  });

  @override
  State<SupportRecordsScreen> createState() => _SupportRecordsScreenState();
}

class _SupportRecordsScreenState extends State<SupportRecordsScreen> {
  String stage = 'Completed';
  late final controller = PagedController(fetch: _fetchFor(stage));

  PageFetch _fetchFor(String stage) =>
      (offset, limit) => api.get(
        '/logistics/requests',
        query: {
          if (stage.isNotEmpty) 'stage': stage,
          if (widget.disasterTypeId != null)
            'disaster_type_id': '${widget.disasterTypeId}',
          'limit': '$limit',
          'offset': '$offset',
        },
      );

  void _pick(String s) {
    if (s == stage) return;
    setState(() => stage = s);
    controller.refresh(fetch: _fetchFor(s));
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.disasterTypeName;
    return PagedListView(
      controller: controller,
      header: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final s in const [
                'Completed',
                '',
                'Pending',
                'Accepted',
                'In Transit',
                'Declined',
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(s.isEmpty ? 'All' : s),
                    selected: stage == s,
                    onSelected: (_) => _pick(s),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
      empty: EmptyState(
        type != null
            ? 'No logistics requests for $type here.'
            : 'No logistics requests here.',
      ),
      itemBuilder: (context, r) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          leading: CircleAvatar(
            child: Icon(
              r['request_type'] == 'Pickup'
                  ? Icons.door_front_door_outlined
                  : Icons.fire_truck_outlined,
            ),
          ),
          // A Disaster Unit pickup run has no delivery.
          title: Text(
            r['request_type'] == 'Pickup'
                ? 'Request #${r['request_id']} · pickup run, '
                      '${r['destination'] ?? '-'}'
                : 'Request #${r['request_id']} · delivery '
                      '#${r['delivery_id']} to ${r['destination'] ?? '-'}',
          ),
          subtitle: Text(
            [
              if (r['report_label'] != null) '${r['report_label']}',
              if ((r['goods'] as List?)?.isNotEmpty ?? false)
                (r['goods'] as List).join(', '),
              if (r['scheduled_date'] != null)
                'Scheduled ${niceDate(r['scheduled_date'])}',
              if (r['notes'] != null) '${r['notes']}',
            ].join('\n'),
          ),
          isThreeLine: true,
          trailing: Badge2.status('${r['stage']}'),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Administrator "Records" menu: the monitoring parts of Modules 4-8 that
// Appendix H gives the Administrator (view only).
// NF-001: a "Disaster type" filter above the tabs. The choice is kept while
// switching tabs, and each tab asks the server for that type only.
// ---------------------------------------------------------------------------
class AdminRecordsScreen extends StatefulWidget {
  const AdminRecordsScreen({super.key});

  @override
  State<AdminRecordsScreen> createState() => _AdminRecordsScreenState();
}

class _AdminRecordsScreenState extends State<AdminRecordsScreen>
    with HomeTargetListener<AdminRecordsScreen> {
  String view = 'donations';

  /// null = All types.
  int? typeId;
  String? typeName;
  late final Future<Map<String, dynamic>> _lookups = api.lookups();

  // A donation notification opens Records on Donations, with its Scan QR
  // button, and the donation's pop-out on top.
  @override
  String get homeTab => 'Records';

  @override
  void applyHomeTarget(HomeTarget target) {
    view = target.view ?? 'donations';
    // NF-002: /admin/records...?type=<id> (a web address) sets the filter.
    final q = target.query;
    if (q != null) {
      typeId = int.tryParse(q['type'] ?? '');
      typeName = null;
      _nameType();
    }
  }

  /// The name of [typeId] for the empty messages, once the lookups are in.
  void _nameType() {
    final id = typeId;
    if (id == null) return;
    _lookups.then((m) {
      for (final t
          in ((m['disaster_types'] as List?) ?? const []).cast<Map>()) {
        if (t['id'] == id && mounted && typeId == id) {
          setState(() => typeName = '${t['name']}');
        }
      }
    });
  }

  /// NF-002: the open sub-tab and filter in the web address.
  void _toAddress({bool replace = false}) => AppRoutes.instance.viewChanged(
    homeTab,
    view,
    query: typeId == null ? const {} : {'type': '$typeId'},
    replace: replace,
  );

  Widget _typeFilter() => FutureBuilder<Map<String, dynamic>>(
    future: _lookups,
    builder: (context, snap) {
      final types = ((snap.data?['disaster_types'] as List?) ?? const [])
          .cast<Map>();
      return DropdownButtonFormField<int?>(
        key: const ValueKey('records-disaster-type'),
        initialValue: typeId,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Disaster type'),
        items: [
          const DropdownMenuItem(value: null, child: Text('All types')),
          for (final t in types)
            DropdownMenuItem(
              value: (t['id'] as num).toInt(),
              child: Text('${t['name']}'),
            ),
        ],
        onChanged: (v) {
          setState(() {
            typeId = v;
            typeName = null;
            for (final t in types) {
              if (t['id'] == v) typeName = '${t['name']}';
            }
          });
          _toAddress(replace: true);
        },
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _typeFilter(),
              Gaps.v12,
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'donations', label: Text('Donations')),
                  ButtonSegment(value: 'reports', label: Text('Per report')),
                  ButtonSegment(value: 'deliveries', label: Text('Deliveries')),
                  ButtonSegment(value: 'support', label: Text('Logistics')),
                ],
                selected: {view},
                onSelectionChanged: (v) {
                  setState(() => view = v.first);
                  _toAddress();
                },
              ),
            ],
          ),
        ),
        // UAT (Nov 14): sub-tabs opened once stay loaded; another disaster
        // type starts every sub-tab again from page 1.
        Expanded(
          child: KeptViews(
            current: view,
            resetKey: typeId ?? 'all',
            builder: (context, v) => switch (v) {
              'reports' => ReportSummariesScreen(
                disasterTypeId: typeId,
                disasterTypeName: typeName,
              ),
              'deliveries' => DeliveriesScreen(
                readOnly: true,
                disasterTypeId: typeId,
                disasterTypeName: typeName,
              ),
              'support' => SupportRecordsScreen(
                disasterTypeId: typeId,
                disasterTypeName: typeName,
              ),
              _ => DonationRecordsScreen(
                header: false,
                disasterTypeId: typeId,
                disasterTypeName: typeName,
              ),
            },
          ),
        ),
      ],
    );
  }
}
