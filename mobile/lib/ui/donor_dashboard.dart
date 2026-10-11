import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'disaster_art.dart';
import 'donation_entries_view.dart';
import 'landing/landing_extras.dart' show kImpactImage;
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
        final validated = names.rows('validated_reports');
        final urgent = mostUrgentReport(validated);

        // Other open critical / high reports, for the picture cards.
        final others = validated
            .where(
              (r) =>
                  r != urgent &&
                  _percent(r) < 100 &&
                  (r['priority_level'] == 'Critical' ||
                      r['priority_level'] == 'High'),
            )
            .toList()
          ..sort(
            (a, b) => PriorityColors.rank(a['priority_level'] as String?)
                .compareTo(PriorityColors.rank(b['priority_level'] as String?)),
          );

        // Supported reports joined with /lookups for barangay, disaster and
        // families (the /donations/mine rows only carry a label).
        final byId = {for (final r in validated) '${r['id']}': r};
        final helped = [
          for (final r in supported)
            {...r, ...?byId['${r['report_id']}'], 'label': r['label']},
        ];

        return ListView(
          padding: const EdgeInsets.only(bottom: Space.xl),
          children: [
            _DashboardHero(
              profile: profile,
              isOrg: isOrg,
              summary: sum,
              urgent: urgent == null
                  ? null
                  : _UrgentReportCard(
                      report: urgent,
                      onDonate: () => _donate(urgent, names),
                    ),
            ),
            if (others.isNotEmpty) ...[
              _Centered(
                child: SectionHeader(
                  'Critical and high priority',
                  subtitle: 'These reports need help first.',
                  action: TextButton(
                    onPressed: _openFeed,
                    child: const Text('See all'),
                  ),
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in others.take(6)) ...[
                      _PictureReportCard(
                        report: r,
                        onTap: () => _donate(r, names),
                      ),
                      Gaps.h12,
                    ],
                  ],
                ),
              ),
            ],
            _Centered(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ---- Organization: impact and where goods went -------
                  if (isOrg) ...[
                    const SectionHeader('Your organization\'s impact'),
                    _ImpactRow(summary: sum, helped: helped),
                    if (helped.isNotEmpty) ...[
                      const SectionHeader(
                        'Barangays your goods went to',
                        subtitle: 'From the reports you donated to.',
                      ),
                      _BarangayPins(helped: helped),
                    ],
                  ],

                  // ---- Status of each donation (7.3 item 2) -------------
                  const SectionHeader('Your giving'),
                  _GivingRing(entries: entries),

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
                  if (helped.isEmpty)
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
                  for (final r in helped) ...[
                    _ReportProgress(report: r),
                    Gaps.v12,
                  ],
                  if (helped.isNotEmpty) ...[
                    Gaps.v12,
                    _ThankYouStrip(helped: helped),
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

/// The relief photo, darkened so white text stays readable. Falls back to
/// the plain dark color if the image can't load.
class _HeroPhoto extends StatelessWidget {
  final double opacity;
  final Alignment alignment;
  const _HeroPhoto({this.opacity = 0.74, this.alignment = Alignment.center});

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Image.asset(
        kImpactImage,
        fit: BoxFit.cover,
        alignment: alignment,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) => const ColoredBox(color: AppColors.harborDeep),
      ),
      ColoredBox(color: AppColors.harborDeep.withValues(alpha: opacity)),
    ],
  );
}

/// Like the landing page hero, with a photo: greeting and small totals for
/// donors; cover photo, logo box and account status for organizations.
/// The most urgent report overlaps the bottom of the photo.
class _DashboardHero extends StatelessWidget {
  final Map profile;
  final Map summary;
  final bool isOrg;
  final Widget? urgent;
  const _DashboardHero({
    required this.profile,
    required this.summary,
    required this.isOrg,
    required this.urgent,
  });

