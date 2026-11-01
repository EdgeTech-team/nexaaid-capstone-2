import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../disaster_art.dart';
import 'landing_extras.dart' show kImpactImage;
import 'landing_sections.dart'
    show LandingWidth, LandingEyebrow, LandingTitle, landingWide;
import 'public_data.dart' show PublicStats;

// Landing page redesign (Oct 26 mockup, "NexaAid landing page redesign"):
// a rounded teal hero with the most urgent reports, an About block with a
// photo collage, and four trust cards. The rest of the page (impact, how it
// works, report cards, FAQ) stays in landing_sections.dart.

// ---------------------------------------------------------------------------
// Hero: rounded teal banner + the 3 most urgent reports, one at a time
// ---------------------------------------------------------------------------

class LandingHeroBanner extends StatefulWidget {
  /// Validated reports, most urgent first (the first 3 are shown).
  final List<Map<String, dynamic>> reports;
  final bool loading;
  final VoidCallback onLogIn;
  final VoidCallback onCreateAccount;
  final VoidCallback onDonateAsGuest;
  final void Function(Map<String, dynamic> report) onDonate;
  final void Function(Map<String, dynamic> report) onOpen;

  const LandingHeroBanner({
    super.key,
    required this.reports,
    required this.loading,
    required this.onLogIn,
    required this.onCreateAccount,
    required this.onDonateAsGuest,
    required this.onDonate,
    required this.onOpen,
  });

  @override
  State<LandingHeroBanner> createState() => _LandingHeroBannerState();
}

class _LandingHeroBannerState extends State<LandingHeroBanner> {
  int _index = 0;

  List<Map<String, dynamic>> get _urgent => widget.reports.take(3).toList();

