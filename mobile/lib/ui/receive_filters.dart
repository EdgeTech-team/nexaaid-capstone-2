import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'widgets.dart';

/// Concerns2.txt 5.2 (UC-CM1, Table 34, Scope 3.3): receive and record goods
/// by donation entry, with filter and sort by report and by barangay.
///
/// Used by the CSWS Main Office Receive screen (csws_screens.dart) on all
/// three tabs: Pending, Received and Inventory. Filtering happens in the app
/// on data the screen already loads; nothing on the server changes.
///
/// Plain words on purpose (non-technical staff): "Barangay", "Report",
/// "Show first", "More", "Showing 5 of 12 entries", "Show all".

const receiveHandovers = ['Drop Off', 'Door to Door'];
const receivedStatuses = ['Partly Received', 'Received', 'Confirmed'];

enum ReceiveSort {
  urgent('Most urgent', 'Most urgent'),
  waitingLongest('Waiting longest', 'Oldest first'),
  newest('Newest', 'Newest'),
  barangayAz('Barangay A–Z', 'Barangay A–Z');

  /// Label on the Pending tab / on the Received tab.
  final String label;
  final String receivedLabel;
  const ReceiveSort(this.label, this.receivedLabel);
}

enum ReceiveWhen {
  any('Any time'),
  today('Today'),
  week('Last 7 days'),
  month('Last 30 days');

  final String label;
  const ReceiveWhen(this.label);
}

// ---------------------------------------------------------------------------
// Small helpers (pure, unit tested in test/receive_filters_test.dart)
// ---------------------------------------------------------------------------

/// Report label as the server writes it: "#21 Typhoon - Banilad"
/// (or "Typhoon in Banilad" in donor views).
String receiveReportLabel(Map row) {
  final r = row['report'];
  return '${row['report_label'] ?? (r is Map ? r['label'] : null) ?? 'Report #${row['report_id']}'}';
}

/// The barangay name, taken from the report label (every row has one).
String barangayOf(Map row) {
  final label = receiveReportLabel(row);
  for (final sep in const [' - ', ' in ']) {
    final i = label.lastIndexOf(sep);
    if (i >= 0) return label.substring(i + sep.length).trim();
  }
  return 'Unknown barangay';
}

int priorityRank(String? p) => switch (p) {
  'Critical' => 0,
  'High' => 1,
  'Medium' => 2,
  'Low' => 3,
  _ => 4,
};

DateTime? whenOf(dynamic v) =>
    v == null ? null : DateTime.tryParse('$v')?.toLocal();

int _calendarDays(DateTime from, DateTime to) => DateTime(
  to.year,
  to.month,
  to.day,
).difference(DateTime(from.year, from.month, from.day)).inDays;

/// "Waiting since today" / "Waiting 1 day" / "Waiting 4 days".
String waitingText(dynamic createdAt, {DateTime? now}) {
  final d = whenOf(createdAt);
  if (d == null) return '';
  final days = _calendarDays(d, now ?? DateTime.now());
  if (days <= 0) return 'Waiting since today';
  return days == 1 ? 'Waiting 1 day' : 'Waiting $days days';
}

bool inWhen(dynamic createdAt, ReceiveWhen w, {DateTime? now}) {
  if (w == ReceiveWhen.any) return true;
  final d = whenOf(createdAt);
  if (d == null) return false;
  final age = _calendarDays(d, now ?? DateTime.now());
  return switch (w) {
    ReceiveWhen.today => age <= 0,
    ReceiveWhen.week => age < 7,
    ReceiveWhen.month => age < 30,
    ReceiveWhen.any => true,
  };
}

/// QR reference, donor or any item name.
bool matchesSearch(Map e, String search) {
  final q = search.trim().toLowerCase();
  if (q.isEmpty) return true;
  if ('${e['batch_reference']}'.toLowerCase().contains(q)) return true;
  if ('${e['donor'] ?? ''}'.toLowerCase().contains(q)) return true;
  final items = e['items'];
  if (items is List) {
    for (final i in items) {
      if (i is Map && '${i['item_name']}'.toLowerCase().contains(q)) {
        return true;
      }
    }
  }
  return false;
}

/// Older entries get smaller numbers (submitted time, else first item id).
int _age(Map e) {
  final d = whenOf(e['created_at']);
  if (d != null) return d.millisecondsSinceEpoch;
  final items = e['items'];
  if (items is List && items.isNotEmpty && items.first is Map) {
    return ((items.first as Map)['donation_id'] as num?)?.toInt() ?? 0;
  }
  return 0;
}

int _reportId(Map r) => (r['report_id'] as num?)?.toInt() ?? 0;

