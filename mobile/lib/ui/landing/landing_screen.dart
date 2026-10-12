import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/design.dart';
import '../donor_screens.dart' show DonateScreen;
import '../login_screen.dart';
import '../blur_popup.dart';
import '../register_screen.dart' show showRegisterPopup;
import '../report_summary_card.dart';
import '../widgets.dart' show api, formDialog, DialogField, Names;
import 'landing_extras.dart' show CredentialsCard;
import 'landing_sections.dart';
import 'public_data.dart';

/// First screen for anyone not signed in (adviser item 8): what NexaAid
/// is, live numbers, how it works, and the validated reports that need
/// help, with guest donation, log in and sign up.
///
/// Redesign (Oct 12, approved mockups): pinned header with the section
/// links, headline with a photo, our impact, how it works, the report cards,
/// questions and a closing band. Sections are in landing_sections.dart.
class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  late Future<PublicSnapshot> _future = loadPublicData(api);
  final _scroll = ScrollController();
  final _viewportKey = GlobalKey();
  final _sections = {
    for (final s in LandingSection.values) s: GlobalKey(debugLabel: s.name),
  };

  /// The section in view, highlighted in the header links.
  LandingSection? _current;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  double get _headerExtent =>
      LandingHeader.heightFor(context) + MediaQuery.paddingOf(context).top;

  /// Top of [key]'s section, measured from the top of the scroll view.
  double? _topOf(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (box == null || viewport == null || !box.attached) return null;
    return box.localToGlobal(Offset.zero, ancestor: viewport).dy;
  }

  /// Highlights the link of the section under the pinned header.
  bool _track(ScrollNotification _) {
    LandingSection? now;
    for (final s in LandingSection.values) {
      final top = _topOf(_sections[s]!);
      if (top != null && top <= _headerExtent + 120) now = s;
    }
    if (now != _current) setState(() => _current = now);
    return false;
  }

  Future<void> _reload() async {
    setState(() {
      _future = loadPublicData(api);
    });
    try {
      await _future;
    } catch (_) {
      // Shown by the FutureBuilder.
    }
  }

  Future<void> _serverAddress() async {
    final v = await formDialog(
      context,
      title: 'Server address',
      message:
          'Android emulator: http://10.0.2.2:8000\n'
          'Chrome: http://localhost:8000\n'
          'Phone on USB (adb reverse): http://localhost:8000',
      fields: [DialogField('url', 'API base URL', initial: api.baseUrl)],
    );
    if (v == null) return;
    api.setBase(v['url']!);
    _reload();
  }

  void _logIn() => showLoginPopup(context);

  /// "Register as donor or organization": a formatted pop-out (over the
  /// blurred landing page) to choose which kind of donor account.
  Future<void> _createAccount() async {
    final org = await showBlurPopup<bool>(
      context,
      label: 'Close',
      child: const _DonorTypeChooser(),
    );
    if (org == null || !mounted) return;
    showRegisterPopup(context, org: org);
  }

  Future<void> _donate(Map<String, dynamic> report) async {
    final lookups = await api.lookups();
    if (!mounted) return;
    if (lookups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'The donation form couldn\'t load. Check the server address '
            'and try again.',
          ),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DonateScreen(report: report, names: Names(lookups)),
      ),
    );
  }

  /// Public pop-out of one validated report: a dialog on Chrome and
  /// tablets, a bottom sheet on phones. Reporter details are never shown.
  void _openReport(Map<String, dynamic> r) {
    void donate(BuildContext ctx) {
      Navigator.of(ctx).pop();
      _donate(r);
    }

    if (landingWide(context)) {
      showDialog<void>(
        context: context,
        builder: (ctx) => Dialog(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(Space.lg),
              child: LandingReportDetails(
                report: r,
                onDonate: () => donate(ctx),
              ),
            ),
          ),
        ),
      );
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
            child: LandingReportDetails(report: r, onDonate: () => donate(ctx)),
          ),
        ),
      ),
    );
  }

  /// Header links: scroll so the section starts just under the pinned
  /// header.
  void _jump(LandingSection s) {
    final top = _topOf(_sections[s]!);
    if (top == null || !_scroll.hasClients) return;
    final pos = _scroll.position;
    final target = (pos.pixels + top - _headerExtent)
        .clamp(pos.minScrollExtent, pos.maxScrollExtent)
        .toDouble();
    if (MediaQuery.disableAnimationsOf(context)) {
      _scroll.jumpTo(target);
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 450),
        curve: Motion.curve,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: FutureBuilder<PublicSnapshot>(
          future: _future,
          builder: (context, snap) {
            final data = snap.data;
            return RefreshIndicator(
              onRefresh: _reload,
              edgeOffset: _headerExtent,
              child: NotificationListener<ScrollNotification>(
                onNotification: _track,
                child: CustomScrollView(
                  key: _viewportKey,
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // Pinned while scrolling, with the section links.
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _PinnedHeader(
                        extent: _headerExtent,
                        child: LandingHeader(onJump: _jump, current: _current),
                      ),
                    ),
                    // One sliver, so every section is built (and findable).
                    SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          LandingHero(
                            onLogIn: _logIn,
                            onCreateAccount: _createAccount,
                            onDonateAsGuest: api.continueAsGuest,
                          ),
                          KeyedSubtree(
                            key: _sections[LandingSection.impact],
                            child: snap.hasError && data == null
                                ? _Centered(child: _error(snap.error))
                                : LandingImpactSection(
                                    stats: data?.stats,
                                    asOf: data?.loadedAt,
                                  ),
                          ),
                          LandingHowItWorks(
                            key: _sections[LandingSection.how],
                            onSeeReports: () => _jump(LandingSection.reports),
                            onDonateAsGuest: api.continueAsGuest,
                          ),
                          KeyedSubtree(
                            key: _sections[LandingSection.reports],
                            child: _reports(
                              context,
                              data,
                              loading: data == null && !snap.hasError,
                            ),
                          ),
                          LandingFaq(key: _sections[LandingSection.questions]),
                          LandingClosingBand(
                            onStart: api.continueAsGuest,
                            onRegister: _createAccount,
                          ),
                          const _Centered(child: CredentialsCard()),
                          Gaps.v32,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _error(Object? e) {
    final err = e is PublicDataError ? e : const PublicDataError(0, '');
    return Padding(
      padding: const EdgeInsets.only(top: Space.lg),
      child: ErrorView.forStatus(
        err.status,
        err.detail,
        onRetry: _reload,
        secondary: AppButton(
          'Server address',
          icon: Icons.dns_outlined,
          variant: AppButtonVariant.text,
          onPressed: _serverAddress,
        ),
      ),
    );
  }

  /// "Reports that need help": the 6 most urgent validated reports, on the
  /// same card as the signed-in report lists.
  Widget _reports(
    BuildContext context,
    PublicSnapshot? data, {
    required bool loading,
  }) {
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);
    final all = data?.reports ?? const <Map<String, dynamic>>[];
    final shown = all.take(6).toList();
    final seeAll = TextButton(
      onPressed: api.continueAsGuest,
      style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('See all reports'),
          Gaps.h4,
          Icon(Icons.arrow_forward, size: 16),
        ],
      ),
    );
    return Material(
      color: cs.surfaceContainerLowest,
      child: LandingWidth(
        padding: EdgeInsets.symmetric(vertical: wide ? 80 : Space.xl + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LandingEyebrow('Reports that need help'),
                      Gaps.v8,
                      LandingTitle('Barangays waiting for relief'),
                      Gaps.v8,
                      Text(
                        'Checked by the City. Most urgent first. Tap a report '
                        'to see everything.',
                      ),
                    ],
                  ),
                ),
                if (wide && all.isNotEmpty) seeAll,
              ],
            ),
            if (!wide && all.isNotEmpty)
              Align(alignment: Alignment.centerRight, child: seeAll),
            Gaps.v24,
            if (loading)
              const LandingReportGrid(
                children: [
                  SkeletonCard(height: 300),
                  SkeletonCard(height: 300),
                  SkeletonCard(height: 300),
                ],
              )
            else if (shown.isEmpty)
              const AppCard(
                child: EmptyView(
                  compact: true,
                  icon: Icons.verified_outlined,
                  title: 'No reports need help right now',
                  message:
                      'When the City validates a disaster report, it shows up '
                      'here so you can donate.',
                ),
              )
            else
              LandingReportGrid(
                children: [for (final r in shown) _reportCard(r)],
              ),
          ],
        ),
      ),
    );
  }

  Widget _reportCard(Map<String, dynamic> r) {
    final guidance = '${r['priority_guidance'] ?? ''}'.trim();
    final description = '${r['description'] ?? ''}'.trim();
    final needs = '${r['assistance_needed'] ?? ''}'.trim();
    return ReportSummaryCard(
      reportId: (r['report_id'] ?? r['id']) as int?,
      disaster: '${r['disaster'] ?? 'Disaster'}',
      barangay: '${r['barangay'] ?? '-'}',
      status: 'Validated',
      priority: r['priority_level'] as String?,
      source: r['source']?.toString(),
      affectedFamilies: (r['affected_families'] as num?)?.toInt(),
      assistanceNeeded: needs.isEmpty ? null : needs,
      quantity: r['total_items_needed'] as num?,
      description: description.isEmpty ? null : description,
      guidance: guidance.isEmpty ? null : guidance,
      delivered: r['total_items_delivered'] as num? ?? 0,
      needed: r['total_items_needed'] as num? ?? 0,
      percent: num.tryParse('${r['fulfillment_percentage'] ?? ''}'),
      margin: EdgeInsets.zero,
      fillActions: true,
      onTap: () => _openReport(r),
      actions: [
        OutlinedButton(
          onPressed: () => _openReport(r),
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          child: const Text('Details'),
        ),
        AppButton(
          'Donate',
          icon: Icons.volunteer_activism_outlined,
          variant: AppButtonVariant.donate,
          expand: true,
          onPressed: () => _donate(r),
        ),
      ],
    );
  }
}

