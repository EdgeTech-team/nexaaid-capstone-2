import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'donation_entries_view.dart';
import 'expiry_widgets.dart';
import 'donor_screens.dart' show DonateScreen, ReportsFeed;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Adviser item 10 / Module 9: donor and relief organization dashboard
// (UC-D3, UC-D4, UC-R3, UC-R4; section 7.3).
//
// Ivan's note #2: the dashboard looks like the landing page, but signed in.
// A dark hero greets the donor and highlights the most urgent report, then
// the page scrolls down to the donor's own giving. Only the cards the
// manuscript asks for stay here (donation history, status of each donation,
// reports supported and their progress). Browsing every report, active and
// done, moved to the middle "Reports" tab (DonorReportsTab).
//
// Data: GET /donations/mine (profile, summary, entries, supported_reports)
// and GET /lookups (validated_reports). Donations are shown per entry (one
// QR), Appendix H 4.4 / 4.5.
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
num _percent(Map r) => r['fulfillment_percentage'] as num? ?? 0;

/// The report to highlight in the hero: still needs help (under 100%),
/// highest priority first, then the one furthest from its goal.
Map<String, dynamic>? mostUrgentReport(List<Map<String, dynamic>> reports) {
  final open = reports.where((r) => _percent(r) < 100).toList()
    ..sort((a, b) {
      final byPriority = PriorityColors.rank(
        a['priority_level'] as String?,
      ).compareTo(PriorityColors.rank(b['priority_level'] as String?));
      return byPriority != 0
          ? byPriority
          : _percent(a).compareTo(_percent(b));
    });
  return open.isEmpty ? null : open.first;
} 
class DonorDashboard extends StatefulWidget {
  const DonorDashboard({super.key});

  @override
  State<DonorDashboard> createState() => _DonorDashboardState();
}