  /// Up to two letters for the organization's logo box.
  static String initials(String name) {
    final words = name
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty && w[0].toUpperCase() != w[0].toLowerCase())
        .toList();
    if (words.isEmpty) return '?';
    return words.take(2).map((w) => w[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const onHero = Colors.white;
    final status = '${profile['account_status'] ?? 'Active'}';
    final pending = isOrg && status != 'Approved' && status != 'Active';
    final first = '${profile['name'] ?? ''}'.split(' ').first;
    final orgName = '${profile['organization'] ?? ''}';

    int n(String k) => (summary[k] as num?)?.toInt() ?? 0;
    Widget pill(String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: Colors.white.withValues(alpha: 0.4)),
      ),
      child: Text(
        text,
        style: t.labelLarge?.copyWith(color: onHero),
      ),
    );

    final greeting = isOrg
        ? <Widget>[
            Container(
              width: 72,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.vest,
                borderRadius: BorderRadius.circular(Radii.lg),
                border: Border.all(color: Colors.white, width: 3),
              ),
              child: Text(
                initials(orgName),
                style: t.headlineSmall?.copyWith(
                  color: AppColors.vestInk,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Gaps.v12,
            Semantics(
              header: true,
              child: Text(
                orgName,
                style: t.headlineSmall?.copyWith(
                  color: onHero,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Gaps.v4,
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xxs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  'Relief organization',
                  style: t.bodyLarge?.copyWith(color: AppColors.harborMist),
                ),
                StatusChip(status),
              ],
            ),
          ]
        : <Widget>[
            Semantics(
              header: true,
              child: Text(
                'Hi, $first',
                style: t.headlineMedium?.copyWith(
                  color: onHero,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Gaps.v4,
            Text(
              n('supported_reports') > 0
                  ? 'Thank you for helping families get back on their feet. '
                        'Here is who needs help next.'
                  : 'Thank you for being here. Here is who needs help first.',
              style: t.bodyLarge?.copyWith(color: AppColors.harborMist),
            ),
            if (n('total_entries') > 0) ...[
              Gaps.v12,
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  pill(
                    '${n('total_entries')} '
                    '${n('total_entries') == 1 ? 'donation' : 'donations'}',
                  ),
                  pill('${n('total_quantity')} items given'),
                  pill(
                    '${n('supported_reports')} '
                    '${n('supported_reports') == 1 ? 'report' : 'reports'} helped',
                  ),
                ],
              ),
            ],
          ];

    return Stack(
      children: [
        // The photo covers everything but the bottom of the urgent card.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          bottom: urgent == null ? 0 : 72,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(
              bottom: Radius.circular(Radii.xl),
            ),
            child: _HeroPhoto(
              alignment: isOrg ? const Alignment(0, -0.3) : Alignment.center,
            ),
          ),
        ),
        _Centered(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Gaps.v24,
              ...greeting,
              if (pending) ...[
                Gaps.v16,
                const _Notice(
                  tone: 'Pending Review',
                  icon: Icons.hourglass_top,
                  text:
                      'Your organization is being reviewed by the '
                      'administrator. You will be notified once it is '
                      'approved.',
                ),
              ],
              Gaps.v24,
              urgent ??
                  Text(
                    'No reports need help right now. Check the Reports tab '
                    'later.',
                    style: t.bodyMedium?.copyWith(color: AppColors.harborMist),
                  ),
              Gaps.v24,
            ],
          ),
        ),
      ],
    );
  }
}

/// The hero's highlighted report, with its disaster picture on top.
class _UrgentReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDonate;
  const _UrgentReportCard({required this.report, required this.onDonate});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final needs = '${r['assistance_needed'] ?? ''}'
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      elevation: 4,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              DisasterArt(disasterKind(r['disaster']), height: 130),
              Positioned(
                left: Space.sm,
                top: Space.sm,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _PulseDot(),
                      Gaps.h4,
                      Text(
                        'Most urgent right now',
                        style: t.labelLarge?.copyWith(
                          color: PriorityColors.base('Critical'),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Padding(
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
                        style: t.titleLarge,
                      ),
                    ),
                    Gaps.h8,
                    PriorityChip(r['priority_level'] as String?),
                  ],
                ),
                Gaps.v4,
                Text(
                  [
                    if (r['sitio'] != null) 'Sitio ${r['sitio']}',
                    if (r['affected_families'] != null)
                      '${r['affected_families']} families',
                  ].join(' · '),
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                if (needs.isNotEmpty) ...[
                  Gaps.v8,
                  Wrap(
                    spacing: Space.xs,
                    runSpacing: Space.xs,
                    children: [
                      for (final n in needs.take(4))
                        Chip(
                          label: Text(n),
                          visualDensity: VisualDensity.compact,
                        ),
                    ],
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
          ),
        ],
      ),
    );
  }
}