// ---------------------------------------------------------------------------
// The chosen filters (remembered on this phone)
// ---------------------------------------------------------------------------
class ReceiveFilters {
  final String? barangay;
  final int? reportId;
  final ReceiveSort sort;
  final String? handover;
  final ReceiveWhen when;

  /// Received tab only: Partly Received / Received / Confirmed.
  final String? status;

  const ReceiveFilters({
    this.barangay,
    this.reportId,
    this.sort = ReceiveSort.urgent,
    this.handover,
    this.when = ReceiveWhen.any,
    this.status,
  });

  static const _keep = Object();

  ReceiveFilters copyWith({
    Object? barangay = _keep,
    Object? reportId = _keep,
    ReceiveSort? sort,
    Object? handover = _keep,
    ReceiveWhen? when,
    Object? status = _keep,
  }) => ReceiveFilters(
    barangay: identical(barangay, _keep) ? this.barangay : barangay as String?,
    reportId: identical(reportId, _keep) ? this.reportId : reportId as int?,
    sort: sort ?? this.sort,
    handover: identical(handover, _keep) ? this.handover : handover as String?,
    when: when ?? this.when,
    status: identical(status, _keep) ? this.status : status as String?,
  );

  /// Something is hiding rows.
  bool get narrowed =>
      barangay != null ||
      reportId != null ||
      handover != null ||
      when != ReceiveWhen.any ||
      status != null;

  /// How many of the "More" filters are on.
  int get moreCount =>
      (handover != null ? 1 : 0) +
      (when != ReceiveWhen.any ? 1 : 0) +
      (status != null ? 1 : 0);

  /// "Show all": clears every filter but keeps the chosen order.
  ReceiveFilters cleared() => ReceiveFilters(sort: sort);

  static const _prefsKey = 'receive_filters_v1';

  Map<String, dynamic> toJson() => {
    'barangay': barangay,
    'report_id': reportId,
    'sort': sort.name,
    'handover': handover,
    'when': when.name,
    'status': status,
  };

  static ReceiveFilters fromJson(Map j) => ReceiveFilters(
    barangay: j['barangay'] as String?,
    reportId: (j['report_id'] as num?)?.toInt(),
    sort: ReceiveSort.values.firstWhere(
      (s) => s.name == j['sort'],
      orElse: () => ReceiveSort.urgent,
    ),
    handover: j['handover'] as String?,
    when: ReceiveWhen.values.firstWhere(
      (w) => w.name == j['when'],
      orElse: () => ReceiveWhen.any,
    ),
    status: j['status'] as String?,
  );

  Future<void> save() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_prefsKey, jsonEncode(toJson()));
    } catch (e) {
      debugPrint('Receive filters not saved: $e');
    }
  }

  static Future<ReceiveFilters> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString(_prefsKey);
      if (s != null) return fromJson(jsonDecode(s) as Map);
    } catch (e) {
      debugPrint('Receive filters not loaded: $e');
    }
    return const ReceiveFilters();
  }
}

// ---------------------------------------------------------------------------
// Filtering and sorting per tab
// ---------------------------------------------------------------------------

/// Pending tab: reports (from GET /donations/entries?pending_only=true) with
/// only their matching entries, reports and entries in the chosen order.
/// Adds 'priority_level' to each report from [priorities] when missing.
List<Map> filterPendingReports(
  List<Map> reports,
  ReceiveFilters f, {
  String search = '',
  Map<int, String?> priorities = const {},
  DateTime? now,
}) {
  final out = <Map>[];
  for (final r in reports) {
    if (f.barangay != null && barangayOf(r) != f.barangay) continue;
    if (f.reportId != null && _reportId(r) != f.reportId) continue;
    final entries = ((r['entries'] as List?) ?? const [])
        .cast<Map>()
        .where(
          (e) =>
              matchesSearch(e, search) &&
              (f.handover == null || e['handover_method'] == f.handover) &&
              inWhen(e['created_at'], f.when, now: now),
        )
        .toList();
    if (entries.isEmpty) continue;
    entries.sort(
      (a, b) => f.sort == ReceiveSort.newest
          ? _age(b).compareTo(_age(a))
          : _age(a).compareTo(_age(b)),
    );
    out.add({
      ...r,
      'entries': entries,
      'priority_level': r['priority_level'] ?? priorities[_reportId(r)],
    });
  }
  int oldest(Map r) =>
      (r['entries'] as List).cast<Map>().map(_age).reduce(math.min);
  int newest(Map r) =>
      (r['entries'] as List).cast<Map>().map(_age).reduce(math.max);
  out.sort(switch (f.sort) {
    ReceiveSort.urgent => (a, b) {
      final p = priorityRank(a['priority_level'] as String?)
          .compareTo(priorityRank(b['priority_level'] as String?));
      return p != 0 ? p : oldest(a).compareTo(oldest(b));
    },
    ReceiveSort.waitingLongest => (a, b) => oldest(a).compareTo(oldest(b)),
    ReceiveSort.newest => (a, b) => newest(b).compareTo(newest(a)),
    ReceiveSort.barangayAz => (a, b) {
      final c = barangayOf(a)
          .toLowerCase()
          .compareTo(barangayOf(b).toLowerCase());
      return c != 0 ? c : _reportId(a).compareTo(_reportId(b));
    },
  });
  return out;
}