  void _move(int step) {
    final n = _urgent.length;
    if (n == 0) return;
    setState(() => _index = (_index + step + n) % n);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wide = landingWide(context);
    final urgent = _urgent;
    final i = urgent.isEmpty ? 0 : _index.clamp(0, urgent.length - 1);

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.vest,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
          child: Text(
            'Mandaue City disaster relief',
            style: t.labelLarge?.copyWith(
              color: AppColors.vestInk,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Gaps.v16,
        Semantics(
          header: true,
          child: Text(
            'Get relief to the barangays that need it most',
            style: (wide ? t.displaySmall : t.headlineMedium)?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              height: 1.1,
            ),
          ),
        ),
        Gaps.v12,
        Text(
          'See which barangays the City has checked and what they still '
          'need. Pledge food, water or supplies, then follow your donation '
          'until it reaches the families.',
          style: (wide ? t.titleMedium : t.bodyLarge)?.copyWith(
            color: AppColors.harborMist,
            fontWeight: FontWeight.w400,
          ),
        ),
        Gaps.v24,
        // Team notes: Register and Log in sit above (and stand out more
        // than) Donate as guest. Short label on narrow screens.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: LayoutBuilder(
            builder: (context, box) {
              final short = box.maxWidth < 500;
              return Row(
                children: [
                  Expanded(
                    flex: short ? 1 : 3,
                    child: FilledButton.icon(
                      onPressed: widget.onCreateAccount,
                      icon: const Icon(Icons.favorite_border),
                      label: Text(
                        short ? 'Register' : 'Register as donor or organization',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.vest,
                        foregroundColor: AppColors.vestInk,
                        minimumSize: const Size(0, 52),
                      ),
                    ),
                  ),
                  Gaps.h12,
                  Expanded(
                    flex: short ? 1 : 2,
                    child: OutlinedButton.icon(
                      onPressed: widget.onLogIn,
                      icon: const Icon(Icons.login),
                      label: const Text('Log in'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(
                          color: AppColors.harborMist,
                          width: 1.5,
                        ),
                        minimumSize: const Size(0, 52),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Gaps.v8,
        TextButton(
          onPressed: widget.onDonateAsGuest,
          style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Donate as guest',
                style: t.labelLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                ' · no account needed',
                style: t.bodyMedium?.copyWith(color: AppColors.harborMist),
              ),
            ],
          ),
        ),
        Gaps.v16,
        Wrap(
          spacing: Space.md,
          runSpacing: Space.xs,
          children: const [
            _HeroCheck('Reports checked by the City'),
            _HeroCheck('A QR code for every pledge'),
            _HeroCheck('Goods only, no money'),
          ],
        ),
      ],
    );

    final Widget card;
    if (widget.loading) {
      card = const SkeletonCard(height: 360);
    } else if (urgent.isEmpty) {
      card = const _NoUrgentCard();
    } else {
      card = _UrgentCard(
        report: urgent[i],
        rank: i + 1,
        total: urgent.length,
        onDonate: () => widget.onDonate(urgent[i]),
        onOpen: () => widget.onOpen(urgent[i]),
      );
    }

    final controls = urgent.length < 2
        ? const SizedBox.shrink()
        : Row(
            children: [
              _RoundButton(
                icon: Icons.chevron_left,
                label: 'Previous urgent report',
                background: Colors.white,
                foreground: AppColors.harborDeep,
                onPressed: () => _move(-1),
              ),
              Gaps.h8,
              _RoundButton(
                icon: Icons.chevron_right,
                label: 'Next urgent report',
                background: AppColors.vest,
                foreground: AppColors.vestInk,
                onPressed: () => _move(1),
              ),
              Gaps.h12,
              for (var k = 0; k < urgent.length; k++)
                AnimatedContainer(
                  duration: Motion.normal,
                  margin: const EdgeInsets.only(right: 6),
                  width: k == i ? 28 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: k == i ? AppColors.vest : AppColors.harbor,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
            ],
          );

    return Padding(
      padding: EdgeInsets.only(top: wide ? Space.lg : Space.md),
      child: LandingWidth(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(wide ? 28 : 24),
          child: ColoredBox(
            color: AppColors.harborDeep,
            child: Stack(
              children: [
                // Two flat circles for depth (no gradients).
                Positioned(
                  right: -120,
                  top: -120,
                  child: Container(
                    width: 420,
                    height: 420,
                    decoration: const BoxDecoration(
                      color: AppColors.harbor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                Positioned(
                  left: -80,
                  bottom: -140,
                  child: Container(
                    width: 260,
                    height: 260,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: AppColors.harbor, width: 36),
                    ),
                  ),
                ),
                Padding(
                  padding: wide
                      ? const EdgeInsets.fromLTRB(48, 56, 48, 32)
                      : const EdgeInsets.fromLTRB(20, 28, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (wide)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Expanded(flex: 6, child: text),
                            const SizedBox(width: 40),
                            Expanded(flex: 5, child: card),
                          ],
                        )
                      else ...[
                        text,
                        Gaps.v24,
                        card,
                      ],
                      Gaps.v16,
                      controls,
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroCheck extends StatelessWidget {
  final String text;
  const _HeroCheck(this.text);

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      const Icon(Icons.check, size: 16, color: AppColors.vest),
      Gaps.h4,
      Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: AppColors.harborMist),
      ),
    ],
  );
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;
  final VoidCallback onPressed;
  const _RoundButton({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: onPressed,
    tooltip: label,
    icon: Icon(icon),
    style: IconButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      minimumSize: const Size(44, 44),
    ),
  );
}

/// One urgent report inside the hero.
class _UrgentCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final int rank;
  final int total;
  final VoidCallback onDonate;
  final VoidCallback onOpen;
  const _UrgentCard({
    required this.report,
    required this.rank,
    required this.total,
    required this.onDonate,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final disaster = '${r['disaster'] ?? 'Disaster'}';
    final barangay = '${r['barangay'] ?? '-'}';
    final families = (r['affected_families'] as num?)?.toInt();
    final needs = '${r['assistance_needed'] ?? ''}'.trim();
    return Material(
      color: cs.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Stack(
              children: [
                DisasterArt(disasterKind(disaster), height: 160),
                Positioned(
                  left: 12,
                  top: 12,
                  child: _OnArt(child: PriorityChip(r['priority_level'] as String?)),
                ),
                Positioned(
                  right: 12,
                  top: 12,
                  child: _OnArt(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      child: Text(
                        total > 1 ? 'Most urgent $rank of $total' : 'Most urgent',
                        style: t.labelMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    families == null
                        ? barangay
                        : '$barangay · $families families affected',
                    style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  Gaps.v4,
                  Text(
                    '$disaster in $barangay',
                    style: t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (needs.isNotEmpty) ...[
                    Gaps.v4,
                    Text(
                      'Needs: $needs',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                  Gaps.v12,
                  FulfillmentBar(
                    delivered: r['total_items_delivered'] as num? ?? 0,
                    needed: r['total_items_needed'] as num? ?? 0,
                    percent: num.tryParse('${r['fulfillment_percentage'] ?? ''}'),
                  ),
                  Gaps.v12,
                  AppButton(
                    'Donate now',
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

/// White pill behind a label drawn over the illustration, so it stays
/// readable on any picture.
class _OnArt extends StatelessWidget {
  final Widget child;
  const _OnArt({required this.child});

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
    child: child,
  );
}

class _NoUrgentCard extends StatelessWidget {
  const _NoUrgentCard();

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLowest,
    borderRadius: BorderRadius.circular(22),
    child: const Padding(
      padding: EdgeInsets.all(Space.md),
      child: EmptyView(
        compact: true,
        icon: Icons.verified_outlined,
        title: 'No reports need help right now',
        message:
            'When the City validates a disaster report, it shows up here so '
            'you can donate.',
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// About NexaAid: text + photo collage + live "reports need help" badge
// ---------------------------------------------------------------------------

class LandingAboutCollage extends StatelessWidget {
  final PublicStats? stats;
  final VoidCallback onHowItWorks;
  const LandingAboutCollage({
    super.key,
    required this.stats,
    required this.onHowItWorks,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);
    // Not "families covered": the impact numbers below already show that.
    final active = stats?.activeReports;

    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingEyebrow('About NexaAid'),
        Gaps.v8,
        const LandingTitle('One place for donors and the City\'s relief offices'),
        Gaps.v12,
        Text(
          'NexaAid connects donors with the barangays of Mandaue City after a '
          'disaster. The CSWS Disaster Unit reports what each barangay needs, '
          'the City checks it, and you choose where your goods go.',
          style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
        ),
        Gaps.v8,
        Text(
          'CSWS receives your pledge, the City Mayor\'s Office acknowledges it, '
          'and the barangay confirms when it arrives. You can follow every '
          'step.',
          style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
        ),
        Gaps.v16,
        OutlinedButton(
          onPressed: onHowItWorks,
          style: OutlinedButton.styleFrom(minimumSize: const Size(0, 48)),
          child: const Text('See how it works'),
        ),
      ],
    );

    final height = wide ? 420.0 : 300.0;
    final badge = wide ? 132.0 : 108.0;
    final collage = SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            width: wide ? 330 : 220,
            height: height * 0.72,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.asset(
                kImpactImage,
                fit: BoxFit.cover,
                semanticLabel:
                    'Volunteers handing out relief goods to families in a '
                    'barangay',
                errorBuilder: (_, _, _) =>
                    ColoredBox(color: cs.surfaceContainerHigh),
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            width: wide ? 280 : 190,
            height: height * 0.6,
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: cs.surface,
                borderRadius: BorderRadius.circular(22),
              ),
              child: const DisasterArt(
                DisasterKind.other,
                height: double.infinity,
                borderRadius: BorderRadius.all(Radius.circular(16)),
              ),
            ),
          ),
          Positioned(
            left: wide ? 230 : 140,
            top: height * 0.72 - badge / 2,
            width: badge,
            height: badge,
            child: Semantics(
              label:
                  '${active ?? 'Loading'} reports need help right now',
              excludeSemantics: true,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.vest,
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.surface, width: 6),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      active == null ? '–' : '$active',
                      style: (wide ? t.headlineMedium : t.titleLarge)?.copyWith(
                        color: AppColors.vestInk,
                        fontWeight: FontWeight.w700,
                        height: 1,
                      ),
                    ),
                    Text(
                      'reports\nneed help',
                      textAlign: TextAlign.center,
                      style: t.labelMedium?.copyWith(
                        color: AppColors.vestInk,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );

    return LandingWidth(
      padding: EdgeInsets.symmetric(vertical: wide ? 80 : Space.xl + 4),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: text),
                const SizedBox(width: 48),
                Expanded(child: collage),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [text, Gaps.v24, collage],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Why you can trust it: four cards
// ---------------------------------------------------------------------------

class LandingTrustCards extends StatelessWidget {
  const LandingTrustCards({super.key});

  static const _cards = [
    (
      Icons.verified_user_outlined,
      'Checked by the City',
      'Only reports the administrator validated appear here.',
    ),
    (
      Icons.priority_high,
      'Priority guidance',
      'Critical reports come first, so the most urgent barangays get help '
          'sooner.',
    ),
    (
      Icons.qr_code_2,
      'A QR code for every pledge',
      'CSWS scans it and records what actually arrived.',
    ),
    (
      Icons.task_alt,
      'Confirmed by the barangay',
      'You see when the barangay confirms your goods arrived.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);
    final width = MediaQuery.sizeOf(context).width;
    final columns = wide ? 4 : (width >= 600 ? 2 : 1);

    Widget card((IconData, String, String) c) => AppCard(
      padding: const EdgeInsets.all(Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(c.$1, color: cs.onPrimaryContainer, size: 26),
          ),
          Gaps.v12,
          Text(c.$2, style: t.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          Gaps.v4,
          Text(c.$3, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );

    final rows = <Widget>[];
    for (var start = 0; start < _cards.length; start += columns) {
      final slice = _cards.skip(start).take(columns).toList();
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var k = 0; k < slice.length; k++) ...[
                if (k > 0) Gaps.h16,
                Expanded(child: card(slice[k])),
              ],
            ],
          ),
        ),
      );
      if (start + columns < _cards.length) rows.add(Gaps.v16);
    }

    return LandingWidth(
      padding: EdgeInsets.only(bottom: wide ? 80 : Space.xl + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: LandingEyebrow('Why you can trust it')),
          Gaps.v8,
          const LandingTitle(
            'Every pledge is checked, tracked and confirmed',
            align: TextAlign.center,
          ),
          Gaps.v24,
          ...rows,
        ],
      ),
    );
  }
}