/// A small side-scrolling report card with its disaster picture.
class _PictureReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onTap;
  const _PictureReportCard({required this.report, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final pct = _percent(r);
    return SizedBox(
      width: 230,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DisasterArt(disasterKind(r['disaster']), height: 96),
              Padding(
                padding: const EdgeInsets.all(Space.sm),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        PriorityChip(r['priority_level'] as String?),
                        if (r['affected_families'] != null) ...[
                          Gaps.h8,
                          Flexible(
                            child: Text(
                              '${r['affected_families']} families',
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    Gaps.v8,
                    Text(
                      '${r['disaster'] ?? 'Disaster'} in Barangay ${r['barangay'] ?? '-'}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleSmall,
                    ),
                    Gaps.v8,
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Radii.pill),
                      child: LinearProgressIndicator(
                        value: (pct / 100).clamp(0, 1).toDouble(),
                        minHeight: 6,
                      ),
                    ),
                    Gaps.v4,
                    Text(
                      '${pct.round()}% delivered · Tap to donate',
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 7.3 item 2 at a glance: a ring of donations confirmed by the City, and
/// how many donations are at each status.
class _GivingRing extends StatelessWidget {
  final List<Map> entries;
  const _GivingRing({required this.entries});

  static const _labels = {
    'Pending': 'Waiting for drop-off or pickup',
    'Partly Received': 'Partly received',
    'Received': 'Received by CSWS',
    'On Hold': 'On hold by the City',
    'Confirmed': 'Confirmed by the City',
    'Expired': 'Expired',
    'Cancelled': 'Cancelled',
  };

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final total = entries.length;
    final counts = <String, int>{};
    for (final e in entries) {
      final s = '${e['status'] ?? 'Pending'}';
      counts[s] = (counts[s] ?? 0) + 1;
    }
    final confirmed = counts['Confirmed'] ?? 0;
    final rows = [
      for (final s in const ['Pending', 'Received', 'Confirmed']) s,
      for (final s in counts.keys)
        if (!const ['Pending', 'Received', 'Confirmed'].contains(s)) s,
    ];

    return AppCard(
      child: Row(
        children: [
          Semantics(
            label: '$confirmed of $total donations confirmed by the City',
            child: SizedBox(
              width: 96,
              height: 96,
              child: CustomPaint(
                painter: _RingPainter(
                  fraction: total == 0 ? 0 : confirmed / total,
                  track: cs.surfaceContainerHighest,
                  color: StatusColors.base('Confirmed'),
                ),
                child: Center(
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('$confirmed/$total', style: t.titleLarge),
                        Text(
                          'confirmed',
                          style: t.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Gaps.h16,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final s in rows)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: StatusColors.base(s),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Gaps.h8,
                        Expanded(
                          child: Text(_labels[s] ?? s, style: t.bodyMedium),
                        ),
                        Text(
                          '${counts[s] ?? 0}',
                          style: t.titleSmall,
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fraction;
  final Color track;
  final Color color;
  const _RingPainter({
    required this.fraction,
    required this.track,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 6.283185, false, p..color = track);
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        -1.570796,
        6.283185 * fraction.clamp(0, 1).toDouble(),
        false,
        p..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.track != track || old.color != color;
}

/// Organizations: items given, barangays reached and families in the
/// reports they donated to. All three come from data the app already has.
class _ImpactRow extends StatelessWidget {
  final Map summary;
  final List<Map> helped;
  const _ImpactRow({required this.summary, required this.helped});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final b = Theme.of(context).brightness;
    final barangays = {for (final r in helped) _barangayOf(r)};
    final families = helped.fold<int>(
      0,
      (n, r) => n + ((r['affected_families'] as num?)?.toInt() ?? 0),
    );

    Widget tile(IconData icon, String tone, String value, String label) {
      final s = StatusColors.of(tone, b);
      return Expanded(
        child: AppCard(
          padding: const EdgeInsets.all(Space.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: s.bg,
                child: Icon(icon, size: 18, color: s.fg),
              ),
              Gaps.v8,
              Text(value, style: t.headlineSmall),
              Text(
                label,
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tile(
          Icons.inventory_2_outlined,
          'Confirmed',
          '${summary['total_quantity'] ?? 0}',
          'items given',
        ),
        Gaps.h8,
        tile(
          Icons.location_on_outlined,
          'Preparing',
          '${barangays.length}',
          barangays.length == 1 ? 'barangay reached' : 'barangays reached',
        ),
        Gaps.h8,
        tile(
          Icons.groups_outlined,
          'Received',
          '$families',
          'families in reports you support',
        ),
      ],
    );
  }
}

/// "Flood in Banilad" -> "Banilad", or the joined /lookups barangay.
String _barangayOf(Map r) {
  final b = r['barangay'];
  if (b != null) return '$b';
  final parts = '${r['label'] ?? ''}'.split(' in ');
  return parts.length > 1 ? parts.last : '${r['label'] ?? '-'}';
}

/// Organizations: one pin per barangay their goods went to, colored by how
/// that barangay's report is doing. Barangays have no map coordinates in
/// the database, so this is a list of pins, not a map.
class _BarangayPins extends StatelessWidget {
  final List<Map> helped;
  const _BarangayPins({required this.helped});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    Color colorOf(Map r) {
      if (_percent(r) >= 100) return StatusColors.base('Fulfilled');
      if (r['priority_level'] == 'Critical') {
        return PriorityColors.base('Critical');
      }
      return cs.primary;
    }

    // One pin per barangay: keep its least fulfilled report.
    final byBarangay = <String, Map>{};
    for (final r in helped) {
      final k = _barangayOf(r);
      final old = byBarangay[k];
      if (old == null || _percent(r) < _percent(old)) byBarangay[k] = r;
    }

    Widget legend(Color c, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.location_on, size: 16, color: c),
        Gaps.h4,
        Text(text, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
      ],
    );

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final e in byBarangay.entries)
                Container(
                  padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.location_on, size: 20, color: colorOf(e.value)),
                      Gaps.h4,
                      Text(e.key, style: t.labelLarge),
                      Gaps.h8,
                      Text(
                        '${_percent(e.value).round()}%',
                        style: t.labelLarge?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          Gaps.v12,
          Wrap(
            spacing: Space.md,
            runSpacing: Space.xxs,
            children: [
              legend(PriorityColors.base('Critical'), 'Still critical'),
              legend(cs.primary, 'In progress'),
              legend(StatusColors.base('Fulfilled'), 'Fulfilled'),
            ],
          ),
        ],
      ),
    );
  }
}

/// Photo strip that thanks the donor with a real report they helped.
class _ThankYouStrip extends StatelessWidget {
  final List<Map> helped;
  const _ThankYouStrip({required this.helped});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    // The supported report furthest along, so the message is about progress.
    final r = (helped.toList()
          ..sort((a, b) => _percent(b).compareTo(_percent(a))))
        .first;
    final families = r['affected_families'];
    final where = 'Barangay ${_barangayOf(r)}';
    final pct = _percent(r).round();
    final headline = pct >= 100
        ? '$where got everything it needed.'
        : families != null
        ? '$families families in $where are getting help.'
        : '$where is $pct% supplied.';

    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.lg),
      child: SizedBox(
        height: 140,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const _HeroPhoto(opacity: 0.66, alignment: Alignment(-0.4, 0.2)),
            Padding(
              padding: const EdgeInsets.all(Space.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    headline,
                    style: t.titleMedium?.copyWith(color: Colors.white),
                  ),
                  Gaps.v4,
                  Text(
                    'Part of it came from you. Thank you.',
                    style: t.bodyMedium?.copyWith(color: AppColors.harborMist),
                  ),
                ],
              ),
            ),
          ],
        ),
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
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DisasterArt(
            disasterKindOfLabel(r['label']),
            width: 52,
            height: 52,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          Gaps.h12,
          Expanded(
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