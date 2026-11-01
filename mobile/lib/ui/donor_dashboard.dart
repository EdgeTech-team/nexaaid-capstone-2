import 'dart:convert';

import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'disaster_art.dart';
import 'donation_entries_view.dart';
import 'donor_feed.dart';
import 'landing/about_section.dart';
import 'landing/landing_screen.dart' show HowItWorksSteps;
import 'landing/mission_section.dart';
import 'landing/landing_extras.dart' show kImpactImage;
import 'donor_screens.dart' show DonateScreen;
import 'expiry_widgets.dart' show cancelDonation, cautionButtonStyle;
import 'qr_save.dart';
import 'home_nav.dart';
import 'needs_progress.dart' show stillNeededText;
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Adviser item 10 / Module 9: donor and relief organization dashboard
// (UC-D3, UC-D4, UC-R3, UC-R4; section 7.3).
//
// Ivan (simple donor screens): the Dashboard tab looks like the landing
// page: a photo banner with the greeting, then a side-scrolling box of the
// barangays that need help (most urgent first) with Donate buttons, and a
// "See all reports" link. The donor's own giving (4 cards, donation status,
// delivery status) is in the Reports tab (my_giving.dart).
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
/// Oct 25: the CMO's acknowledgement ("Confirmed") is not a donor step, so
/// it stays on "Received by CSWS".
String donationStep(Map d) {
  final s = '${d['lifecycle_status'] ?? d['status'] ?? 'Pending'}';
  return switch (s) {
    'Partly Received' => 'Pending',
    'Confirmed' => 'Received',
    _ => s,
  };
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
      final byPriority = PriorityColors.rank(a['priority_level'] as String?)
          .compareTo(PriorityColors.rank(b['priority_level'] as String?));
      return byPriority != 0 ? byPriority : _percent(a).compareTo(_percent(b));
    });
  return open.isEmpty ? null : open.first;
}

class DonorDashboard extends StatefulWidget {
  const DonorDashboard({super.key});

  @override
  State<DonorDashboard> createState() => _DonorDashboardState();
}

class _DonorDashboardState extends State<DonorDashboard> {
  /// "See all reports": the Reports tab, every validated report, active and
  /// done, with the priority and progress filters (2.4, 3.3).
  void _openAllReports() => HomeNav.go(context, const HomeTarget('Reports'));

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
        final supported = (m['supported_reports'] as List).cast<Map>();
        final isOrg = profile['organization'] != null;
        final validated = names.rows('validated_reports');

        // Barangays that need help: most urgent first, fully supplied hidden.
        final open = needsHelp(validated);

        // Supported reports joined with /lookups for families and barangay.
        final byId = {for (final r in validated) '${r['id']}': r};
        final helped = [
          for (final r in supported)
            {...r, ...?byId['${r['report_id']}'], 'label': r['label']},
        ];

        final donateLabel = isOrg
            ? 'Donate as ${profile['organization']}'
            : 'Donate';

