import 'package:flutter/material.dart';

import 'report_filters.dart';
import 'widgets.dart';
import 'donate_screen.dart';
export 'donate_screen.dart' show DonateScreen, DonationReceipt;

/// UC-D2 / UC-R2 step 1-3 and dashboard item 7.3 (5): every validated
/// report, active and fulfilled, with search, priority (3.3) and
/// fulfillment filters, and sorting. Fulfilled reports are no longer a
/// separate section: pick the Fulfilled chip or sort by progress.
class ReportsFeed extends StatefulWidget {
  /// Show the page title (off when a screen already has an app bar title).
  final bool header;
  const ReportsFeed({super.key, this.header = true});

  @override
  State<ReportsFeed> createState() => _ReportsFeedState();
}

class _ReportsFeedState extends State<ReportsFeed> {
  final searchC = TextEditingController();
  String search = '';
  String? barangay, type, priority, fulfillment;
  ReportSort sort = ReportSort.urgent;

  @override
  void dispose() {
    searchC.dispose();
    super.dispose();
  }

  Widget _dropdown(
    String label,
    String? value,
    List<String> options,
    ValueChanged<String?> onChanged,
  ) {
    return DropdownButtonFormField<String?>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        const DropdownMenuItem<String?>(value: null, child: Text('All')),
        for (final o in options)
          DropdownMenuItem<String?>(
            value: o,
            child: Text(o, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Loader(
      load: [api.lookupsResult],
      builder: (context, data) {
        final names = Names(Map<String, dynamic>.from(data[0] as Map));
        final all = names.rows('validated_reports');
        final q = search.toLowerCase();
        final matching = all.where((r) {
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
        final reports = sortAndFilterReports(
          matching,
          fulfillment: fulfillment,
          sort: sort,
        );
        final open = all.where((r) => fulfillmentState(r) != 'Fulfilled');
        final urgent = open.where(
          (r) => r['priority_level'] == 'Critical' || r['priority_level'] == 'High',
        );

        return ListView(
          padding: Space.page,
          children: [
            if (widget.header) ...[
              Text('All reports', style: t.headlineSmall),
              Gaps.v4,
              Text(
                'Validated disaster reports in Mandaue City, active and '
                'fulfilled.',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v16,
            ],
            StatCardGrid([
              StatCard(
                label: 'Still need help',
                value: '${open.length}',
                icon: Icons.campaign_outlined,
              ),
              StatCard(
                label: 'Critical or high priority',
                value: '${urgent.length}',
                icon: Icons.priority_high,
                color: PriorityColors.base('Critical'),
              ),
            ]),
            Gaps.v16,
            AppTextField(
              controller: searchC,
              label: 'Search barangay, disaster or needs',
              icon: Icons.search,
              onChanged: (v) => setState(() => search = v.trim()),
            ),
            Gaps.v12,
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in <String?>[
                    null,
                    ...PriorityColors.levels,
                    'Needs Review',
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: Space.xs),
                      child: ChoiceChip(
                        label: Text(p ?? 'Any priority'),
                        selected: priority == p,
                        onSelected: (_) => setState(() => priority = p),
                      ),
                    ),
                ],
              ),
            ),
            Gaps.v8,
            FulfillmentChips(
              rows: matching,
              value: fulfillment,
              onChanged: (v) => setState(() => fulfillment = v),
            ),
            Gaps.v12,
            Row(
              children: [
                Expanded(
                  child: _dropdown('Barangay', barangay, [
                    for (final b in names.rows('barangays')) '${b['name']}',
                  ], (v) => setState(() => barangay = v)),
                ),
                Gaps.h12,
                Expanded(
                  child: _dropdown('Disaster', type, [
                    for (final d in names.rows('disaster_types'))
                      '${d['name']}',
                  ], (v) => setState(() => type = v)),
                ),
              ],
            ),
            Gaps.v12,
            ReportSortField(
              value: sort,
              onChanged: (v) => setState(() => sort = v),
            ),
            Gaps.v16,
            Text(
              'Showing ${reports.length} of ${all.length} reports',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v8,
            if (reports.isEmpty)
              const AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.filter_alt_off_outlined,
                  title: 'No reports match',
                  message: 'Try another priority, progress or search.',
                ),
              ),
            for (final r in reports) ...[
              FeedReportCard(
                report: r,
                onDonate: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DonateScreen(report: r, names: names),
                  ),
                ),
              ),
              Gaps.v12,
            ],
          ],
        );
      },
    );
  }
}

/// One report for donors: priority, needs, fulfillment progress and a
/// Donate button (hidden once the report is fulfilled). Critical and high
/// priority reports get a colored edge so they stand out.
class FeedReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDonate;
  final bool compact;

  const FeedReportCard({
    super.key,
    required this.report,
    required this.onDonate,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final p = r['priority_level'] as String?;
    final state = fulfillmentState(r) ?? 'Not Started';
    final fulfilled = state == 'Fulfilled';
    final highlight = !fulfilled && (p == 'Critical' || p == 'High');
    final needs = '${r['assistance_needed'] ?? ''}'
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    Widget meta(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        Gaps.h4,
        Text(text, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
    );

    final body = Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${r['disaster'] ?? 'Disaster'} in Barangay ${r['barangay'] ?? '-'}',
                  style: t.titleMedium,
                ),
              ),
              Gaps.h8,
              PriorityChip(p),
            ],
          ),
          Gaps.v8,
          Wrap(
            spacing: Space.md,
            runSpacing: Space.xxs,
            children: [
              if (r['sitio'] != null)
                meta(Icons.place_outlined, 'Sitio ${r['sitio']}'),
              if (r['affected_families'] != null)
                meta(Icons.groups_outlined, '${r['affected_families']} families'),
              StatusChip(state),
            ],
          ),
          if (!compact && '${r['description'] ?? ''}'.isNotEmpty) ...[
            Gaps.v8,
            Text(
              '${r['description']}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium,
            ),
          ],
          if (needs.isNotEmpty) ...[
            Gaps.v8,
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                for (final n in compact ? needs.take(3) : needs)
                  Chip(label: Text(n), visualDensity: VisualDensity.compact),
              ],
            ),
          ],
          Gaps.v12,
          FulfillmentBar(
            delivered: r['total_items_delivered'] as num? ?? 0,
            needed: r['total_items_needed'] as num? ?? 0,
            percent: r['fulfillment_percentage'] as num?,
          ),
          Gaps.v12,
          if (fulfilled)
            Row(
              children: [
                Icon(
                  Icons.task_alt,
                  size: 18,
                  color: StatusColors.base('Fulfilled'),
                ),
                Gaps.h8,
                Expanded(
                  child: Text(
                    'This report has received what it needs. Thank you!',
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            )
          else
            AppButton(
              'Donate to this report',
              icon: Icons.volunteer_activism_outlined,
              variant: AppButtonVariant.donate,
              expand: true,
              onPressed: onDonate,
            ),
        ],
      ),
    );

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: highlight
          ? IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(width: 5, color: PriorityColors.base(p)),
                  Expanded(child: body),
                ],
              ),
            )
          : body,
    );
  }
}
