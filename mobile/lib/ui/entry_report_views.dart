import 'package:flutter/material.dart';

import 'widgets.dart';

// Report -> Entries -> Items (team rule, Oct 6). One ENTRY = one donor
// submission = one batch_reference. The grouping comes from the backend
// (services/donation_entries.py); this file only displays it.

/// 4.1: every donation entry, or only one report's.
void openDonationEntries(
  BuildContext context, {
  int? reportId,
  String title = 'Donation entries',
}) => _openEntriesPage(
  context,
  title,
  '/donations/entries',
  query: {if (reportId != null) 'report_id': '$reportId'},
  empty: 'No donations yet.',
);

/// 5.1: the held donations behind the Admin dashboard tile.
void openHeldDonations(BuildContext context) => _openEntriesPage(
  context,
  'Held donations',
  '/dashboard/admin/held',
  empty: 'No donations are on hold.',
);

void _openEntriesPage(
  BuildContext context,
  String title,
  String path, {
  Map<String, String> query = const {},
  required String empty,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Loader(
          load: [() => api.get(path, query: query)],
          builder: (context, data) {
            final m = data[0] as Map;
            return EntryReportsList(
              (m['reports'] as List).cast<Map>(),
              held: ((m['held_donation_ids'] as List?) ?? const []).toSet(),
              empty: empty,
            );
          },
        ),
      ),
    ),
  );
}

/// Full list: each report, its entries (tap to open), each entry's items.
class EntryReportsList extends StatelessWidget {
  final List<Map> reports;

  /// donation_ids to mark "On hold" (held donations page only).
  final Set held;
  final String empty;
  const EntryReportsList(
    this.reports, {
    super.key,
    this.held = const {},
    this.empty = 'No donations yet.',
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (reports.isEmpty) EmptyState(empty),
        for (final r in reports) ...[
          SectionTitle(
            '${r['report_label'] ?? 'Report #${r['report_id']}'}',
            trailing: Text(
              '${r['total_entries']} entries · ${r['total_items']} items',
              style: const TextStyle(color: Brand.muted),
            ),
          ),
          for (final e in (r['entries'] as List).cast<Map>())
            _entryCard(context, e),
        ],
      ],
    );
  }

  Widget _entryCard(BuildContext context, Map e) {
    final items = (e['items'] as List).cast<Map>();
    final hasHeld = items.any((i) => held.contains(i['donation_id']));
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        initiallyExpanded: hasHeld,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                'Donation ${e['entry_no']}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Badge2.status('${e['status']}'),
          ],
        ),
        subtitle: Text(
          [
            '${e['batch_reference']}',
            if (e['donor'] != null) '${e['donor']}',
            '${e['total_items']} item(s) · ${e['handover_method'] ?? '-'}',
            niceDate(e['created_at']),
          ].join('\n'),
        ),
        children: [for (final i in items) _itemTile(i)],
      ),
    );
  }

  Widget _itemTile(Map i) {
    final received = i['actual_quantity_received'];
    return ListTile(
      dense: true,
      title: Text('${i['quantity']} ${i['unit']} ${i['item_name']}'),
      subtitle: Text(
        '${i['qr_reference']} · ${i['packaging'] ?? '-'}'
        '${received != null ? ' · received $received' : ''}',
      ),
      trailing: held.contains(i['donation_id'])
          ? const Badge2(
              'On hold',
              Color(0xFFC62828),
              icon: Icons.pause_circle_outline,
            )
          : Badge2.status('${i['status']}'),
    );
  }
}

/// 6.3: one card per report with its entry and item counts, for the
/// Admin and CMO dashboards. Tap a report to see its entries.
class EntrySummaryList extends StatelessWidget {
  final Map data; // the GET /donations/entries response
  const EntrySummaryList(this.data, {super.key});

  @override
  Widget build(BuildContext context) {
    final reports = (data['reports'] as List).cast<Map>();
    if (reports.isEmpty) return const EmptyState('No donations yet.');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${data['total_entries']} entries across '
          '${data['total_reports']} report(s)',
          style: const TextStyle(color: Brand.muted),
        ),
        const SizedBox(height: 6),
        for (final r in reports)
          Card(
            margin: const EdgeInsets.only(bottom: 10),
            child: ListTile(
              title: Text(
                '${r['report_label'] ?? 'Report #${r['report_id']}'}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Text(
                '${r['total_entries']} entries · ${r['total_items']} items\n'
                '${_itemStatusLine(r)}',
              ),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () => openDonationEntries(
                context,
                reportId: r['report_id'] as int,
                title: '${r['report_label'] ?? 'Report'}',
              ),
            ),
          ),
      ],
    );
  }
}

/// "4 confirmed · 2 received · 1 pending" across a report's items.
String _itemStatusLine(Map report) {
  final counts = <String, int>{};
  for (final e in (report['entries'] as List).cast<Map>()) {
    for (final i in (e['items'] as List).cast<Map>()) {
      final s = '${i['status']}';
      counts[s] = (counts[s] ?? 0) + 1;
    }
  }
  return counts.entries
      .map((c) => '${c.value} ${c.key.toLowerCase()}')
      .join(' · ');
}