/// Received tab: entries (from GET /donations/records) that have at least
/// one item received, in the chosen order.
List<Map> filterReceivedEntries(
  List<Map> entries,
  ReceiveFilters f, {
  String search = '',
  Map<int, String?> priorities = const {},
  DateTime? now,
}) {
  final shown = entries
      .where((e) => e['status'] != 'Pending')
      .where((e) => f.barangay == null || barangayOf(e) == f.barangay)
      .where((e) => f.reportId == null || _reportId(e) == f.reportId)
      .where((e) => f.handover == null || e['handover_method'] == f.handover)
      .where((e) => f.status == null || e['status'] == f.status)
      .where((e) => inWhen(e['created_at'], f.when, now: now))
      .where((e) => matchesSearch(e, search))
      .toList();
  // "Most urgent" is for choosing what to receive first (Pending tab).
  // Received goods are already in; their order follows time, so on this
  // tab "Most urgent" shows the newest first.
  shown.sort(switch (f.sort) {
    ReceiveSort.urgent => (a, b) => _age(b).compareTo(_age(a)),
    ReceiveSort.waitingLongest => (a, b) => _age(a).compareTo(_age(b)),
    ReceiveSort.newest => (a, b) => _age(b).compareTo(_age(a)),
    ReceiveSort.barangayAz => (a, b) {
      final c = barangayOf(a)
          .toLowerCase()
          .compareTo(barangayOf(b).toLowerCase());
      return c != 0 ? c : _age(b).compareTo(_age(a));
    },
  });
  return shown;
}

/// Inventory tab: rows (from GET /donations/inventory) of the chosen
/// barangay and report. InventoryView keeps its own search and sort.
List<Map> filterInventoryRows(List<Map> rows, ReceiveFilters f) => rows
    .where((r) => f.barangay == null || barangayOf(r) == f.barangay)
    .where((r) => f.reportId == null || _reportId(r) == f.reportId)
    .toList();

/// Every barangay that appears in [rows], A–Z.
List<String> barangayOptions(Iterable<Map> rows) =>
    {for (final r in rows) barangayOf(r)}.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

/// Every report in [rows] (only the chosen barangay's), newest report first.
Map<int, String> reportOptions(Iterable<Map> rows, String? barangay) {
  final m = <int, String>{};
  for (final r in rows) {
    if (barangay != null && barangayOf(r) != barangay) continue;
    m.putIfAbsent(_reportId(r), () => receiveReportLabel(r));
  }
  final ids = m.keys.toList()..sort((a, b) => b.compareTo(a));
  return {for (final id in ids) id: m[id]!};
}

// ---------------------------------------------------------------------------
// The filter bar
// ---------------------------------------------------------------------------
class ReceiveFilterBar extends StatefulWidget {
  final ReceiveFilters filters;
  final ValueChanged<ReceiveFilters> onChanged;

  /// Clears the filters and the search box.
  final VoidCallback onShowAll;
  final List<String> barangays;
  final Map<int, String> reports;

  /// Received tab: other sort labels and a Status filter.
  final bool received;

  /// Inventory tab: only Barangay and Report (it has its own sort).
  final bool compact;
  final bool searching;
  final int shown;
  final int total;
  final String noun;

  const ReceiveFilterBar({
    super.key,
    required this.filters,
    required this.onChanged,
    required this.onShowAll,
    required this.barangays,
    required this.reports,
    required this.shown,
    required this.total,
    this.noun = 'entries',
    this.received = false,
    this.compact = false,
    this.searching = false,
  });

  @override
  State<ReceiveFilterBar> createState() => _ReceiveFilterBarState();
}

class _ReceiveFilterBarState extends State<ReceiveFilterBar> {
  late bool more = widget.filters.moreCount > 0;

