import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/design.dart';
import '../donor_screens.dart' show DonateScreen;
import '../login_screen.dart';
import '../register_screen.dart';
import '../widgets.dart' show api, formDialog, DialogField, Names;
import 'landing_extras.dart';
import 'about_section.dart';
import 'mission_section.dart';
import 'public_data.dart';

/// First screen for anyone not signed in (adviser item 8): what NexaAid
/// is, live numbers, how it works, and the validated reports that need
/// help, with guest donation, log in and sign up.
class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});

  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  late Future<PublicSnapshot> _future = loadPublicData(api);
  String? _priority; // null = all

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

  void _logIn() =>
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => const LoginScreen()));

  void _createAccount() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Create an account',
                style: Theme.of(ctx).textTheme.titleLarge,
              ),
              Gaps.v8,
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('Individual donor'),
                subtitle: const Text('Track your donations to each report.'),
                onTap: () => _register(ctx, org: false),
              ),
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Relief organization'),
                subtitle: const Text(
                  'The administrator reviews your organization first.',
                ),
                onTap: () => _register(ctx, org: true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _register(BuildContext sheet, {required bool org}) {
    Navigator.of(sheet).pop();
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => RegisterScreen(org: org)));
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

  /// Public detail view of one validated report: needs, fulfillment progress
  /// and priority guidance, no login. Reporter details are never shown.
  void _openReport(Map<String, dynamic> r) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        final cs = Theme.of(ctx).colorScheme;
        final guidance = (r['priority_guidance'] ?? '').toString();
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
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
                Gaps.v8,
                Text(
                  [
                    if (r['sitio'] != null) 'Sitio ${r['sitio']}',
                    if (r['affected_families'] != null)
                      '${r['affected_families']} families affected',
                  ].join(' · '),
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                Gaps.v16,
                Text('Reported needs', style: t.titleSmall),
                Gaps.v8,
                _NeedChips(r['assistance_needed']),
                Gaps.v16,
                Text('Fulfillment progress', style: t.titleSmall),
                Gaps.v8,
                FulfillmentBar(
                  delivered: r['total_items_delivered'] as num? ?? 0,
                  needed: r['total_items_needed'] as num? ?? 0,
                  percent: r['fulfillment_percentage'] as num?,
                ),
                if (guidance.isNotEmpty) ...[
                  Gaps.v16,
                  Text('Priority guidance', style: t.titleSmall),
                  Gaps.v8,
                  Text(guidance, style: t.bodyMedium),
                ],
                Gaps.v24,
                AppButton(
                  'Donate to this report',
                  icon: Icons.volunteer_activism_outlined,
                  variant: AppButtonVariant.donate,
                  expand: true,
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    _donate(r);
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        body: FutureBuilder<PublicSnapshot>(
          future: _future,
          builder: (context, snap) {
            final data = snap.data;
            final loading = data == null && !snap.hasError;
            final urgent = data != null && data.reports.isNotEmpty
                ? data.reports.first
                : null;
            return RefreshIndicator(
              onRefresh: _reload,
              edgeOffset: MediaQuery.paddingOf(context).top,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverToBoxAdapter(
                    child: _Hero(
                      onDonateAsGuest: api.continueAsGuest,
                      onLogIn: _logIn,
                      onCreateAccount: _createAccount,
                      onServer: _serverAddress,
                      urgent: loading
                          ? const _UrgentSkeleton()
                          : urgent == null
                          ? null
                          : _UrgentCard(
                              report: urgent,
                              onDonate: () => _donate(urgent),
                            ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: _Centered(
                      child: snap.hasError && data == null
                          ? _error(snap.error)
                          : _body(context, data),
                    ),
                  ),
                ],
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

  Widget _body(BuildContext context, PublicSnapshot? data) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final s = data?.stats;
    final all = data?.reports ?? const <Map<String, dynamic>>[];
    final shown = all
        .where(
          (r) =>
              _priority == null ||
              (r['priority_level'] as String?)?.toLowerCase() ==
                  _priority!.toLowerCase(),
        )
        .take(6)
        .toList();

    String fmt(int n) => n.toString().replaceAllMapped(
      RegExp(r'\B(?=(\d{3})+(?!\d))'),
      (_) => ',',
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          'Right now in Mandaue',
          subtitle: 'From validated disaster reports. Pull down to refresh.',
        ),
        s == null
            ? const StatCardGrid([
                SkeletonCard(height: 132),
                SkeletonCard(height: 132),
                SkeletonCard(height: 132),
                SkeletonCard(height: 132),
              ])
            : StatCardGrid([
                StatCard(
                  label: 'Reports needing help',
                  value: fmt(s.activeReports),
                  icon: Icons.campaign_outlined,
                ),
                StatCard(
                  label: 'Critical or high priority',
                  value: fmt(s.urgentReports),
                  icon: Icons.priority_high,
                  color: PriorityColors.base('Critical'),
                ),
                StatCard(
                  label: 'Families affected',
                  value: fmt(s.familiesAffected),
                  icon: Icons.groups_outlined,
                  color: PriorityColors.base('High'),
                ),
                StatCard(
                  label: 'Barangays with reports',
                  value: fmt(s.barangays),
                  icon: Icons.location_on_outlined,
                  color: StatusColors.base('Received'),
                ),
                if (s.donationsReceived != null)
                  StatCard(
                    label: 'Donations received',
                    value: fmt(s.donationsReceived!),
                    icon: Icons.inventory_2_outlined,
                    color: StatusColors.base('Confirmed'),
                  ),
                if (s.deliveriesCompleted != null)
                  StatCard(
                    label: 'Deliveries completed',
                    value: fmt(s.deliveriesCompleted!),
                    icon: Icons.local_shipping_outlined,
                    color: StatusColors.base('Delivered'),
                  ),
              ]),
        const SectionHeader('How it works'),
        const _Steps(),
        const _PriorityGuide(),
        SectionHeader(
          'Reports that need help',
          subtitle: 'Most urgent first.',
          action: all.length > shown.length
              ? TextButton(
                  onPressed: api.continueAsGuest,
                  child: Text('See all ${all.length}'),
                )
              : null,
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final p in <String?>[null, ...PriorityColors.levels])
                Padding(
                  padding: const EdgeInsets.only(right: Space.xs),
                  child: ChoiceChip(
                    label: Text(p ?? 'All'),
                    selected: _priority == p,
                    onSelected: (_) => setState(() => _priority = p),
                  ),
                ),
            ],
          ),
        ),
        Gaps.v12,
        if (data == null) ...[
          const SkeletonCard(height: 200),
          Gaps.v12,
          const SkeletonCard(height: 200),
        ] else if (shown.isEmpty)
          AppCard(
            child: EmptyView(
              compact: true,
              icon: Icons.verified_outlined,
              title: all.isEmpty
                  ? 'No reports need help right now'
                  : 'No ${_priority?.toLowerCase()} priority reports',
              message: all.isEmpty
                  ? 'When the City validates a disaster report, it shows up '
                        'here so you can donate.'
                  : 'Choose another priority to see more reports.',
            ),
          )
        else
          for (final r in shown) ...[
            _ReportCard(
              report: r,
              onDonate: () => _donate(r),
              onOpen: () => _openReport(r),
            ),
            Gaps.v12,
          ],
        if (data != null) ImpactSection(stats: data.stats, asOf: data.loadedAt),
        const RecentDeliveriesSection(),
        const MissionSection(),
        WaysToHelpSection(
          onDonate: api.continueAsGuest,
          onRegister: (org) => Navigator.of(
            context,
          ).push(MaterialPageRoute(builder: (_) => RegisterScreen(org: org))),
        ),
        const AboutSection(),
        const CredentialsCard(),
        Gaps.v24,
        Text(
          'Built for the relief offices of Mandaue City: CSWS, CMO and DRRMO.',
          textAlign: TextAlign.center,
          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        Gaps.v32,
      ],
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

class _Hero extends StatelessWidget {
  final VoidCallback onDonateAsGuest;
  final VoidCallback onLogIn;
  final VoidCallback onCreateAccount;
  final VoidCallback onServer;
  final Widget? urgent;

  const _Hero({
    required this.onDonateAsGuest,
    required this.onLogIn,
    required this.onCreateAccount,
    required this.onServer,
    required this.urgent,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    const onHero = Colors.white;
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.harborDeep,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(Radii.xl)),
      ),
      child: SafeArea(
        bottom: false,
        child: _Centered(
          child: StaggeredColumn(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Gaps.v8,
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppColors.vest,
                      borderRadius: BorderRadius.circular(Radii.sm + 2),
                    ),
                    child: const Icon(
                      Icons.volunteer_activism,
                      size: 20,
                      color: AppColors.vestInk,
                    ),
                  ),
                  Gaps.h12,
                  Text(
                    'NexaAid',
                    style: t.titleLarge?.copyWith(
                      color: onHero,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: 'Server address',
                    onPressed: onServer,
                    color: AppColors.harborMist,
                    icon: const Icon(Icons.settings_outlined),
                  ),
                ],
              ),
              Gaps.v24,
              Semantics(
                header: true,
                child: Text(
                  'Get relief to the barangays that need it most.',
                  style: t.displaySmall?.copyWith(color: onHero),
                ),
              ),
              Gaps.v12,
              Text(
                'See validated disaster reports in Mandaue City, pledge goods, '
                'and follow them until the barangay confirms they arrived.',
                style: t.bodyLarge?.copyWith(color: AppColors.harborMist),
              ),
              Gaps.v24,
              AppButton(
                'Donate as guest',
                icon: Icons.volunteer_activism_outlined,
                variant: AppButtonVariant.donate,
                large: true,
                expand: true,
                onPressed: onDonateAsGuest,
              ),
              Gaps.v12,
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: onLogIn,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: onHero,
                        side: const BorderSide(color: AppColors.harborMist),
                      ),
                      child: const Text('Log in'),
                    ),
                  ),
                  Gaps.h12,
                  Expanded(
                    child: TextButton(
                      onPressed: onCreateAccount,
                      style: TextButton.styleFrom(foregroundColor: onHero),
                      child: const Text('Create account'),
                    ),
                  ),
                ],
              ),
              if (urgent != null) ...[Gaps.v24, urgent!],
              Gaps.v24,
            ],
          ),
        ),
      ),
    );
  }
}

