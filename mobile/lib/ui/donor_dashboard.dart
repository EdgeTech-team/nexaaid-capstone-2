import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'donor_screens.dart' show DonateScreen, ReportsFeed;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Adviser item 10 / Module 9: donor and relief organization dashboard
// (UC-D3, UC-D4, UC-R3, UC-R4).
//
// Data: GET /donations/mine (profile, summary, donations, supported_reports).
//
// Timeline note: a donation's own status goes Pending -> Received ->
// Confirmed. The last three steps (In transit, Delivered, Acknowledged)
// happen on the delivery. Once the backend returns them for each donation
// (Hoyohoy: e.g. a "lifecycle_status" field and per-step dates), use those
// in _lifecycleStatus and _stepDates below; nothing else needs to change.
// ---------------------------------------------------------------------------

/// The step to show on the timeline for a donation.
String _lifecycleStatus(Map d) =>
    '${d['lifecycle_status'] ?? d['status'] ?? 'Pending'}';

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
  String? _filter; // null = all

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
        final donations = (m['donations'] as List).cast<Map>();
        final supported = (m['supported_reports'] as List).cast<Map>();
        final isOrg = profile['organization'] != null;

        final needHelp =
            names.rows('validated_reports').cast<Map>().toList()..sort(
              (a, b) =>
                  PriorityColors.rank(
                    a['priority_level'] as String?,
                  ).compareTo(
                    PriorityColors.rank(b['priority_level'] as String?),
                  ),
            );

        const statuses = ['Pending', 'Received', 'Confirmed'];
        int count(String s) => donations.where((d) => d['status'] == s).length;
        final shown = donations
            .where((d) => _filter == null || d['status'] == _filter)
            .toList();

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
                value: '${sum['total_donations']}',
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
                value: '${sum['pending']}',
                icon: Icons.schedule,
                color: StatusColors.base('Pending'),
              ),
              StatCard(
                label: 'Received by CSWS',
                value: '${sum['received']}',
                icon: Icons.inventory_2_outlined,
                color: StatusColors.base('Received'),
              ),
              StatCard(
                label: 'Confirmed by the City',
                value: '${sum['confirmed']}',
                icon: Icons.verified_outlined,
                color: StatusColors.base('Confirmed'),
              ),
            ]),

            // ---- Donations ------------------------------------------------
            const SectionHeader(
              'Your donations',
              subtitle: 'Tap a donation to see its QR code and full timeline.',
            ),
            if (donations.isEmpty)
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
            else ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final s in <String?>[null, ...statuses])
                      Padding(
                        padding: const EdgeInsets.only(right: Space.xs),
                        child: ChoiceChip(
                          label: Text(
                            s == null
                                ? 'All (${donations.length})'
                                : '$s (${count(s)})',
                          ),
                          selected: _filter == s,
                          onSelected: (_) => setState(() => _filter = s),
                        ),
                      ),
                  ],
                ),
              ),
              Gaps.v12,
              if (shown.isEmpty)
                AppCard(
                  child: EmptyView(
                    compact: true,
                    icon: Icons.filter_alt_off_outlined,
                    title: 'No ${_filter?.toLowerCase()} donations',
                    message: 'Choose another status to see more.',
                  ),
                ),
              for (final d in shown) ...[
                _DonationCard(
                  donation: d,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => DonationDetailScreen(donation: d),
                    ),
                  ),
                ),
                Gaps.v12,
              ],
            ],

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
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: s.fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _DonationCard extends StatelessWidget {
  final Map donation;
  final VoidCallback onTap;
  const _DonationCard({required this.donation, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final d = donation;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final report = d['report'] as Map?;
    return AppCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${d['quantity']} ${d['unit'] ?? ''} ${d['item_name']}'
                          .replaceAll(RegExp(r'\s+'), ' '),
                      style: t.titleMedium,
                    ),
                    if (report != null)
                      Text('For ${report['label']}', style: muted),
                  ],
                ),
              ),
              Gaps.h8,
              StatusChip('${d['status']}'),
            ],
          ),
          Gaps.v8,
          Wrap(
            spacing: Space.md,
            runSpacing: Space.xxs,
            children: [
              _Meta(Icons.qr_code_2, '${d['qr_reference']}'),
              _Meta(Icons.local_shipping_outlined, '${d['handover_method']}'),
              _Meta(Icons.event_outlined, niceDate(d['created_at'])),
            ],
          ),
          Gaps.v16,
          StatusTimeline(
            steps: donationLifecycle,
            labels: donationLifecycleLabels,
            current: _lifecycleStatus(d),
          ),
        ],
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final IconData icon;
  final String text;
  const _Meta(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        Gaps.h4,
        Flexible(
          child: Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
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
// One donation: QR code, details and the full timeline with dates.
// ---------------------------------------------------------------------------
class DonationDetailScreen extends StatefulWidget {
  final Map donation;
  const DonationDetailScreen({super.key, required this.donation});

  @override
  State<DonationDetailScreen> createState() => _DonationDetailScreenState();
}

class _DonationDetailScreenState extends State<DonationDetailScreen> {
  late final Future<ApiResult> _qr = api.get(
    '/donations/${widget.donation['donation_id']}/qr',
  );

  @override
  Widget build(BuildContext context) {
    final d = widget.donation;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    final report = d['report'] as Map?;

    Widget row(String label, Object? value) => value == null ||
            '$value'.isEmpty
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
      appBar: AppBar(title: Text('${d['qr_reference'] ?? 'Donation'}')),
      body: ListView(
        padding: Space.page,
        children: [
          AppCard(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${d['quantity']} ${d['unit'] ?? ''} ${d['item_name']}'
                        .replaceAll(RegExp(r'\s+'), ' '),
                    style: t.titleLarge,
                  ),
                ),
                Gaps.h8,
                StatusChip('${d['status']}'),
              ],
            ),
          ),
          const SectionHeader('Progress'),
          AppCard(
            child: StatusTimeline(
              steps: donationLifecycle,
              labels: donationLifecycleLabels,
              current: _lifecycleStatus(d),
              axis: Axis.vertical,
              dates: _stepDates(d),
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
                  return const Center(
                    child: Skeleton(width: 220, height: 220),
                  );
                }
                final r = snap.data!;
                final b64 = r.ok && r.json is Map
                    ? (r.json as Map)['qr_image_base64'] as String?
                    : null;
                if (b64 == null) {
                  return Text(
                    'The QR code couldn\'t load. Your reference is '
                    '${d['qr_reference']}.',
                    style: muted,
                  );
                }
                return Center(
                  child: Semantics(
                    label: 'QR code for ${d['qr_reference']}',
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
                row('Reference', d['qr_reference']),
                row('Packaging', d['packaging']),
                row('Handover', d['handover_method']),
                row('Pickup address', d['pickup_address']),
                row('Pledged on', niceDate(d['created_at'])),
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