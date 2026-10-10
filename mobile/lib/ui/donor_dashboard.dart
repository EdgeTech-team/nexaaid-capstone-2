import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'donation_entries_view.dart';
import 'donor_screens.dart' show DonateScreen, FeedReportCard;
import 'report_filters.dart';
import 'shell_tabs.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Adviser item 10 / Module 9: donor and relief organization dashboard
// (UC-D3, UC-D4, UC-R3, UC-R4).
//
// Data: GET /donations/mine (profile, summary, entries, supported_reports).
// Donations are shown per entry (one QR), Appendix H 4.4 / 4.5.
//
// Timeline note: a donation's own status goes Pending -> Received ->
// Confirmed. The last three steps (In transit, Delivered, Acknowledged)
// happen on the delivery. Once the backend returns them for each donation
// (Hoyohoy: e.g. a "lifecycle_status" field and per-step dates), use those
// in _lifecycleStatus and _stepDates below; nothing else needs to change.
// ---------------------------------------------------------------------------

/// The step to show on the timeline for a donation entry. A Partly
/// Received entry still has goods waiting, so it stays on the first step.
String _lifecycleStatus(Map d) {
  final s = '${d['lifecycle_status'] ?? d['status'] ?? 'Pending'}';
  return s == 'Partly Received' ? 'Pending' : s;
}

/// Known dates per step, already formatted, for the detail timeline.
Map<String, String> _stepDates(Map d) => {
  if (d['created_at'] != null) 'Pending': niceDate(d['created_at']),
  if (d['step_dates'] is Map)
    for (final e in (d['step_dates'] as Map).entries)
      if (e.value != null) '${e.key}': niceDate(e.value),
};

/// Loads what both donor tabs need: GET /donations/mine and /lookups.
List<Future<ApiResult> Function()> _donorLoad() => [
  () => api.get('/donations/mine'),
  api.lookupsResult,
];

/// Validated reports that still need help, most urgent first.
List<Map<String, dynamic>> _openReports(Names names) => sortAndFilterReports(
  names
      .rows('validated_reports')
      .where((r) => fulfillmentState(r) != 'Fulfilled'),
);

void _donate(BuildContext context, Map<String, dynamic> r, Names names) =>
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DonateScreen(report: r, names: names)),
    );