        return ListView(
          physics: const AlwaysScrollableScrollPhysics(), // pull to refresh
          padding: const EdgeInsets.only(bottom: Space.xl),
          children: [
            _DashboardHero(
              profile: profile,
              isOrg: isOrg,
              summary: sum,
              barangays: {for (final r in helped) _barangayOf(r)}.length,
            ),
            _Centered(
              child: SectionHeader(
                'Barangays that need help',
                subtitle: open.isEmpty
                    ? null
                    : 'Most urgent first. Swipe to see more.',
                action: TextButton(
                  onPressed: _openAllReports,
                  child: const Text('See all reports'),
                ),
              ),
            ),
            if (open.isEmpty)
              const _Centered(
                child: AppCard(
                  child: EmptyView(
                    compact: true,
                    icon: Icons.verified_outlined,
                    title: 'No barangay needs help right now',
                    message:
                        'When the City validates a new disaster report, it '
                        'shows up here.',
                  ),
                ),
              )
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: Space.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final r in open.take(10)) ...[
                      NeedCard(
                        report: r,
                        donateLabel: donateLabel,
                        onDonate: () => _donate(r, names),
                      ),
                      Gaps.h12,
                    ],
                  ],
                ),
              ),
            // ---- Latest updates: a short newsfeed (canvas) ------------
            _Centered(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SectionHeader(
                    'Latest updates',
                    subtitle: 'New reports and goods that arrived.',
                  ),
                  DonorFeed(
                    validated: validated,
                    supported: helped,
                    donateLabel: donateLabel,
                    onDonate: (r) => _donate(r, names),
                  ),

                  // ---- About NexaAid, like the landing page -------------
                  const SectionHeader('How NexaAid works'),
                  const HowItWorksSteps(),
                  Gaps.v8,
                  const MissionSection(),
                  const AboutSection(),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Validated reports still under 100%, most urgent first (Critical, High,
/// Medium, Low), then the one furthest from its goal.
List<Map<String, dynamic>> needsHelp(List<Map<String, dynamic>> reports) =>
    reports.where((r) => _percent(r) < 100).toList()..sort((a, b) {
      final p = PriorityColors.rank(a['priority_level'] as String?)
          .compareTo(PriorityColors.rank(b['priority_level'] as String?));
      return p != 0 ? p : _percent(a).compareTo(_percent(b));
    });

/// One barangay that needs help, for the side-scrolling box: its picture,
/// priority, what it still needs, and a Donate button.
class NeedCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final String donateLabel;
  final VoidCallback onDonate;
  const NeedCard({
    super.key,
    required this.report,
    required this.onDonate,
    this.donateLabel = 'Donate',
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final needed = (r['total_items_needed'] as num?) ?? 0;
    final delivered = (r['total_items_delivered'] as num?) ?? 0;
    final left = (needed - delivered).clamp(0, needed);
    final needs = '${r['assistance_needed'] ?? ''}'.trim();
    return SizedBox(
      width: 250,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DisasterArt(disasterKind(r['disaster']), height: 100),
            Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PriorityChip(r['priority_level'] as String?),
                  Gaps.v8,
                  Text(
                    'Barangay ${r['barangay'] ?? '-'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleMedium,
                  ),
                  Text(
                    '${r['disaster'] ?? 'Disaster'}'
                    '${r['affected_families'] == null ? '' : ' · ${r['affected_families']} families'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  Gaps.v8,
                  Text(
                    switch (stillNeededText(r)) {
                      // Per-item needs: what each one still lacks.
                      final String s when s.isEmpty => 'All needs delivered',
                      final String s => 'Still needs $s',
                      null when needed > 0 =>
                        'Still needs $left of $needed items',
                      null => 'Needs help',
                    },
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.labelLarge,
                  ),
                  if (needs.isNotEmpty)
                    Text(
                      needs,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  Gaps.v8,
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(
                      value: needed > 0
                          ? (delivered / needed).clamp(0, 1).toDouble()
                          : 0,
                      minHeight: 6,
                    ),
                  ),
                  Gaps.v12,
                  AppButton(
                    donateLabel,
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
      ),
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
  static const _darken = 0.74;
  final Alignment alignment;
  const _HeroPhoto({this.alignment = Alignment.center});

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Image.asset(
        kImpactImage,
        fit: BoxFit.cover,
        alignment: alignment,
        excludeFromSemantics: true,
        errorBuilder: (_, _, _) =>
            const ColoredBox(color: AppColors.harborDeep),
      ),
      ColoredBox(color: AppColors.harborDeep.withValues(alpha: _darken)),
    ],
  );
}

/// Like the landing page hero, with a photo: greeting and small totals for
/// donors; cover photo, logo box and account status for organizations.
class _DashboardHero extends StatelessWidget {
  final Map profile;
  final Map summary;
  final bool isOrg;
  final int barangays; // barangays of the reports this donor supported
  const _DashboardHero({
    required this.profile,
    required this.summary,
    required this.isOrg,
    required this.barangays,
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
      child: Text(text, style: t.labelLarge?.copyWith(color: onHero)),
    );

    final greeting = isOrg
        ? <Widget>[
            // Align keeps the logo a small square: the hero's Column
            // stretches its children to full width.
            Align(
              alignment: Alignment.centerLeft,
              child: Container(
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
                  [
                    'Relief organization',
                    if ('${profile['organization_type'] ?? ''}'.isNotEmpty)
                      '${profile['organization_type']}',
                  ].join(' · '),
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
              barangays > 0
                  ? 'Your donations are helping $barangays '
                        '${barangays == 1 ? 'barangay' : 'barangays'} in '
                        'Mandaue. Here is who needs help next.'
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
        Positioned.fill(
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
            ],
          ),
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

/// A supported report with its picture, priority and progress.
class ReportProgressCard extends StatelessWidget {
  final Map report;
  const ReportProgressCard({super.key, required this.report});

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

  /// The entry as last loaded; refreshed after adding or removing items.
  late Map _entry = widget.entry;
  bool _changed = false; // tell the list underneath to reload

  Future<void> _reload() async {
    final r = await api.get('/donations/mine');
    if (!mounted || !r.ok || r.json is! Map) return;
    final fresh = ((r.json as Map)['entries'] as List? ?? const [])
        .cast<Map>()
        .where((x) => x['batch_reference'] == _entry['batch_reference'])
        .firstOrNull;
    if (fresh != null) setState(() => _entry = fresh);
  }

  /// Oct 23: open the donate form in "add items" mode for this donation.
  Future<void> _addItems(BuildContext context, Map e) async {
    final lookups = await api.lookupsResult();
    if (!context.mounted) return;
    final names = Names(
      lookups.ok && lookups.json is Map
          ? Map<String, dynamic>.from(lookups.json as Map)
          : <String, dynamic>{},
    );
    final info = e['report'] as Map? ?? const {};
    final report =
        names
            .rows('validated_reports')
            .where((r) => '${r['id'] ?? r['report_id']}' == '${e['report_id']}')
            .firstOrNull ??
        {
          'id': e['report_id'],
          'disaster': info['disaster'] ?? 'Disaster',
          'barangay': info['barangay'] ?? '',
          'assistance_needed': info['assistance_needed'],
          'priority_level': info['priority_level'],
        };
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DonateScreen(report: report, names: names, addTo: e),
      ),
    );
    if (added == true) {
      _changed = true;
      await _reload();
    }
  }

  /// Oct 23: remove one waiting item, after a strong warning and a reason.
  Future<void> _removeItem(BuildContext context, Map e, Map item) async {
    final reason = await confirmRemoveItem(
      context,
      item,
      '${e['batch_reference']}',
    );
    if (reason == null || !context.mounted) return;
    final r = await act(
      context,
      () => api.post(
        '/donations/entries/${Uri.encodeComponent('${e['batch_reference']}')}'
        '/items/${item['donation_id']}/remove',
        body: {'reason': reason},
      ),
      success: '${item['item_name']} removed. CSWS will see why.',
    );
    if (r.ok) {
      _changed = true;
      await _reload();
    }
  }

  /// Remove is offered only on waiting items, while the donation can still
  /// change, and never on the last item left.
  Widget? _removeButton(BuildContext context, Map e, Map item) {
    if (e['can_change_items'] != true || item['status'] != 'Pending') {
      return null;
    }
    final open = (e['items'] as List? ?? const []).cast<Map>().where(
      (i) => const {'Pending', 'Received', 'Confirmed'}.contains(i['status']),
    );
    if (open.length <= 1) return null; // a donation keeps at least one item
    return IconButton(
      tooltip: 'Remove ${item['item_name']}',
      visualDensity: VisualDensity.compact,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      onPressed: () => _removeItem(context, e, item),
      icon: const Icon(Icons.remove_circle_outline),
    );
  }

  /// Opens the donate form filled in with this donation.
  Future<void> _edit(BuildContext context, Map e) async {
    final lookups = await api.lookupsResult();
    if (!context.mounted) return;
    final names = Names(
      lookups.ok && lookups.json is Map
          ? Map<String, dynamic>.from(lookups.json as Map)
          : <String, dynamic>{},
    );
    final info = e['report'] as Map? ?? const {};
    final report =
        names
            .rows('validated_reports')
            .where((r) => '${r['id'] ?? r['report_id']}' == '${e['report_id']}')
            .firstOrNull ??
        {
          'id': e['report_id'],
          'disaster': info['disaster'] ?? 'Disaster',
          'barangay': info['barangay'] ?? '',
          'assistance_needed': info['assistance_needed'],
          'priority_level': info['priority_level'],
        };
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => DonateScreen(report: report, names: names, edit: e),
      ),
    );
    // Back to the list, which reloads with the changes.
    if (saved == true && context.mounted) Navigator.of(context).pop(true);
  }

  /// Oct 25: the donor cancels (with a reason) instead of deleting, so CSWS
  /// and the records keep the donation and know why it stopped.
  Future<void> _cancel(BuildContext context, Map e) async {
    if (await cancelDonation(context, e)) {
      _changed = true;
      await _reload();
    }
  }

  /// Oct 25: every change to the donation in one card, right under its
  /// items: add more (same QR), update the details, or cancel. Compact
  /// buttons with icons, and no red (the adviser reads red as an error).
  Widget _manage(BuildContext context, Map e) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final items = (e['items'] as List? ?? const []).cast<Map>();
    final waiting = items.any((i) => i['status'] == 'Pending');
    final cancelled = e['status'] == 'Cancelled';
    final canAdd = e['can_change_items'] == true;
    final canEdit = canEditDonation(e);
    final canCancel = waiting;
    final blocked = waiting && !canAdd && e['change_blocked_reason'] != null;
    final open = items.where(
      (i) => const {'Pending', 'Received', 'Confirmed'}.contains(i['status']),
    );
    final slate = StatusColors.of('Cancelled', Theme.of(context).brightness);

    Widget lockNote() => Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.lock_outline, size: 16, color: cs.onSurfaceVariant),
        Gaps.h8,
        Expanded(child: Text('${e['change_blocked_reason']}', style: muted)),
      ],
    );

    if (!canAdd && !canEdit && !canCancel) {
      return blocked
          ? Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: lockNote(),
            )
          : const SizedBox.shrink();
    }
    return AppCard(
      margin: const EdgeInsets.only(top: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (canAdd) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.add_shopping_cart_rounded,
                    size: 20,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                Gaps.h12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Want to add more?',
                        style: t.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Gaps.v4,
                      Text(
                        'New items join this donation and keep the same QR '
                        'code and pickup.',
                        style: muted,
                      ),
                      Gaps.v12,
                      FilledButton.icon(
                        onPressed: () => _addItems(context, e),
                        icon: const Icon(Icons.add_rounded, size: 20),
                        label: const Text('Add items'),
                      ),
                      if (open.length > 1) ...[
                        Gaps.v8,
                        Text(
                          'To take an item out, tap ⊖ beside it. A donation '
                          'always keeps at least one item.',
                          style: muted,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (canAdd && (canEdit || canCancel))
            const Divider(height: Space.lg * 1.5),
          if (canEdit || canCancel) ...[
            Text(
              cancelled ? 'Changed your mind?' : 'Need to change something?',
              style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant),
            ),
            Gaps.v8,
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                if (canEdit)
                  OutlinedButton.icon(
                    onPressed: () => _edit(context, e),
                    icon: Icon(
                      cancelled
                          ? Icons.replay_rounded
                          : Icons.edit_note_rounded,
                      size: 20,
                    ),
                    label: Text(
                      cancelled ? 'Fix and send again' : 'Update details',
                    ),
                  ),
                if (canCancel)
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: slate.fg,
                      side: BorderSide(
                        color: slate.base.withValues(alpha: 0.5),
                      ),
                    ),
                    onPressed: () => _cancel(context, e),
                    icon: const Icon(Icons.event_busy_outlined, size: 20),
                    label: const Text('Cancel donation'),
                  ),
              ],
            ),
          ],
          if (blocked) ...[Gaps.v12, lockNote()],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = _entry;
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

    return PopScope(
      // Back to the list, which reloads when items were added or removed.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_changed);
      },
      child: Scaffold(
        appBar: AppBar(title: Text('${e['batch_reference'] ?? 'Donation'}')),
        body: ListView(
          padding: Space.page,
          children: [
            DonationEntryCard(
              entry: e,
              donor: true,
              itemAction: (item) => _removeButton(context, e, item),
            ),
            // Add more, update or cancel: right under the items they change.
            _manage(context, e),
            const SectionHeader('Progress'),
            AppCard(
              child: StatusTimeline(
                steps: donationLifecycle,
                labels: donationLifecycleLabels,
                current: donationStep(e),
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
                      '${e['batch_reference']}.',
                      style: muted,
                    );
                  }
                  return Column(
                    children: [
                      Center(
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
                      ),
                      Gaps.v8,
                      SaveQrButton(
                        qrBase64: b64,
                        reference: '${e['batch_reference']}',
                        handover: '${e['handover_method'] ?? ''}',
                        forReport: report?['label'] as String?,
                      ),
                    ],
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
                  if (e['pickup_days_label'] != null)
                    row(
                      'Pickup days',
                      '${e['pickup_days_label']} · ${e['pickup_hours'] ?? ''}',
                    )
                  else if (e['preferred_pickup_at'] != null)
                    row('Preferred pickup', niceDate(e['preferred_pickup_at'])),
                  row('Pledged on', niceDate(e['created_at'])),
                  row('For report', report?['label']),
                ],
              ),
            ),
            if (report != null) ...[
              const SectionHeader('Report progress'),
              ReportProgressCard(report: report),
            ],
            Gaps.v24,
          ],
        ),
      ),
    );
  }
}

