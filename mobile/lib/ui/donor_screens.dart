import 'dart:convert';

import 'package:flutter/material.dart';

import 'widgets.dart';
import 'donate_screen.dart';
export 'donate_screen.dart' show DonateScreen, DonationReceipt;

/// UC-D2 / UC-R2 step 1-3: browse validated reports and pick one to
/// support. Layout follows the "Validated Disaster Reports" wireframe.
class ReportsFeed extends StatefulWidget {
  const ReportsFeed({super.key});

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
        final all = names.rows('validated_reports');
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
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Validated Disaster Reports',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: Brand.ink,
                    ),
                  ),
                  SizedBox(height: 6),
                  Text(
                    'Browse and support relief efforts for validated disaster '
                    'reports in Mandaue City',
                    style: TextStyle(color: Brand.muted),
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
                      'Validated reports',
                      '${all.length}',
                      Icons.report_outlined,
                    ),
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
                    const EmptyState('No validated reports match.'),
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
        ),
      ),
    );
  }
}

const _donationSteps = ['Pending', 'Received', 'Confirmed'];

/// Pending -> Received (CSWS) -> Confirmed (CMO), as small labeled dots.
class _DonationSteps extends StatelessWidget {
  final String status;
  const _DonationSteps(this.status);

  @override
  Widget build(BuildContext context) {
    final at = _donationSteps.indexOf(status);
    const labels = ['Submitted', 'Received by CSWS', 'Confirmed by City'];
    return Row(
      children: [
        for (var i = 0; i < 3; i++) ...[
          Icon(
            i <= at ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: i <= at ? Brand.pink : Colors.black26,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                color: i <= at ? Brand.ink : Brand.muted,
              ),
            ),
          ),
          if (i < 2) const SizedBox(width: 8),
        ],
      ],
    );
  }
}

/// UC-D3 / UC-D4 (donor) and UC-R3 / UC-R4 (relief organization):
/// own donation history, status, supported reports and their fulfillment.
class DonorDashboard extends StatelessWidget {
  const DonorDashboard({super.key});

  Future<void> _showQr(BuildContext context, Map d) async {
    final r = await api.get('/donations/${d['donation_id']}/qr');
    if (!context.mounted || !r.ok) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${d['qr_reference']}'),
        content: Image.memory(
          base64Decode(r.json['qr_image_base64'] as String),
          width: 220,
          height: 220,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/donations/mine'), api.lookupsResult],
      builder: (context, data) {
        final m = data[0] as Map;
        final profile = m['profile'] as Map, sum = m['summary'] as Map;
        final donations = (m['donations'] as List).cast<Map>();
        final supported = (m['supported_reports'] as List).cast<Map>();
        final active = Names(Map<String, dynamic>.from(data[1] as Map))
            .rows('validated_reports');
        final isOrg = profile['organization'] != null;
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader(
              isOrg ? 'Relief Organization Dashboard' : 'Donor Dashboard',
              subtitle: isOrg
                  ? '${profile['organization']} • ${roleLine()}'
                  : '${profile['name']} • ${roleLine()}',
            ),
            if (isOrg)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    const Text(
                      'Account status: ',
                      style: TextStyle(color: Brand.muted),
                    ),
                    Badge2.status(
                      profile['account_status'] == 'Approved'
                          ? 'Validated'
                          : '${profile['account_status']}',
                    ),
                  ],
                ),
              ),
            StatGrid([
              StatTile(
                'Total donations',
                '${sum['total_donations']}',
                Icons.volunteer_activism_outlined,
              ),
              StatTile(
                'Waiting for drop-off / pickup',
                '${sum['pending']}',
                Icons.hourglass_top,
                color: const Color(0xFFEF6C00),
              ),
              StatTile(
                'Received by CSWS',
                '${sum['received']}',
                Icons.inventory_2_outlined,
                color: const Color(0xFF1565C0),
              ),
              StatTile(
                'Confirmed by the City',
                '${sum['confirmed']}',
                Icons.verified_outlined,
                color: const Color(0xFF2E7D32),
              ),
              StatTile(
                'Reports supported',
                '${sum['supported_reports']}',
                Icons.flag_outlined,
              ),
              StatTile(
                'Total quantity given',
                '${sum['total_quantity']}',
                Icons.inventory_outlined,
              ),
            ]),
            const SectionTitle('Donation history'),
            if (donations.isEmpty)
              const EmptyState(
                'No donations yet. Open Validated Reports to donate.',
              ),
            for (final d in donations)
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
                              '${d['quantity']} ${d['unit']} ${d['item_name']}',
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.status('${d['status']}'),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${d['qr_reference']} · ${d['packaging']} · '
                        '${d['handover_method']} · ${niceDate(d['created_at'])}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Brand.muted,
                        ),
                      ),
                      if (d['report'] != null)
                        Text(
                          'For: ${d['report']['label']}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      const SizedBox(height: 10),
                      _DonationSteps('${d['status']}'),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: () => _showQr(context, d),
                          icon: const Icon(Icons.qr_code_2),
                          label: const Text('Show QR'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SectionTitle('Supported reports'),
            if (supported.isEmpty)
              const EmptyState('You have not supported a report yet.'),
            for (final r in supported)
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
                              '${r['label']}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Badge2.priority(r['priority_level'] as String?),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Progress(
                        delivered: r['total_items_delivered'] as num? ?? 0,
                        needed: r['total_items_needed'] as num? ?? 0,
                        percent: r['fulfillment_percentage'] as num?,
                      ),
                    ],
                  ),
                ),
              ),
            const SectionTitle('Active reports and priority'),
            if (active.isEmpty) const EmptyState('No active reports.'),
            for (final r in active.take(5))
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  dense: true,
                  title: Text('${r['disaster']} in ${r['barangay']}'),
                  subtitle: Text(
                    'Fulfilled ${(r['fulfillment_percentage'] as num? ?? 0).toStringAsFixed(0)}%',
                  ),
                  trailing: Badge2.priority(r['priority_level'] as String?),
                ),
              ),
          ],
        );
      },
    );
  }
}