// ---------------------------------------------------------------------------
// Home tab (7.3, UC-D4 / UC-R4): the landing page, signed in. The most
// urgent report up top, critical and high priority reports highlighted,
// active reports by priority, then a short summary of the donor's own
// donations and supported reports. The full donation list is in the
// Donations tab; every report is in the Reports tab.
// ---------------------------------------------------------------------------
class DonorDashboard extends StatelessWidget {
  const DonorDashboard({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: _donorLoad(),
      builder: (context, data) {
        final m = data[0] as Map;
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        final profile = m['profile'] as Map;
        final sum = m['summary'] as Map;
        final entries = (m['entries'] as List).cast<Map>();
        final supported = (m['supported_reports'] as List).cast<Map>();
        final isOrg = profile['organization'] != null;

        final open = _openReports(names);
        final top = open.isEmpty ? null : open.first;
        final urgent = open
            .skip(1)
            .where(
              (r) =>
                  r['priority_level'] == 'Critical' ||
                  r['priority_level'] == 'High',
            )
            .take(3)
            .toList();
        final waiting = entries
            .where((e) => ((e['pending_items'] as num?) ?? 0) > 0)
            .length;
        final confirmed = entries
            .where((e) => e['status'] == 'Confirmed')
            .length;

        return ListView(
          padding: const EdgeInsets.only(bottom: Space.xl),
          children: [
            _HomeHero(
              profile: profile,
              isOrg: isOrg,
              urgent: top == null
                  ? null
                  : FeedReportCard(
                      report: top,
                      compact: true,
                      onDonate: () => _donate(context, top, names),
                    ),
            ),
            _Centered(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionHeader(
                    'Critical and high priority',
                    subtitle: 'These reports need help first.',
                    action: TextButton(
                      onPressed: () => ShellTabs.open('Reports'),
                      child: const Text('See all'),
                    ),
                  ),
                  if (urgent.isEmpty)
                    const AppCard(
                      child: EmptyView(
                        compact: true,
                        icon: Icons.verified_outlined,
                        title: 'No other critical or high priority reports',
                        message: 'Check All reports for other ways to help.',
                      ),
                    ),
                  for (final r in urgent) ...[
                    FeedReportCard(
                      report: r,
                      compact: true,
                      onDonate: () => _donate(context, r, names),
                    ),
                    Gaps.v12,
                  ],
                  const SectionHeader(
                    'Active reports by priority',
                    subtitle: 'Tap a level to see its reports.',
                  ),
                  _PriorityCounts(open: open),
                  SectionHeader(
                    'Your donations',
                    action: TextButton(
                      onPressed: () => ShellTabs.open('Donations'),
                      child: const Text('View all'),
                    ),
                  ),
                  _GivingSummary(
                    total: (sum['total_entries'] as num?)?.toInt() ?? 0,
                    waiting: waiting,
                    confirmed: confirmed,
                  ),
                  if (supported.isNotEmpty) ...[
                    SectionHeader(
                      'Reports you supported',
                      action: supported.length > 2
                          ? TextButton(
                              onPressed: () => ShellTabs.open('Donations'),
                              child: const Text('See all'),
                            )
                          : null,
                    ),
                    for (final r in supported.take(2)) ...[
                      _ReportProgress(report: r),
                      Gaps.v12,
                    ],
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Keeps reading content at a comfortable width on tablets and Chrome.
class _Centered extends StatelessWidget {
  final Widget child;
  const _Centered({required this.child});

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: Breakpoints.contentMax),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
        child: child,
      ),
    ),
  );
}

/// Same look as the landing page hero: greeting, account status, and the
/// single most urgent report.
class _HomeHero extends StatelessWidget {
  final Map profile;
  final bool isOrg;
  final Widget? urgent;
  const _HomeHero({
    required this.profile,
    required this.isOrg,
    required this.urgent,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final status = '${profile['account_status'] ?? 'Active'}';
    final pending = isOrg && status != 'Approved' && status != 'Active';
    final first = '${profile['name'] ?? ''}'.split(' ').first;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.harborDeep,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(Radii.xl)),
      ),
      child: _Centered(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Gaps.v16,
            Text(
              isOrg ? '${profile['organization']}' : 'Hi, $first',
              style: t.headlineSmall?.copyWith(color: Colors.white),
            ),
            Gaps.v4,
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  isOrg ? 'Relief organization' : 'Donor',
                  style: t.bodyMedium?.copyWith(color: AppColors.harborMist),
                ),
                if (isOrg) StatusChip(status),
              ],
            ),
            if (pending) ...[
              Gaps.v12,
              const _Notice(
                tone: 'Pending Review',
                icon: Icons.hourglass_top,
                text:
                    'Your organization is being reviewed by the administrator. '
                    'You will be notified once it is approved.',
              ),
            ],
            Gaps.v12,
            Text(
              'Here is where help is needed most in Mandaue right now.',
              style: t.bodyLarge?.copyWith(color: AppColors.harborMist),
            ),
            Gaps.v16,
            if (urgent != null)
              urgent!
            else
              const AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.verified_outlined,
                  title: 'No reports need help right now',
                  message:
                      'When the City validates a disaster report, it shows '
                      'up here.',
                ),
              ),
            Gaps.v24,
          ],
        ),
      ),
    );
  }
}