/// Oct 23: "Remove this item?" with a strong warning. The donor must type
/// why and tick that they understand. Returns the reason, or null.
Future<String?> confirmRemoveItem(
  BuildContext context,
  Map item,
  String reference,
) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RemoveItemDialog(item: item, reference: reference),
  );
}

class _RemoveItemDialog extends StatefulWidget {
  final Map item;
  final String reference;
  const _RemoveItemDialog({required this.item, required this.reference});

  @override
  State<_RemoveItemDialog> createState() => _RemoveItemDialogState();
}

class _RemoveItemDialogState extends State<_RemoveItemDialog> {
  final _reason = TextEditingController();
  bool _sure = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _ready => _sure && _reason.text.trim().length >= 3;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final i = widget.item;
    final what = '${i['quantity']} ${i['unit'] ?? ''} ${i['item_name']}'
        .replaceAll(RegExp(r'\s+'), ' ');
    // A strong warning in amber: red reads as a system error (Oct 25).
    final caution = StatusColors.of('On Hold', Theme.of(context).brightness);
    return AlertDialog(
      icon: Icon(Icons.warning_amber_rounded, color: caution.fg, size: 40),
      title: const Text('Remove this item?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(Space.sm),
              decoration: BoxDecoration(
                color: caution.bg,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Text(
                what,
                textAlign: TextAlign.center,
                style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Gaps.v12,
            Text(
              'Are you sure you want to remove this item from donation '
              '${widget.reference}? This cannot be undone. CSWS will no '
              'longer expect it, and it will see that you removed it and why.',
              style: t.bodyMedium,
            ),
            Gaps.v12,
            TextField(
              controller: _reason,
              autofocus: true,
              maxLength: 200,
              minLines: 1,
              maxLines: 3,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                labelText: 'Why are you removing it? (required)',
                hintText: 'e.g. The goods expired, or I gave them elsewhere',
              ),
            ),
            CheckboxListTile(
              value: _sure,
              onChanged: (v) => setState(() => _sure = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'Yes, I am sure I want to remove this item.',
                style: t.bodyMedium?.copyWith(color: cs.onSurface),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Keep it'),
        ),
        FilledButton.icon(
          style: cautionButtonStyle(context),
          onPressed: _ready
              ? () => Navigator.pop(context, _reason.text.trim())
              : null,
          icon: const Icon(Icons.remove_circle_outline),
          label: const Text('Remove item'),
        ),
      ],
    );
  }
}

/// Nothing of it was received yet: every item is waiting, or it was
/// cancelled or declined (fixing it sends it again). Oct 23: not once items
/// were added later or removed (that history stays; use add / remove).
bool canEditDonation(Map e) {
  final items = (e['items'] as List? ?? const []).cast<Map>();
  return items.isNotEmpty &&
      items.every(
        (i) => i['status'] == 'Pending' || i['status'] == 'Cancelled',
      ) &&
      !items.any(
        (i) =>
            ((i['addition_no'] as num?) ?? 1) > 1 ||
            i['removed_by_donor'] == true,
      );
}

/// A donation notification was tapped: open that donation's own page
/// (Oct 11), not the whole dashboard. If it was deleted, say so.
Future<void> openMyDonation(BuildContext context, int donationId) async {
  final r = await api.get('/donations/mine');
  if (!context.mounted) return;
  final entries = r.ok && r.json is Map
      ? ((r.json as Map)['entries'] as List? ?? const []).cast<Map>()
      : const <Map>[];
  final entry = entries
      .where(
        (e) => (e['items'] as List? ?? const []).any(
          (i) => (i as Map)['donation_id'] == donationId,
        ),
      )
      .firstOrNull;
  if (entry == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('This donation is no longer in your list.')),
    );
    return;
  }
  await Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => DonationDetailScreen(entry: entry)));
}
