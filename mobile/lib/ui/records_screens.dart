import 'package:flutter/material.dart';

import 'donation_entries_view.dart';
import 'ops_screens.dart' show DeliveriesScreen;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Appendix H 4.4 View donation records / 4.5 Monitor donation status
// (Administrator, CSWS Main Office, CMO). One record per donation entry
// (one QR), with its items, filters and sorting.
// ---------------------------------------------------------------------------
class DonationRecordsScreen extends StatelessWidget {
  final bool header;
  const DonationRecordsScreen({super.key, this.header = true});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/donations/records')],
      builder: (context, data) {
        final entries = (data[0] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (header)
              const PageHeader(
                'Donation Records',
                subtitle:
                    'Every donation entry and where it is in the process.',
              ),
            DonationEntriesView(
              entries: entries,
              emptyTitle: 'No donations to show.',
              emptyMessage:
                  'Donation entries appear here once donors submit them.',
            ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Appendix H 6.3 View donation summaries per report (CMO, Administrator)
// ---------------------------------------------------------------------------
class ReportSummariesScreen extends StatelessWidget {
  const ReportSummariesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/cmo/dashboard')],
      builder: (context, data) {
        final rows = ((data[0] as Map)['per_report'] as List).cast<Map>();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (rows.isEmpty)
              const EmptyState('No received donations under any report yet.'),
            for (final r in rows)
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
                      const SizedBox(height: 6),
                      Text(
                        '${r['confirmed_count']} confirmed '
                        '(${r['confirmed_quantity']} units, '
                        'PHP ${r['confirmed_value']}) · '
                        '${r['pending_count']} waiting for CMO',
                      ),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value:
                            ((num.tryParse('${r['fulfillment_percentage']}') ??
                                        0) /
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
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Appendix H 7.5 Monitor completed support records
// (Administrator, CSWS Main Office, DRRMO)
// ---------------------------------------------------------------------------
class SupportRecordsScreen extends StatefulWidget {
  const SupportRecordsScreen({super.key});

  @override
  State<SupportRecordsScreen> createState() => _SupportRecordsScreenState();
}

class _SupportRecordsScreenState extends State<SupportRecordsScreen> {
  String stage = 'Completed';

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/logistics/requests')],
      builder: (context, data) {
        final all = (data[0] as List).cast<Map>();
        final rows = stage.isEmpty
            ? all
            : all.where((r) => r['stage'] == stage).toList();
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
                        onSelected: (_) => setState(() => stage = s),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (rows.isEmpty) const EmptyState('No logistics requests here.'),
            for (final r in rows)
              Card(
                margin: const EdgeInsets.only(bottom: 10),
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.fire_truck_outlined),
                  ),
                  title: Text(
                    'Request #${r['request_id']} · delivery #${r['delivery_id']}'
                    ' to ${r['destination'] ?? '-'}',
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
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Administrator "Records" menu: the monitoring parts of Modules 4-8 that
// Appendix H gives the Administrator (view only).
// ---------------------------------------------------------------------------
class AdminRecordsScreen extends StatefulWidget {
  const AdminRecordsScreen({super.key});

  @override
  State<AdminRecordsScreen> createState() => _AdminRecordsScreenState();
}

class _AdminRecordsScreenState extends State<AdminRecordsScreen> {
  String view = 'donations';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'donations', label: Text('Donations')),
              ButtonSegment(value: 'reports', label: Text('Per report')),
              ButtonSegment(value: 'deliveries', label: Text('Deliveries')),
              ButtonSegment(value: 'support', label: Text('Logistics')),
            ],
            selected: {view},
            onSelectionChanged: (v) => setState(() => view = v.first),
          ),
        ),
        Expanded(
          child: switch (view) {
            'reports' => const ReportSummariesScreen(),
            'deliveries' => const DeliveriesScreen(readOnly: true),
            'support' => const SupportRecordsScreen(),
            _ => const DonationRecordsScreen(header: false),
          },
        ),
      ],
    );
  }
}