/// 7.3 (5) active reports and their priority levels: one tile per level.
class _PriorityCounts extends StatelessWidget {
  final List<Map<String, dynamic>> open;
  const _PriorityCounts({required this.open});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final b = Theme.of(context).brightness;
    return Row(
      children: [
        for (final (i, level) in PriorityColors.levels.indexed) ...[
          if (i > 0) Gaps.h8,
          Expanded(
            child: AppCard(
              padding: const EdgeInsets.symmetric(
                vertical: Space.sm,
                horizontal: Space.xs,
              ),
              color: PriorityColors.of(level, b).bg,
              onTap: () => ShellTabs.open('Reports'),
              child: Column(
                children: [
                  Text(
                    '${open.where((r) => r['priority_level'] == level).length}',
                    style: t.headlineSmall?.copyWith(
                      color: PriorityColors.of(level, b).fg,
                    ),
                  ),
                  Text(
                    level,
                    style: t.labelMedium?.copyWith(
                      color: PriorityColors.of(level, b).fg,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 7.3 (1, 2): donation history and status in one small card.
class _GivingSummary extends StatelessWidget {
  final int total;
  final int waiting;
  final int confirmed;
  const _GivingSummary({
    required this.total,
    required this.waiting,
    required this.confirmed,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    Widget cell(String value, String label, Color color) => Expanded(
      child: Column(
        children: [
          Text(value, style: t.headlineSmall?.copyWith(color: color)),
          Text(
            label,
            textAlign: TextAlign.center,
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
    return AppCard(
      onTap: () => ShellTabs.open('Donations'),
      child: total == 0
          ? Row(
              children: [
                Icon(Icons.volunteer_activism_outlined, color: cs.primary),
                Gaps.h12,
                Expanded(
                  child: Text(
                    'No donations yet. Pick a report above to make your '
                    'first one.',
                    style: t.bodyMedium,
                  ),
                ),
              ],
            )
          : Row(
              children: [
                cell('$total', 'Donations made', cs.primary),
                cell(
                  '$waiting',
                  'Waiting for drop-off or pickup',
                  StatusColors.base('Pending'),
                ),
                cell(
                  '$confirmed',
                  'Confirmed by the City',
                  StatusColors.base('Confirmed'),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Donations tab (UC-D3 / UC-R3 monitoring): a few summary cards, every
// donation entry (tap for its QR and timeline) and supported reports.
// ---------------------------------------------------------------------------
class MyDonationsScreen extends StatelessWidget {
  const MyDonationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Loader(
      load: _donorLoad(),
      builder: (context, data) {
        final m = data[0] as Map;
        final sum = m['summary'] as Map;
        final entries = (m['entries'] as List).cast<Map>();
        final supported = (m['supported_reports'] as List).cast<Map>();

        return ListView(
          padding: Space.page,
          children: [
            Text('My donations', style: t.headlineSmall),
            Gaps.v4,
            Text(
              'Tap a donation to see its QR code and full timeline.',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v16,
            StatCardGrid([
              StatCard(
                label: 'Donations made',
                value: '${sum['total_entries']}',
                icon: Icons.volunteer_activism_outlined,
              ),
              StatCard(
                label: 'Items given',
                value: '${sum['total_quantity']}',
                icon: Icons.inventory_outlined,
                color: StatusColors.base('Received'),
              ),
            ]),
            Gaps.v16,
            if (entries.isEmpty)
              AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.volunteer_activism_outlined,
                  title: 'No donations yet',
                  message:
                      'Pick a report that needs help and pledge goods. Your '
                      'donations and their progress will show here.',
                  action: AppButton(
                    'Find a report to support',
                    variant: AppButtonVariant.donate,
                    onPressed: () => ShellTabs.open('Reports'),
                  ),
                ),
              )
            else
              DonationEntriesView(
                entries: entries,
                footer: (e) => StatusTimeline(
                  steps: donationLifecycle,
                  labels: donationLifecycleLabels,
                  current: _lifecycleStatus(e),
                ),
                onTap: (e) => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => DonationDetailScreen(entry: e),
                  ),
                ),
              ),
            SectionHeader(
              'Reports you supported (${supported.length})',
              subtitle: 'How close each report is to getting what it needs.',
            ),
            if (supported.isEmpty)
              const AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.campaign_outlined,
                  title: 'No reports supported yet',
                  message:
                      'When you donate to a report, its progress shows here.',
                ),
              ),
            for (final r in supported) ...[
              _ReportProgress(report: r),
              Gaps.v12,
            ],
          ],
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  final String tone;
  final IconData icon;
  final String text;
  const _Notice({required this.tone, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final s = StatusColors.of(tone, Theme.of(context).brightness);
    return Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: s.bg,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: s.fg, size: 20),
          Gaps.h12,
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: s.fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportProgress extends StatelessWidget {
  final Map report;
  const _ReportProgress({required this.report});

  @override
  Widget build(BuildContext context) {
    final r = report;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  '${r['label']}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              Gaps.h8,
              PriorityChip(r['priority_level'] as String?),
            ],
          ),
          Gaps.v12,
          FulfillmentBar(
            delivered: r['total_items_delivered'] as num? ?? 0,
            needed: r['total_items_needed'] as num? ?? 0,
            percent: r['fulfillment_percentage'] as num?,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// One donation entry: its QR code (shared by every item), the items, and the
// full timeline with dates.
// ---------------------------------------------------------------------------
class DonationDetailScreen extends StatefulWidget {
  final Map entry;
  const DonationDetailScreen({super.key, required this.entry});

  @override
  State<DonationDetailScreen> createState() => _DonationDetailScreenState();
}

class _DonationDetailScreenState extends State<DonationDetailScreen> {
  late final Future<ApiResult> _qr = api.get(
    '/donations/batch/${widget.entry['batch_reference']}/qr',
  );

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    final report = e['report'] as Map?;

    Widget row(String label, Object? value) => value == null || '$value'.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: Space.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 120, child: Text(label, style: muted)),
                Expanded(child: Text('$value', style: t.bodyMedium)),
              ],
            ),
          );

    return Scaffold(
      appBar: AppBar(title: Text('${e['batch_reference'] ?? 'Donation'}')),
      body: ListView(
        padding: Space.page,
        children: [
          DonationEntryCard(entry: e),
          const SectionHeader('Progress'),
          AppCard(
            child: StatusTimeline(
              steps: donationLifecycle,
              labels: donationLifecycleLabels,
              current: _lifecycleStatus(e),
              axis: Axis.vertical,
              dates: _stepDates(e),
            ),
          ),
          const SectionHeader(
            'QR code',
            subtitle:
                'Show this at the CSWS Main Office when you drop off, or to '
                'the person who picks up your donation.',
          ),
          AppCard(
            child: FutureBuilder<ApiResult>(
              future: _qr,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: Skeleton(width: 220, height: 220));
                }
                final r = snap.data!;
                final b64 = r.ok && r.json is Map
                    ? (r.json as Map)['qr_image_base64'] as String?
                    : null;
                if (b64 == null) {
                  return Text(
                    'The QR code couldn\'t load. Your reference is '
                    '${e['batch_reference']}.',
                    style: muted,
                  );
                }
                return Center(
                  child: Semantics(
                    label: 'QR code for ${e['batch_reference']}',
                    child: Container(
                      padding: const EdgeInsets.all(Space.sm),
                      color: Colors.white, // QR needs a white background
                      child: Image.memory(
                        base64Decode(b64),
                        width: 220,
                        height: 220,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SectionHeader('Details'),
          AppCard(
            child: Column(
              children: [
                row('Reference', e['batch_reference']),
                row('Handover', e['handover_method']),
                row('Pickup address', e['pickup_address']),
                row('Notes for pickup', e['pickup_landmark']),
                if (e['preferred_pickup_at'] != null)
                  row('Preferred pickup', niceDate(e['preferred_pickup_at'])),
                row('Pledged on', niceDate(e['created_at'])),
                row('For report', report?['label']),
              ],
            ),
          ),
          if (report != null) ...[
            const SectionHeader('Report progress'),
            _ReportProgress(report: report),
          ],
          Gaps.v24,
        ],
      ),
    );
  }
}