/// Keeps the header at the top while the page scrolls.
class _PinnedHeader extends SliverPersistentHeaderDelegate {
  final double extent;
  final Widget child;
  const _PinnedHeader({required this.extent, required this.child});

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      SizedBox.expand(child: child);

  @override
  bool shouldRebuild(covariant _PinnedHeader old) => true;
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

/// The three "How it works" steps. Also on the donor Dashboard (Ivan).
class HowItWorksSteps extends StatelessWidget {
  const HowItWorksSteps({super.key});

  static const _steps = [
    (
      'The City validates a report',
      'The CSWS Disaster Unit reports what a barangay needs. The '
          'administrator checks it before it appears here.',
    ),
    (
      'You pledge goods',
      'Choose items and quantities, then drop them off at the CSWS Main '
          'Office or ask for pickup. You get a QR code for your donation.',
    ),
    (
      'You follow it to the barangay',
      'CSWS receives it, the CMO confirms it, DRRMO delivers it, and the '
          'barangay confirms it arrived.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        children: [
          for (var i = 0; i < _steps.length; i++)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: cs.primaryContainer,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${i + 1}',
                          style: t.titleMedium?.copyWith(
                            color: cs.onPrimaryContainer,
                          ),
                        ),
                      ),
                      if (i < _steps.length - 1)
                        Expanded(
                          child: Container(
                            width: 2,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            color: cs.outlineVariant,
                          ),
                        ),
                    ],
                  ),
                  Gaps.h16,
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: i < _steps.length - 1 ? Space.md : 0,
                        top: 4,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_steps[i].$1, style: t.titleMedium),
                          Gaps.v4,
                          Text(
                            _steps[i].$2,
                            style: t.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
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

// ---------------------------------------------------------------------------
// Which kind of donor? (Ivan's note: "lacking format pop out for choosing
// which donor"). Pops true for an organization, false for an individual.
// ---------------------------------------------------------------------------
class _DonorTypeChooser extends StatelessWidget {
  const _DonorTypeChooser();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        Space.lg,
        Space.xs,
        Space.lg,
        Space.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          ),
          Text(
            'Join NexaAid',
            textAlign: TextAlign.center,
            style: t.headlineSmall,
          ),
          Gaps.v4,
          Text(
            'How will you give? Either way you can donate to any validated '
            'report and follow it to the barangay.',
            textAlign: TextAlign.center,
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.v24,
          _DonorTypeCard(
            icon: Icons.person_outline,
            title: 'Individual donor',
            subtitle: 'For yourself or your family.',
            points: const [
              'Donate right after signing up',
              'Track each donation with its QR code',
            ],
            onTap: () => Navigator.of(context).pop(false),
          ),
          Gaps.v12,
          _DonorTypeCard(
            icon: Icons.groups_outlined,
            title: 'Relief organization',
            subtitle: 'Churches, companies, schools and relief groups.',
            points: const [
              'Give under your organization\'s name',
              'Documents are optional for some organization types',
            ],
            onTap: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
  }
}

class _DonorTypeCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final List<String> points;
  final VoidCallback onTap;

  const _DonorTypeCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.points,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: '$title. $subtitle',
      excludeSemantics: true,
      child: Material(
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: cs.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: cs.primaryContainer,
                  child: Icon(icon, color: cs.onPrimaryContainer),
                ),
                Gaps.h12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: t.titleMedium),
                      Gaps.v4,
                      Text(
                        subtitle,
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      Gaps.v8,
                      for (final p in points)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.check,
                                size: 16,
                                color: StatusColors.base('Acknowledged'),
                              ),
                              Gaps.h4,
                              Expanded(child: Text(p, style: t.bodySmall)),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: cs.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
