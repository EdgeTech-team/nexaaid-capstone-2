import 'package:flutter/material.dart';

import 'disaster_art.dart';
import 'landing/landing_extras.dart' show kImpactImage;
import 'landing/public_data.dart' show kDemoData;
import 'notifications_screen.dart' show showReportSheet;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Ivan (donor Dashboard, from the canvas): a short newsfeed under the
// barangay box, newest first. Every post is real data the app already has:
//   - New validated report    /lookups validated_reports (created_at)
//   - Goods arrived           /public/recent-deliveries (barangay confirmed)
//   - You helped finish one   /donations/mine supported_reports at 100%
//   - Right now in Mandaue    /public/stats
// No likes, comments or other donors' names: there is no data for them.
// The donor's own donation status is not here: it stays in the Reports tab.
// ---------------------------------------------------------------------------

/// "Just now", "2h", "Yesterday", "3 days ago", or the date.
String timeAgo(Object? iso, {DateTime? now}) {
  final t = DateTime.tryParse('${iso ?? ''}');
  if (t == null) return '';
  final d = (now ?? DateTime.now()).difference(t.toLocal());
  if (d.inMinutes < 1) return 'Just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  if (d.inDays == 1) return 'Yesterday';
  if (d.inDays < 7) return '${d.inDays} days ago';
  return niceDate(iso);
}

/// One post: its time (for newest-first order) and its card.
typedef _Post = (DateTime?, Widget);

class DonorFeed extends StatefulWidget {
  final List<Map<String, dynamic>> validated;
  final List<Map> supported;
  final String donateLabel;
  final void Function(Map<String, dynamic> report) onDonate;

  const DonorFeed({
    super.key,
    required this.validated,
    required this.supported,
    required this.donateLabel,
    required this.onDonate,
  });

  @override
  State<DonorFeed> createState() => _DonorFeedState();
}

class _DonorFeedState extends State<DonorFeed> {
  // Public data loads on its own, so a slow or failed call never blocks the
  // dashboard; those posts just don't appear.
  late final Future<List<Map>> _arrived = _list('/public/recent-deliveries');
  late final Future<Map?> _stats = _map('/public/stats');

  Future<List<Map>> _list(String path) async {
    final r = await api.get(path);
    return r.ok && r.json is List ? (r.json as List).cast<Map>() : const [];
  }

  Future<Map?> _map(String path) async {
    final r = await api.get(path);
    return r.ok && r.json is Map ? r.json as Map : null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Object?>>(
      future: Future.wait<Object?>([_arrived, _stats]),
      builder: (context, snap) {
        final arrived = (snap.data?[0] as List<Map>?) ?? const <Map>[];
        final stats = snap.data?[1] as Map?;
        final posts = _posts(arrived);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final p in posts) ...[p.$2, Gaps.v12],
            if (stats != null) MandaueNowPost(stats: stats),
          ],
        );
      },
    );
  }

  List<_Post> _posts(List<Map> arrived) {
    DateTime? at(Object? iso) => DateTime.tryParse('${iso ?? ''}');
    final dated = <_Post>[
      // The 2 newest validated reports that still need help.
      for (final r
          in (widget.validated
                  .where(
                    (r) =>
                        ((r['fulfillment_percentage'] as num?) ?? 0) < 100,
                  )
                  .toList()
                ..sort(
                  (a, b) => (at(b['created_at']) ?? DateTime(0)).compareTo(
                    at(a['created_at']) ?? DateTime(0),
                  ),
                ))
              .take(2))
        (
          at(r['created_at']),
          ReportPost(
            report: r,
            donateLabel: widget.donateLabel,
            onDonate: () => widget.onDonate(r),
          ),
        ),
      // Goods the barangays confirmed (latest 3).
      for (final d in arrived.take(3))
        (
          at(d['confirmed_at']),
          ArrivedPost(delivery: d, reports: widget.validated),
        ),
    ]..sort((a, b) => (b.$1 ?? DateTime(0)).compareTo(a.$1 ?? DateTime(0)));

    return [
      ...dated,
      // Reports this donor helped finish (no date, so after the rest).
      for (final r in widget.supported.where(
        (r) => ((r['fulfillment_percentage'] as num?) ?? 0) >= 100,
      ))
        (null, FinishedPost(report: r)),
    ];
  }
}

