import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'donation_entries_view.dart';
import 'donor_screens.dart' show DonateScreen, ReportsFeed;
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
        body: const ReportsFeed(),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [() => api.get('/donations/mine'), api.lookupsResult],
      builder: (context, data) {
        final m = data[0] as Map;
        final lookups = Map<String, dynamic>.from(data[1] as Map);
        final names = Names(lookups);
        final profile = m['profile'] as Map;
        final sum = m['summary'] as Map;
        final entries = (m['entries'] as List).cast<Map>();
        final supported = (m['supported_reports'] as List).cast<Map>();
        final isOrg = profile['organization'] != null;

        final needHelp = names.rows('validated_reports').cast<Map>().toList()
          ..sort(
            (a, b) => PriorityColors.rank(a['priority_level'] as String?)
                .compareTo(PriorityColors.rank(b['priority_level'] as String?)),
          );

        int count(String s) => entries.where((e) => e['status'] == s).length;

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            Space.md,
            Space.md,
            Space.md,
            Space.xl,
          ),
          children: [
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

            // ---- Reports that need help ----------------------------------
            if (needHelp.isNotEmpty) ...[
              SectionHeader(
                'Reports that need help now',
                subtitle: 'Most urgent first.',
                action: TextButton(
                  onPressed: _openFeed,
                  child: const Text('See all'),
                ),
              ),
              for (final r in needHelp.take(3)) ...[
                AppCard(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${r['disaster']} in Barangay ${r['barangay']}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Gaps.v4,
                            PriorityChip(r['priority_level'] as String?),
                          ],
                        ),
                      ),
                      Gaps.h8,
                      AppButton(
                        'Donate',
                        variant: AppButtonVariant.donate,
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => DonateScreen(
                              report: Map<String, dynamic>.from(r),
                              names: names,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Gaps.v8,
              ],
            ],
          ],
        );
      },
    );
  }
}

class _Welcome extends StatelessWidget {
  final Map profile;
  final bool isOrg;
  const _Welcome({required this.profile, required this.isOrg});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final status = '${profile['account_status'] ?? 'Active'}';
    final pending = isOrg && status != 'Approved' && status != 'Active';
    final first = '${profile['name'] ?? ''}'.split(' ').first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          isOrg ? '${profile['organization']}' : 'Hi, $first',
          style: t.headlineSmall,
        ),
        Gaps.v4,
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xxs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              isOrg ? 'Relief organization' : 'Donor',
              style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (isOrg) StatusChip(status),
          ],
        ),
        if (pending) ...[
          Gaps.v12,
          _Notice(
            tone: 'Pending Review',
            icon: Icons.hourglass_top,
            text:
                'Your organization is being reviewed by the administrator. '
                'You will be notified once it is approved.',
          ),
        ],
      ],
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
