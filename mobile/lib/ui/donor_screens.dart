import 'package:flutter/material.dart';

import 'widgets.dart';
import 'donate_screen.dart';
export 'donate_screen.dart' show DonateScreen, DonationReceipt;

/// Ivan's note #2: the signed-in donor / relief organization's middle tab.
/// It shows every validated report, split into Active (still needs help,
/// with Donate buttons) and Done (reached 100%, with its final progress).
/// Reports stay "Validated" after they are fulfilled, so both lists come
/// from GET /lookups `validated_reports`.
class DonorReportsTab extends StatelessWidget {
  const DonorReportsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          Material(
            color: cs.surface,
            child: const TabBar(
              tabs: [
                Tab(text: 'Active'),
                Tab(text: 'Done'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                ReportsFeed(done: false),
                ReportsFeed(done: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// UC-D2 / UC-R2 step 1-3: browse validated reports and pick one to
/// support. Layout follows the "Validated Disaster Reports" wireframe.
///
/// [done]: null shows every validated report (guests); false only the ones
/// still under 100%; true only the fulfilled ones, without Donate buttons.
class ReportsFeed extends StatefulWidget {
  final bool? done;
  const ReportsFeed({super.key, this.done});

  @override
  State<ReportsFeed> createState() => _ReportsFeedState();
}

class _ReportsFeedState extends State<ReportsFeed> {
  String search = '';
  String? barangay, type, priority;

  Widget _filter(
    String hint,
    String? value,
    List<String> options,
    ValueChanged<String?> onChanged,
  ) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
      items: [
        DropdownMenuItem<String>(value: null, child: Text(hint)),
        for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [api.lookupsResult],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[0] as Map));
                final done = widget.done;
        final all = names.rows('validated_reports').where((r) {
          if (done == null) return true;
          final full = (r['fulfillment_percentage'] as num? ?? 0) >= 100;
          return done ? full : !full;
        }).toList();
        final q = search.toLowerCase();
        final reports = all.where((r) {
          final text = [
            r['barangay'],
            r['sitio'],
            r['disaster'],
            r['assistance_needed'],
            r['description'],
          ].join(' ').toLowerCase();
          return (q.isEmpty || text.contains(q)) &&
              (barangay == null || r['barangay'] == barangay) &&
              (type == null || r['disaster'] == type) &&
              (priority == null || r['priority_level'] == priority);
        }).toList();
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              width: double.infinity,
              color: Brand.pinkSoft,
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    done == null
                        ? 'Validated Disaster Reports'
                        : done
                        ? 'Completed Reports'
                        : 'Active Reports',
                    style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Brand.ink,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    done == null
                        ? 'Browse and support relief efforts for validated '
                              'disaster reports in Mandaue City'
                        : done
                        ? 'Reports that received everything they needed. '
                              'Thank you to everyone who helped.'
                        : 'Reports that still need help. Pick one and '
                              'pledge goods.',
                    style: const TextStyle(color: Brand.muted),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StatGrid([
                                        StatTile(
                      done == null
                          ? 'Validated reports'
                          : done
                          ? 'Completed reports'
                          : 'Active reports',
                      '${all.length}',
                      done == true
                          ? Icons.task_alt_outlined
                          : Icons.report_outlined,
                    ),
                    if (done != true)
                      StatTile(
                        'High / critical priority',
                        '${all.where((r) => r['priority_level'] == 'High' || r['priority_level'] == 'Critical').length}',
                        Icons.trending_up,
                        color: const Color(0xFFE65100),
                      ),
                  ]),
                  const SizedBox(height: 14),
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText:
                          'Search reports, barangay, or assistance needed...',
                    ),
                    onChanged: (v) => setState(() => search = v.trim()),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _filter('All Barangays', barangay, [
                          for (final b in names.rows('barangays'))
                            '${b['name']}',
                        ], (v) => setState(() => barangay = v)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _filter('All Types', type, [
                          for (final t in names.rows('disaster_types'))
                            '${t['name']}',
                        ], (v) => setState(() => type = v)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _filter('All Priorities', priority, const [
                    'Critical',
                    'High',
                    'Medium',
                    'Low',
                    'Needs Review',
                  ], (v) => setState(() => priority = v)),
                  const SizedBox(height: 14),
                  Text.rich(
                    TextSpan(
                      text: 'Showing ',
                      style: const TextStyle(color: Brand.muted),
                      children: [
                        TextSpan(
                          text: '${reports.length}',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Brand.ink,
                          ),
                        ),
                        const TextSpan(text: ' reports'),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (reports.isEmpty)
                     EmptyState(
                      done == true && all.isEmpty
                          ? 'No completed reports yet.'
                          : 'No validated reports match.',
                    ),
                  for (final r in reports) _card(context, r, names),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _card(BuildContext context, Map<String, dynamic> r, Names names) {
    final pct = (r['fulfillment_percentage'] as num? ?? 0).toDouble();
    final state = pct >= 100
        ? 'Fulfilled'
        : pct > 0
        ? 'In Progress'
        : 'Not Started';
    Widget info(String label, dynamic value) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label:',
            style: const TextStyle(fontSize: 12, color: Brand.muted),
          ),
          Text('${value ?? '-'}', style: const TextStyle(fontSize: 14)),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    '${r['disaster']} in Barangay ${r['barangay']}',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Badge2.priority(r['priority_level'] as String?),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                info('Barangay', r['barangay']),
                info('Sitio', r['sitio']),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                info('Type', r['disaster']),
                info(
                  'Affected',
                  r['affected_families'] == null
                      ? null
                      : '${r['affected_families']} families',
                ),
              ],
            ),
            if (r['description'] != null) ...[
              const SizedBox(height: 10),
              Text('${r['description']}'),
            ],
            const SizedBox(height: 8),
            Text.rich(
              TextSpan(
                text: 'Assistance Needed: ',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                children: [
                  TextSpan(
                    text: '${r['assistance_needed'] ?? '-'}',
                    style: const TextStyle(fontWeight: FontWeight.normal),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Progress(
              delivered: r['total_items_delivered'] as num? ?? 0,
              needed: r['total_items_needed'] as num? ?? 0,
              percent: pct,
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 5),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: statusTone(
                  state == 'Fulfilled'
                      ? 'Complete'
                      : state == 'In Progress'
                      ? 'Partial'
                      : null,
                ).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                state,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: statusTone(
                    state == 'Fulfilled'
                        ? 'Complete'
                        : state == 'In Progress'
                        ? 'Partial'
                        : null,
                  ),
                ),
              ),
            ),
               if (widget.done != true) ...[
              const SizedBox(height: 10),
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DonateScreen(report: r, names: names),
                  ),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                ),
                child: const Text('Donate'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