// ---------------------------------------------------------------------------
// The posts. Each one is a white card: a header (who and when), a sentence,
// sometimes a picture, and at most two actions.
// ---------------------------------------------------------------------------

class _PostHeader extends StatelessWidget {
  final Widget avatar;
  final String title;
  final String subtitle;
  final Widget? trailing;
  const _PostHeader({
    required this.avatar,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, Space.xs),
      child: Row(
        children: [
          avatar,
          Gaps.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleSmall),
                if (subtitle.isNotEmpty)
                  Text(
                    subtitle,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// A round avatar: an icon on a tint, or short text (e.g. "CSWS").
class _Avatar extends StatelessWidget {
  final IconData? icon;
  final String? text;
  final String tone; // a StatusColors name
  const _Avatar({this.icon, this.text, required this.tone});

  @override
  Widget build(BuildContext context) {
    final s = StatusColors.of(tone, Theme.of(context).brightness);
    return CircleAvatar(
      radius: 20,
      backgroundColor: text != null ? AppColors.harbor : s.bg,
      child: text != null
          ? Text(
              text!,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            )
          : Icon(icon, size: 20, color: s.fg),
    );
  }
}

Widget _postCard(List<Widget> children) => Card(
  margin: EdgeInsets.zero,
  clipBehavior: Clip.antiAlias,
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: children,
  ),
);

/// New validated report: picture, needs, progress, Donate and Details.
class ReportPost extends StatelessWidget {
  final Map<String, dynamic> report;
  final String donateLabel;
  final VoidCallback onDonate;
  const ReportPost({
    super.key,
    required this.report,
    required this.donateLabel,
    required this.onDonate,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = report;
    final families = r['affected_families'];
    final sitio = r['sitio'];
    final needs = '${r['assistance_needed'] ?? ''}'.trim();
    final who = [
      if (families != null) '$families families',
      if (sitio != null) 'in Sitio $sitio',
    ].join(' ');
    return _postCard([
      _PostHeader(
        avatar: const _Avatar(text: 'CSWS', tone: 'Validated'),
        title: 'CSWS Disaster Unit',
        subtitle: [
          'New validated report',
          if (timeAgo(r['created_at']).isNotEmpty) timeAgo(r['created_at']),
        ].join(' · '),
        trailing: PriorityChip(r['priority_level'] as String?),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text:
                    '${r['disaster'] ?? 'Disaster'} in Barangay '
                    '${r['barangay'] ?? '-'}. ',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (who.isNotEmpty || needs.isNotEmpty)
                TextSpan(
                  text: '${[
                    if (who.isNotEmpty) who,
                    if (needs.isNotEmpty) 'need $needs',
                  ].join(' ')}.',
                ),
            ],
          ),
          style: t.bodyLarge,
        ),
      ),
      DisasterArt(disasterKind(r['disaster']), height: 170),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, Space.sm, Space.md, 0),
        child: FulfillmentBar(
          delivered: r['total_items_delivered'] as num? ?? 0,
          needed: r['total_items_needed'] as num? ?? 0,
          percent: r['fulfillment_percentage'] as num?,
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(Space.sm),
        child: Row(
          children: [
            Expanded(
              child: AppButton(
                donateLabel,
                variant: AppButtonVariant.donate,
                expand: true,
                onPressed: onDonate,
              ),
            ),
            Gaps.h8,
            Expanded(
              child: AppButton(
                'Details',
                variant: AppButtonVariant.secondary,
                expand: true,
                onPressed: () => showReportSheet(
                  context,
                  ((r['id'] ?? r['report_id']) as num).toInt(),
                ),
              ),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// Goods arrived: a delivery the barangay confirmed, with the relief photo.
class ArrivedPost extends StatelessWidget {
  final Map delivery;
  final List<Map<String, dynamic>> reports; // to say how supplied it is now
  const ArrivedPost({super.key, required this.delivery, required this.reports});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final d = delivery;
    final brgy = '${d['barangay'] ?? 'the barangay'}';
    final here = reports.where((r) => r['barangay'] == d['barangay']).toList();
    final progress = here.length == 1
        ? '${here.first['disaster']} in $brgy is now '
              '${((here.first['fulfillment_percentage'] as num?) ?? 0).round()}% '
              'supplied.'
        : null;
    return _postCard([
      _PostHeader(
        avatar: const _Avatar(icon: Icons.task_alt, tone: 'Acknowledged'),
        title: 'Barangay $brgy',
        subtitle: [
          'Goods arrived',
          if (timeAgo(d['confirmed_at']).isNotEmpty) timeAgo(d['confirmed_at']),
        ].join(' · '),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.sm),
        child: Text(
          '${d['summary'] ?? 'Relief goods'} reached Barangay $brgy. The '
          'barangay confirmed they arrived.',
          style: t.bodyLarge,
        ),
      ),
      SizedBox(
        height: 170,
        child: Image.asset(
          kImpactImage,
          fit: BoxFit.cover,
          excludeFromSemantics: true,
          errorBuilder: (_, _, _) => ColoredBox(color: cs.surfaceContainerHigh),
        ),
      ),
      if (progress != null)
        Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Text(
            progress,
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
        )
      else
        Gaps.v12,
    ]);
  }
}

/// A report this donor supported reached 100%.
class FinishedPost extends StatelessWidget {
  final Map report;
  const FinishedPost({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final r = report;
    return _postCard([
      _PostHeader(
        avatar: const _Avatar(icon: Icons.star_outline, tone: 'Preparing'),
        title: 'You helped finish a report',
        subtitle: '${r['label'] ?? ''}',
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
        child: Row(
          children: [
            DisasterArt(
              disasterKindOfLabel(r['label']),
              width: 64,
              height: 64,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            Gaps.h12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'It got everything it needed. Thank you for being part '
                    'of it.',
                    style: t.bodyLarge,
                  ),
                  Gaps.v8,
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(
                      value: 1,
                      minHeight: 6,
                      color: StatusColors.base('Fulfilled'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// The landing page's live numbers, as the last post.
class MandaueNowPost extends StatelessWidget {
  final Map stats;
  const MandaueNowPost({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget tile(String value, String label) => Expanded(
      child: Container(
        padding: const EdgeInsets.all(Space.sm),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: t.headlineSmall?.copyWith(color: Colors.white)),
            Text(
              label,
              style: t.bodySmall?.copyWith(color: AppColors.harborMist),
            ),
          ],
        ),
      ),
    );
    String n(String k) => '${stats[k] ?? 0}';
    return Container(
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: AppColors.harborDeep,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Right now in Mandaue',
                  style: t.titleMedium?.copyWith(color: Colors.white),
                ),
              ),
              if (kDemoData)
                Text(
                  'Demo data',
                  style: t.labelSmall?.copyWith(color: AppColors.harborMist),
                ),
            ],
          ),
          Gaps.v12,
          Row(
            children: [
              tile(n('active_reports'), 'reports need help'),
              Gaps.h8,
              tile(n('urgent_reports'), 'critical or high'),
            ],
          ),
          Gaps.v8,
          Row(
            children: [
              tile(n('families_affected'), 'families affected'),
              Gaps.h8,
              tile(n('deliveries_completed'), 'deliveries completed'),
            ],
          ),
        ],
      ),
    );
  }
}