/// The hero's live card: the single most urgent validated report.
class _UrgentCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDonate;
  const _UrgentCard({required this.report, required this.onDonate});

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
            variant: AppButtonVariant.primary,
            expand: true,
            onPressed: onDonate,
          ),
        ],
      ),
    );
  }
}

class _UrgentSkeleton extends StatelessWidget {
  const _UrgentSkeleton();

  @override
  Widget build(BuildContext context) => const SkeletonCard(height: 220);
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

class _Steps extends StatelessWidget {
  const _Steps();

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

class _ReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDonate;
  final VoidCallback onOpen;
  const _ReportCard({
    required this.report,
    required this.onDonate,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    Widget meta(IconData icon, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: cs.onSurfaceVariant),
        Gaps.h4,
        Flexible(
          child: Text(
            text,
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
    return AppCard(
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
              PriorityChip(r['priority_level'] as String?),
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
                meta(
                  Icons.groups_outlined,
                  '${r['affected_families']} families',
                ),
            ],
          ),
          if (_splitNeeds(r['assistance_needed']).isNotEmpty) ...[
            Gaps.v8,
            _NeedChips(r['assistance_needed']),
          ],
          if ((r['priority_guidance'] ?? '').toString().isNotEmpty) ...[
            Gaps.v8,
            Text(
              r['priority_guidance'].toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
          Gaps.v12,
          FulfillmentBar(
            delivered: r['total_items_delivered'] as num? ?? 0,
            needed: r['total_items_needed'] as num? ?? 0,
            percent: r['fulfillment_percentage'] as num?,
          ),
          Gaps.v12,
          Row(
            children: [
              Expanded(
                child: AppButton(
                  'Donate',
                  icon: Icons.volunteer_activism_outlined,
                  variant: AppButtonVariant.donate,
                  expand: true,
                  onPressed: onDonate,
                ),
              ),
              Gaps.h8,
              OutlinedButton(onPressed: onOpen, child: const Text('Details')),
            ],
          ),
        ],
      ),
    );
  }
}

/// Same split as Report.needs in report_model.dart:
/// "Water, ready-to-eat food" -> ['Water', 'ready-to-eat food']
List<String> _splitNeeds(Object? raw) => (raw ?? '')
    .toString()
    .split(',')
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty)
    .toList();

class _NeedChips extends StatelessWidget {
  final Object? raw;
  const _NeedChips(this.raw);