  @override
  Widget build(BuildContext context) {
    final f = widget.filters;
    final t = Theme.of(context).textTheme;
    final barangay = widget.barangays.contains(f.barangay) ? f.barangay : null;
    final reportId = widget.reports.containsKey(f.reportId) ? f.reportId : null;
    final status = widget.received ? f.status : null;
    final hiding = f.narrowed || widget.searching;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String?>(
          key: ValueKey('receive-brgy-$barangay'),
          initialValue: barangay,
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: 'Barangay',
            prefixIcon: Icon(Icons.location_on_outlined),
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('All barangays')),
            for (final b in widget.barangays)
              DropdownMenuItem(value: b, child: Text(b)),
          ],
          // A new barangay clears the report, so a report from another
          // barangay can never stay selected.
          onChanged: (v) =>
              widget.onChanged(f.copyWith(barangay: v, reportId: null)),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int?>(
          key: ValueKey('receive-report-$barangay-$reportId'),
          initialValue: reportId,
          isExpanded: true,
          decoration: InputDecoration(
            labelText: 'Report',
            prefixIcon: const Icon(Icons.assignment_outlined),
            helperText: barangay == null ? null : 'Only reports in $barangay',
          ),
          items: [
            const DropdownMenuItem(value: null, child: Text('All reports')),
            for (final e in widget.reports.entries)
              DropdownMenuItem(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => widget.onChanged(f.copyWith(reportId: v)),
        ),
        if (!widget.compact) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<ReceiveSort>(
                  key: ValueKey('receive-sort-${f.sort}-${widget.received}'),
                  // Received tab has no "Most urgent" (see filterReceivedEntries).
                  initialValue: widget.received && f.sort == ReceiveSort.urgent
                      ? ReceiveSort.newest
                      : f.sort,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Show first',
                    prefixIcon: Icon(Icons.swap_vert),
                  ),
                  items: [
                    for (final s in ReceiveSort.values)
                      if (!(widget.received && s == ReceiveSort.urgent))
                        DropdownMenuItem(
                          value: s,
                          child: Text(
                            widget.received ? s.receivedLabel : s.label,
                          ),
                        ),
                  ],
                  onChanged: (v) => widget.onChanged(f.copyWith(sort: v)),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => setState(() => more = !more),
                icon: Icon(more ? Icons.expand_less : Icons.tune),
                label: Text(
                  f.moreCount == 0 ? 'More' : 'More (${f.moreCount})',
                ),
              ),
            ],
          ),
          if (more) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              key: ValueKey('receive-handover-${f.handover}'),
              initialValue: f.handover,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Handover',
                prefixIcon: Icon(Icons.local_shipping_outlined),
              ),
              items: [
                const DropdownMenuItem(value: null, child: Text('Any')),
                for (final h in receiveHandovers)
                  DropdownMenuItem(value: h, child: Text(h)),
              ],
              onChanged: (v) => widget.onChanged(f.copyWith(handover: v)),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<ReceiveWhen>(
              key: ValueKey('receive-when-${f.when}'),
              initialValue: f.when,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Submitted',
                prefixIcon: Icon(Icons.event_outlined),
              ),
              items: [
                for (final w in ReceiveWhen.values)
                  DropdownMenuItem(value: w, child: Text(w.label)),
              ],
              onChanged: (v) => widget.onChanged(f.copyWith(when: v)),
            ),
            if (widget.received) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                key: ValueKey('receive-status-$status'),
                initialValue: status,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Status',
                  prefixIcon: Icon(Icons.flag_outlined),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('Any')),
                  for (final s in receivedStatuses)
                    DropdownMenuItem(value: s, child: Text(s)),
                ],
                onChanged: (v) => widget.onChanged(f.copyWith(status: v)),
              ),
            ],
          ],
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                'Showing ${widget.shown} of ${widget.total} ${widget.noun}',
                style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            if (hiding)
              TextButton.icon(
                onPressed: widget.onShowAll,
                icon: const Icon(Icons.filter_alt_off_outlined),
                label: const Text('Show all'),
              ),
          ],
        ),
      ],
    );
  }
}

/// Empty list message that says why, and offers "Show all" when a filter or
/// the search is hiding rows.
class ReceiveEmpty extends StatelessWidget {
  final bool hiding;
  final String nothingText;
  final VoidCallback onShowAll;
  const ReceiveEmpty({
    super.key,
    required this.hiding,
    required this.nothingText,
    required this.onShowAll,
  });

  @override
  Widget build(BuildContext context) {
    if (!hiding) return EmptyState(nothingText);
    return Column(
      children: [
        const EmptyState('Nothing matches these filters.'),
        TextButton.icon(
          onPressed: onShowAll,
          icon: const Icon(Icons.filter_alt_off_outlined),
          label: const Text('Show all'),
        ),
      ],
    );
  }
}