class _DonorDashboardState extends State<DonorDashboard> {
  void _openFeed() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Reports that need help')),
        body: const ReportsFeed(done: false),
      ),
    ),
   );

  void _donate(Map<String, dynamic> report, Names names) =>
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DonateScreen(report: report, names: names),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/donations/mine'), api.lookupsResult],
      builder: (context, data) {
        final m = data[0] as Map;
        final names = Names(Map<String, dynamic>.from(data[1] as Map));
        final profile = m['profile'] as Map;
        final sum = m['summary'] as Map;
        final entries = (m['entries'] as List).cast<Map>();
        final supported = (m['supported_reports'] as List).cast<Map>();
        final isOrg = profile['organization'] != null;
        final urgent = mostUrgentReport(names.rows('validated_reports'));

        return ListView(
          padding: const EdgeInsets.only(bottom: Space.xl),
          children: [
feature/donor-dashboard-2
            _DashboardHero( 
              profile: profile,
              isOrg: isOrg,
              urgent: urgent == null
                  ? null
                  : _UrgentReportCard(
                      report: urgent,
                      onDonate: () => _donate(urgent, names),
                    ),

            _Welcome(profile: profile, isOrg: isOrg),
            const SectionHeader('Your giving'),
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
              ),
              StatCard(
                label: 'Reports supported',
                value: '${sum['supported_reports']}',
                icon: Icons.campaign_outlined,
              ),
              StatCard(
                label: 'Waiting for drop-off or pickup',
                value:
                    '${entries.where((e) => (e['pending_items'] as num) > 0).length}',
                icon: Icons.schedule,
                color: StatusColors.base('Pending'),
              ),
              StatCard(
                label: 'Received by CSWS',
                value: '${count('Received')}',
                icon: Icons.inventory_2_outlined,
                color: StatusColors.base('Received'),
              ),
              StatCard(
                label: 'Confirmed by the City',
                value: '${count('Confirmed')}',
                icon: Icons.verified_outlined,
                color: StatusColors.base('Confirmed'),
              ),
              if (count('Expired') + count('Cancelled') > 0)
                StatCard(
                  label: 'Expired or cancelled',
                  value: '${count('Expired') + count('Cancelled')}',
                  icon: Icons.timer_off_outlined,
                  color: StatusColors.base('Expired'),
                ),
            ]),

            // ---- Donations (one card per entry, 4.4 / 4.5) ------------------
            const SectionHeader(
              'Your donations',
              subtitle: 'Tap a donation to see its QR code and full timeline.',
            ),
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
                    onPressed: _openFeed,
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

            // ---- Supported reports ---------------------------------------
            const SectionHeader(
              'Reports you supported',
              subtitle: 'How close each report is to getting what it needs.',
copy-develop
            ),
            _Centered(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---- Summary: only the three the manuscript needs -----
                  const SectionHeader('Your giving'),
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
                    ),
                    StatCard(
                      label: 'Reports supported',
                      value: '${sum['supported_reports']}',
                      icon: Icons.campaign_outlined,
                    ),
                  ]),

                  // ---- Donations (one card per entry, 4.4 / 4.5) --------
                  const SectionHeader(
                    'Your donations',
                    subtitle:
                        'Tap a donation to see its QR code and full timeline.',
                  ),
                  if (entries.isEmpty)
                    AppCard(
                      child: EmptyView(
                        compact: true,
                        icon: Icons.volunteer_activism_outlined,
                        title: 'No donations yet',
                        message:
                            'Pick a report that needs help and pledge goods. '
                            'Your donations and their progress will show here.',
                        action: AppButton(
                          'Find a report to support',
                          variant: AppButtonVariant.donate,
                          onPressed: _openFeed,
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

                  // ---- Supported reports --------------------------------
                  const SectionHeader(
                    'Reports you supported',
                    subtitle: 'How close each report is to getting what it '
                        'needs.',
                  ),
                  if (supported.isEmpty)
                    const AppCard(
                      child: EmptyView(
                        compact: true,
                        icon: Icons.campaign_outlined,
                        title: 'No reports supported yet',
                        message:
                            'When you donate to a report, its progress shows '
                            'here.',
                      ),
                    ),
                  for (final r in supported) ...[
                    _ReportProgress(report: r),
                    Gaps.v12,
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

/// Same width rules as the landing page's content.
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

/// Dark hero like the landing page: greeting, account status for
/// organizations, and the most urgent report.
class _DashboardHero extends StatelessWidget {
  final Map profile;
  final bool isOrg;
  final Widget? urgent;
  const _DashboardHero({
    required this.profile,
    required this.isOrg,
    required this.urgent,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const onHero = Colors.white;
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
            Gaps.v24,
            Semantics(
              header: true,
              child: Text(
                isOrg ? '${profile['organization']}' : 'Hi, $first',
                textAlign: TextAlign.center,
                style: t.headlineMedium?.copyWith(
                  color: onHero,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Gaps.v8,
            Wrap(
              alignment: WrapAlignment.center,
              spacing: Space.xs,
              runSpacing: Space.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  isOrg
                      ? 'Relief organization'
                      : 'Thank you for helping families get back on their feet.',
                  textAlign: TextAlign.center,
                  style: t.bodyLarge?.copyWith(color: AppColors.harborMist),
                ),
                if (isOrg) StatusChip(status),
              ],
            ),
            if (pending) ...[
              Gaps.v16,
              const _Notice(
                tone: 'Pending Review',
                icon: Icons.hourglass_top,
                text:
                    'Your organization is being reviewed by the administrator. '
                    'You will be notified once it is approved.',
              ),
            ],
            Gaps.v24,
            urgent ??
                Text(
                  'No reports need help right now. Check the Reports tab '
                  'later.',
                  textAlign: TextAlign.center,
                  style: t.bodyMedium?.copyWith(color: AppColors.harborMist),
                ),
            Gaps.v24,
          ],
        ),
      ),
    );
  }
}
/// The hero's highlighted report (same look as the landing page's card).
class _UrgentReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDonate;
  const _UrgentReportCard({required this.report, required this.onDonate});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const _PulseDot(),
              Gaps.h8,
              Expanded(
                child: Text(
                  'Most urgent right now',
                  style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
              PriorityChip(r['priority_level'] as String?),
            ],
          ),
          Gaps.v12,
          Text(
            '${r['disaster'] ?? 'Disaster'} in Barangay ${r['barangay'] ?? '-'}',
            style: t.titleLarge,
          ),
          if ((r['assistance_needed'] ?? '').toString().isNotEmpty) ...[
            Gaps.v4,
            Text(
              'Needs: ${r['assistance_needed']}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          Gaps.v12,
          FulfillmentBar(
            delivered: r['total_items_delivered'] as num? ?? 0,
            needed: r['total_items_needed'] as num? ?? 0,
            percent: r['fulfillment_percentage'] as num?,
          ),
          Gaps.v16,
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
  }
}

/// Small red dot that pulses to show the card is live data.
class _PulseDot extends StatefulWidget {
  const _PulseDot();

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = PriorityColors.base('Critical');
    final dot = Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    if (MediaQuery.disableAnimationsOf(context)) return dot;
    return SizedBox(
      width: 20,
      height: 20,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: _c,
            builder: (_, _) => Container(
              width: 10 + 10 * _c.value,
              height: 10 + 10 * _c.value,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.35 * (1 - _c.value)),
              ),
            ),
          ),
          dot,
        ],
      ),
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
                row('Landmark', e['pickup_landmark']),
                row('Notes for pickup', e['pickup_notes']),
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
          // Withdraw while it is still waiting (only waiting items are
          // cancelled; anything CSWS received stays received).
          if (hasWaitingItems(e)) ...[
            Gaps.v24,
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.danger,
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: () async {
                if (await cancelDonation(context, e) && context.mounted) {
                  Navigator.pop(context);
                }
              },
              icon: const Icon(Icons.block),
              label: const Text('I can no longer give this donation'),
            ),
          ],
          Gaps.v24,
        ],
      ),
    );
  }
}