  @override
  Widget build(BuildContext context) {
    final needs = _splitNeeds(raw);
    if (needs.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: [
        for (final n in needs)
          Chip(label: Text(n), visualDensity: VisualDensity.compact),
      ],
    );
  }
}

/// "How priority works": mirrors core/priority_engine.py. If the weights or
/// thresholds change there, update this too.
class _PriorityGuide extends StatelessWidget {
  const _PriorityGuide();

  static const _levels = [
    ('Critical', 'Score 80 to 100', 'Needs help immediately.'),
    ('High', 'Score 60 to 79', 'Needs help soon.'),
    ('Medium', 'Score 35 to 59', 'Needs help, but is less urgent.'),
    ('Low', 'Score below 35', 'Lower urgency. Cover other reports first.'),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(
          'How priority works',
          subtitle: 'AI-assisted guidance for where help is needed first.',
        ),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Each validated report is scored from four things: families '
                'affected (30%), how much is needed (20%), the severity of '
                'the disaster (25%), and how much is still undelivered (25%).',
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v12,
              for (final l in _levels) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    SizedBox(width: 92, child: PriorityChip(l.$1)),
                    Gaps.h12,
                    Expanded(
                      child: Text('${l.$2}. ${l.$3}', style: t.bodyMedium),
                    ),
                  ],
                ),
                Gaps.v8,
              ],
            ],
          ),
        ),
      ],
    );
  }
}
