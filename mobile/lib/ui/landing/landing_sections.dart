import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../needs_progress.dart';
import '../report_summary_card.dart' show NeedChips;
import '../theme_toggle.dart';
import '../widgets.dart' show api;
import 'landing_extras.dart' show kImpactImage;
import 'public_data.dart';

// Landing page redesign (approved mockups, Oct 12): a pinned header with
// the section links, the headline with a photo, "Our impact so far", an
// interactive "How it works", the report cards (same card as the signed-in
// report lists), questions that open one at a time, and a closing band.
// Colors come from the theme (light and dark) and the design tokens.

/// Widest the landing content gets on Chrome.
const double kLandingMax = 1200;

/// Two columns from tablet width up, one column on phones.
bool landingWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= Breakpoints.expanded;

String _fmt(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

Duration _motion(BuildContext context, [Duration d = Motion.normal]) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : d;

/// A theme color for large numbers and icons that reads well on both
/// backgrounds: the life-vest yellow is too light on white, so it is
/// darkened in light mode.
Color landingVest(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? AppColors.vest
    : Color.lerp(AppColors.vest, AppColors.vestInk, 0.45)!;

Color landingSuccess(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? Color.lerp(AppColors.success, Colors.white, 0.3)!
    : AppColors.success;

/// Centers a section at [kLandingMax] with side padding.
class LandingWidth extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double maxWidth;
  const LandingWidth({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.maxWidth = kLandingMax,
  });

  @override
  Widget build(BuildContext context) {
    final side = landingWide(context) ? Space.lg : Space.md + 4;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: side).add(padding),
          child: child,
        ),
      ),
    );
  }
}

/// Small label above a section title, e.g. "OUR IMPACT SO FAR".
class LandingEyebrow extends StatelessWidget {
  final String text;
  const LandingEyebrow(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Semantics(
    label: text,
    excludeSemantics: true,
    child: Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    ),
  );
}

/// Section title: [before] [accent] [after], the accent in the primary color.
class LandingTitle extends StatelessWidget {
  final String before;
  final String accent;
  final String after;
  final TextAlign? align;
  const LandingTitle(
    this.before, {
    super.key,
    this.accent = '',
    this.after = '',
    this.align,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);
    return Semantics(
      header: true,
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: before),
            if (accent.isNotEmpty)
              TextSpan(
                text: accent,
                style: TextStyle(color: cs.primary),
              ),
            if (after.isNotEmpty) TextSpan(text: after),
          ],
        ),
        textAlign: align,
        style: (wide ? t.headlineLarge : t.headlineSmall)?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
      ),
    );
  }
}

/// Muted line under a section title.
class _Subtitle extends StatelessWidget {
  final String text;
  const _Subtitle(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.bodyLarge
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
  );
}

/// Rounded panel used by the cards of the landing sections.
class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Panel({
    required this.child,
    this.padding = const EdgeInsets.all(Space.lg),
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: child,
    );
  }
}

/// Small rounded square with a tinted icon (trust rows, deliveries).
class _IconSquare extends StatelessWidget {
  final IconData icon;
  final Color color;
  const _IconSquare(this.icon, this.color);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.2 : 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Icon(icon, size: 20, color: color),
    );
  }
}

// ---------------------------------------------------------------------------
// Header: pinned, with the section links at every width
// ---------------------------------------------------------------------------

/// The sections the header links scroll to.
enum LandingSection {
  impact('Impact'),
  how('How it works'),
  reports('Reports'),
  questions('Questions');

  final String label;
  const LandingSection(this.label);
}

class LandingHeader extends StatelessWidget {
  final ValueChanged<LandingSection> onJump;

  /// The section in view, highlighted in the links (null = the hero).
  final LandingSection? current;

  const LandingHeader({super.key, required this.onJump, this.current});

  /// Height of the header below the status bar.
  static double heightFor(BuildContext context) =>
      landingWide(context) ? 68 : 104;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final wide = landingWide(context);

    final brand = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: AppColors.harbor,
            borderRadius: BorderRadius.circular(Radii.sm + 2),
          ),
          child: const Icon(
            Icons.volunteer_activism,
            size: 20,
            color: Colors.white,
          ),
        ),
        Gaps.h12,
        Text(
          'NexaAid',
          style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    );

    final Widget content;
    if (wide) {
      content = Row(
        children: [
          brand,
          const Spacer(),
          for (final s in LandingSection.values)
            _NavLink(
              label: s.label,
              selected: current == s,
              onTap: () => onJump(s),
            ),
          Gaps.h8,
          // Rightmost (Ivan's note).
          const SunMoonToggle(),
        ],
      );
    } else {
      // Phones (Oct 12): the links sit beside the sun/moon button, and they
      // share the row width so there is nothing to scroll sideways.
      content = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 44, child: brand),
          SizedBox(
            height: 48,
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      for (final s in LandingSection.values) ...[
                        if (s.index > 0) const SizedBox(width: 6),
                        Expanded(
                          flex: s.label.length + 2,
                          child: _NavPill(
                            label: s.label,
                            selected: current == s,
                            onTap: () => onJump(s),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Gaps.h8,
                const SunMoonToggle(),
              ],
            ),
          ),
        ],
      );
    }

    return Material(
      color: cs.surfaceContainerLowest,
      child: SafeArea(
        bottom: false,
        child: Container(
          height: heightFor(context),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: cs.outlineVariant)),
          ),
          child: LandingWidth(
            padding: EdgeInsets.symmetric(vertical: wide ? Space.xs : 4),
            child: content,
          ),
        ),
      ),
    );
  }
}

/// Wide header link: a text button, primary and underlined when selected.
class _NavLink extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavLink({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          minimumSize: const Size(0, 44),
          foregroundColor: selected ? cs.primary : cs.onSurface,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label),
            AnimatedContainer(
              duration: _motion(context),
              margin: const EdgeInsets.only(top: 2),
              height: 2,
              width: selected ? 24 : 0,
              color: cs.primary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Phone header link: plain text (no button look), primary and underlined
/// when its section is in view. The tap area is 44 px tall.
class _NavPill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _NavPill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: SizedBox(
          height: 44,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: t.labelLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected ? cs.primary : cs.onSurface,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: _motion(context),
                margin: const EdgeInsets.only(top: 2),
                height: 2,
                width: selected ? 20 : 0,
                color: cs.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero: headline, photo and the ways in
// ---------------------------------------------------------------------------

class LandingHero extends StatelessWidget {
  final VoidCallback onLogIn;
  final VoidCallback onCreateAccount;
  final VoidCallback onDonateAsGuest;

  const LandingHero({
    super.key,
    required this.onLogIn,
    required this.onCreateAccount,
    required this.onDonateAsGuest,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);

    final pill = Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Text(
          'Mandaue City disaster relief',
          style: t.labelLarge?.copyWith(
            color: cs.onPrimaryContainer,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );

    final big = wide ? t.displayMedium : t.headlineLarge;
    final headline = Semantics(
      header: true,
      child: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'Get relief to the '),
            TextSpan(
              text: 'barangays',
              style: TextStyle(color: cs.primary),
            ),
            const TextSpan(text: ' that need it '),
            WidgetSpan(
              alignment: PlaceholderAlignment.baseline,
              baseline: TextBaseline.alphabetic,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: AppColors.vest,
                  borderRadius: BorderRadius.circular(Radii.md),
                ),
                child: Text(
                  'most',
                  style: big?.copyWith(
                    color: AppColors.vestInk,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
              ),
            ),
          ],
        ),
        style: big?.copyWith(fontWeight: FontWeight.w700, height: 1.15),
      ),
    );

    final intro = Text(
      'See which barangays the City has checked and what they still need. '
      'Pledge food, water or supplies, then follow your donation until it '
      'reaches the families.',
      style: (wide ? t.titleMedium : t.bodyLarge)?.copyWith(
        color: cs.onSurfaceVariant,
        fontWeight: FontWeight.w400,
      ),
    );

    // Register (yellow) and Log in (outlined) side by side.
    final buttons = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: LayoutBuilder(
        builder: (context, box) {
          final short = box.maxWidth < 500;
          return Row(
            children: [
              Expanded(
                flex: short ? 1 : 3,
                child: AppButton(
                  short ? 'Register' : 'Register as donor or organization',
                  icon: Icons.favorite_border,
                  variant: AppButtonVariant.donate,
                  large: true,
                  expand: true,
                  onPressed: onCreateAccount,
                ),
              ),
              Gaps.h12,
              Expanded(
                flex: short ? 1 : 2,
                child: OutlinedButton.icon(
                  onPressed: onLogIn,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: cs.primary,
                    side: BorderSide(color: cs.primary, width: 1.5),
                    minimumSize: const Size(double.infinity, 56),
                  ),
                  icon: const Icon(Icons.login),
                  label: const Text('Log in'),
                ),
              ),
            ],
          );
        },
      ),
    );

    final guest = TextButton(
      onPressed: onDonateAsGuest,
      style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
      // Wraps instead of overflowing on narrow phones.
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.center,
        children: [
          Text(
            'Donate as guest',
            style: t.labelLarge?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          Text(
            ' · no account needed',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          Gaps.h4,
          Icon(Icons.arrow_forward, size: 16, color: cs.primary),
        ],
      ),
    );

    final trust = Wrap(
      spacing: Space.md,
      runSpacing: Space.xxs,
      alignment: wide ? WrapAlignment.start : WrapAlignment.center,
      children: [
        for (final line in const [
          'Reports checked by the City',
          'A QR code for every pledge',
          'Goods only, no money',
        ])
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check, size: 16, color: landingSuccess(context)),
              Gaps.h4,
              Flexible(
                child: Text(
                  line,
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
      ],
    );

    final photo = _HeroPhoto(height: wide ? 440 : 230);

    if (wide) {
      return LandingWidth(
        padding: const EdgeInsets.only(top: Space.xxl + 16, bottom: 72),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  pill,
                  Gaps.v24,
                  headline,
                  Gaps.v24,
                  intro,
                  Gaps.v32,
                  buttons,
                  Gaps.v12,
                  guest,
                  Gaps.v12,
                  trust,
                ],
              ),
            ),
            const SizedBox(width: Space.xxl),
            Expanded(child: photo),
          ],
        ),
      );
    }
    return LandingWidth(
      padding: const EdgeInsets.only(top: Space.lg + 4, bottom: Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          pill,
          Gaps.v16,
          headline,
          Gaps.v16,
          intro,
          Gaps.v24,
          // Buttons before the photo so they are on the first screen.
          Align(child: buttons),
          Gaps.v8,
          Center(child: guest),
          Gaps.v8,
          trust,
          Gaps.v24,
          photo,
        ],
      ),
    );
  }
}

/// The relief photo with a "Checked by the City" badge on it.
class _HeroPhoto extends StatelessWidget {
  final double height;
  const _HeroPhoto({required this.height});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final big = height > 300;
    return SizedBox(
      height: height,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(big ? 28 : 22),
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
            left: big ? Space.md : Space.sm,
            bottom: big ? Space.lg : Space.sm,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: big ? 16 : 12,
                vertical: big ? 12 : 8,
              ),
              decoration: BoxDecoration(
                color: cs.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(Radii.lg),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.harborDeep.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: big ? 20 : 14,
                    backgroundColor: AppColors.success,
                    child: Icon(
                      Icons.check,
                      size: big ? 22 : 16,
                      color: Colors.white,
                    ),
                  ),
                  Gaps.h12,
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Checked by the City', style: t.titleSmall),
                      if (big)
                        Text(
                          'Every report is validated by CSWS',
                          style: t.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 1: Our impact so far
// ---------------------------------------------------------------------------

class LandingImpactSection extends StatelessWidget {
  final PublicStats? stats;
  final DateTime? asOf;

  const LandingImpactSection({super.key, required this.stats, this.asOf});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);
    final s = stats;
    String n(int? v) => s == null ? '–' : _fmt(v ?? 0);
    final deliveries = s?.deliveriesCompleted ?? 0;
    final reached = s?.barangaysReached ?? 0;

    final tiles = [
      _ImpactTile(
        number: n(s?.familiesAffected),
        label: 'Families covered',
        note: 'by reports the City validated',
        color: cs.primary,
      ),
      _ImpactTile(
        number: n(s?.donationsReceived),
        label: 'Donated items received',
        note: 'checked in by CSWS',
        color: landingVest(context),
      ),
      _ImpactTile(
        number: n(s?.deliveriesCompleted),
        label: deliveries == 1 ? 'Delivery completed' : 'Deliveries completed',
        note: 'confirmed by the barangay',
        color: landingSuccess(context),
      ),
      _ImpactTile(
        number: n(s?.barangaysReached),
        label: reached == 1 ? 'Barangay reached' : 'Barangays reached',
        note: 'with at least one delivery',
        color: cs.onSurface,
      ),
    ];

    final asOfLine = asOf == null
        ? const SizedBox.shrink()
        : Wrap(
            spacing: Space.xs,
            runSpacing: Space.xxs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: landingSuccess(context),
                  shape: BoxShape.circle,
                ),
              ),
              Text(
                'As of ${formatAsOf(asOf!)}',
                style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (kDemoData) const LandingDemoBadge(),
            ],
          );

    final heading = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingEyebrow('Our impact so far'),
        Gaps.v8,
        const LandingTitle('Every pledge is counted until it reaches a family'),
        Gaps.v8,
        const _Subtitle(
          'Numbers come straight from NexaAid records, not estimates.',
        ),
      ],
    );

    // Reloads with the rest of the page (pull to refresh).
    final recent = _RecentDeliveriesCard(key: ValueKey(asOf));
    final cards = wide
        ? IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 3, child: recent),
                Gaps.h16,
                const Expanded(flex: 2, child: _WhyTrustCard()),
              ],
            ),
          )
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [recent, Gaps.v16, const _WhyTrustCard()],
          );

    return Material(
      color: cs.surfaceContainerLowest,
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: cs.outlineVariant)),
        ),
        child: LandingWidth(
          padding: EdgeInsets.symmetric(vertical: wide ? 80 : Space.xl + 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(child: heading),
                    Gaps.h16,
                    asOfLine,
                  ],
                )
              else ...[
                heading,
                Gaps.v12,
                asOfLine,
              ],
              Gaps.v24,
              _EvenGrid(columns: wide ? 4 : 2, gap: Space.sm, children: tiles),
              Gaps.v16,
              cards,
            ],
          ),
        ),
      ),
    );
  }
}

/// "Demo data" label while the numbers come from test data.
class LandingDemoBadge extends StatelessWidget {
  const LandingDemoBadge({super.key});

  @override
  Widget build(BuildContext context) => const Tooltip(
    message: 'These numbers come from test data, not real donations.',
    child: StatusChip('On Hold', label: 'Demo data', showIcon: false),
  );
}

/// Rows of [columns] equal-width, equal-height cells.
class _EvenGrid extends StatelessWidget {
  final int columns;
  final double gap;
  final List<Widget> children;
  const _EvenGrid({
    required this.columns,
    required this.gap,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final cols = columns < 1 ? 1 : columns;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var start = 0; start < children.length; start += cols) ...[
          if (start > 0) SizedBox(height: gap),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = start; i < start + cols; i++) ...[
                  if (i > start) SizedBox(width: gap),
                  Expanded(
                    child: i < children.length
                        ? children[i]
                        : const SizedBox.shrink(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _ImpactTile extends StatelessWidget {
  final String number;
  final String label;
  final String note;
  final Color color;
  const _ImpactTile({
    required this.number,
    required this.label,
    required this.note,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: '$number $label, $note',
      excludeSemantics: true,
      child: _Panel(
        padding: const EdgeInsets.all(Space.md + 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                number,
                style: t.headlineLarge?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Gaps.v4,
            Text(
              label,
              style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            Gaps.v4,
            Text(
              note,
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// Latest deliveries confirmed by barangays (GET /public/recent-deliveries,
/// newest first, max 5). Only the goods and the barangay, never donors.
class _RecentDeliveriesCard extends StatefulWidget {
  const _RecentDeliveriesCard({super.key});

  @override
  State<_RecentDeliveriesCard> createState() => _RecentDeliveriesCardState();
}

class _RecentDeliveriesCardState extends State<_RecentDeliveriesCard> {
  late final Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final r = await api.get('/public/recent-deliveries');
    if (!r.ok || r.json is! List) return const [];
    return [
      for (final e in (r.json as List).take(5))
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// "Oct 11, 2026 · 11:51 PM"
  static String _when(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    if (d == null) return 'Confirmed by the barangay';
    return formatAsOf(d).replaceFirst('${d.year}, ', '${d.year} · ');
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = t.bodySmall?.copyWith(color: cs.onSurfaceVariant);
    final green = landingSuccess(context);
    return _Panel(
      child: FutureBuilder<List<Map<String, dynamic>>>(
        future: _future,
        builder: (context, snap) {
          final items = snap.data ?? const [];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Space.sm,
                children: [
                  Text('Recently delivered', style: t.titleMedium),
                  Text('Confirmed by the barangay', style: muted),
                ],
              ),
              Gaps.v16,
              if (snap.connectionState != ConnectionState.done)
                for (var i = 0; i < 3; i++)
                  const Padding(
                    padding: EdgeInsets.only(bottom: Space.sm),
                    child: Skeleton(height: 40),
                  )
              else if (items.isEmpty)
                Text(
                  'No deliveries confirmed yet. They appear here once a '
                  'barangay confirms receipt.',
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                )
              else
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(height: Space.lg),
                  Row(
                    children: [
                      _IconSquare(Icons.home_outlined, green),
                      Gaps.h12,
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text.rich(
                              TextSpan(
                                children: [
                                  TextSpan(
                                    text:
                                        '${items[i]['summary'] ?? 'Relief goods'}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  TextSpan(
                                    text: ' to ',
                                    style: TextStyle(
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                  TextSpan(
                                    text:
                                        'Barangay ${items[i]['barangay'] ?? '-'}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              style: t.bodyMedium,
                            ),
                            Text(_when(items[i]['confirmed_at']), style: muted),
                          ],
                        ),
                      ),
                      Gaps.h8,
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: green.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(Radii.pill),
                        ),
                        child: Text(
                          'Arrived',
                          style: t.labelMedium?.copyWith(
                            color: green,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              Gaps.v16,
              Text(
                'Only the goods and the barangay are shown. Donor names stay '
                'private.',
                style: muted,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WhyTrustCard extends StatelessWidget {
  const _WhyTrustCard();

  static const _rows = [
    (
      Icons.verified_user_outlined,
      'The City checks every report',
      'Only reports the administrator validated appear here.',
    ),
    (
      Icons.qr_code_2,
      'Every pledge has a QR code',
      'CSWS scans it and records what actually arrived.',
    ),
    (
      Icons.card_giftcard,
      'Goods only, no money',
      'NexaAid never collects or holds cash.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Why donors trust it', style: t.titleMedium),
          Gaps.v16,
          for (var i = 0; i < _rows.length; i++) ...[
            if (i > 0) Gaps.v16,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _IconSquare(_rows[i].$1, cs.primary),
                Gaps.h12,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _rows[i].$2,
                        style: t.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Gaps.v4,
                      Text(
                        _rows[i].$3,
                        style: t.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 2: How it works (tap a step to see the details)
// ---------------------------------------------------------------------------

class LandingHowItWorks extends StatefulWidget {
  /// "See reports that need help": scrolls to the reports.
  final VoidCallback onSeeReports;
  final VoidCallback onDonateAsGuest;

  const LandingHowItWorks({
    super.key,
    required this.onSeeReports,
    required this.onDonateAsGuest,
  });

  /// (title, short label for phones, question, paragraph 1, paragraph 2)
  static const steps = [
    (
      'Pick a report',
      'Pick a report',
      'How do I choose where to help?',
      'Every report here was checked by the City first. Each one shows the '
          'barangay, how many families are affected, what they still need and '
          'how close it is to complete.',
      'Critical reports are listed first, so the most urgent barangays get '
          'help sooner.',
    ),
    (
      'Pledge your items',
      'Pledge items',
      'What can I give?',
      'Choose the items the report asks for, like food, water, clothing, '
          'sleeping mats or medicine kits, and how many you can give.',
      'Register to keep a history of your donations, or donate as a guest '
          'with no account. NexaAid handles goods only, never money.',
    ),
    (
      'Hand them over',
      'Hand over',
      'How do the goods reach CSWS?',
      'Bring them to the CSWS Main Office, or ask for a door-to-door pickup. '
          'Either way you get a QR code for your donation.',
      'CSWS scans the code, checks the goods and records what actually '
          'arrived.',
    ),
    (
      'Follow it to the families',
      'Follow it',
      'How do I know it arrived?',
      'You see each step with its date, from your pledge to the barangay.',
      'The last step is confirmed by the barangay itself, not by us.',
    ),
  ];

  /// The donation status steps shown on step 4.
  static const statuses = [
    'Pledged',
    'Received by CSWS',
    'Confirmed by the City',
    'Out for delivery',
    'Received by the barangay',
  ];

  @override
  State<LandingHowItWorks> createState() => _LandingHowItWorksState();
}

class _LandingHowItWorksState extends State<LandingHowItWorks> {
  int _step = 0;

  void _select(int i) => setState(() => _step = i);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wide = landingWide(context);

    final heading = Column(
      children: [
        const LandingTitle('How it works', align: TextAlign.center),
        Gaps.v12,
        Container(
          width: 72,
          height: 3,
          decoration: BoxDecoration(
            color: AppColors.vest,
            borderRadius: BorderRadius.circular(Radii.pill),
          ),
        ),
        Gaps.v12,
        Text(
          "Four steps from your pledge to a family's door. Tap a step to see "
          'the details.',
          textAlign: TextAlign.center,
          style: t.bodyLarge?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    final panel = AnimatedSwitcher(
      duration: _motion(context),
      switchInCurve: Motion.curve,
      child: _StepPanel(
        key: ValueKey(_step),
        index: _step,
        onSeeReports: widget.onSeeReports,
        onDonateAsGuest: widget.onDonateAsGuest,
      ),
    );

    final Widget body;
    if (wide) {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < LandingHowItWorks.steps.length; i++) ...[
                  if (i > 0) Gaps.v8,
                  _StepButton(
                    index: i,
                    title: LandingHowItWorks.steps[i].$1,
                    selected: _step == i,
                    onTap: () => _select(i),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Space.lg),
          Expanded(flex: 3, child: panel),
        ],
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < LandingHowItWorks.steps.length; i++)
                Expanded(
                  child: _StepColumn(
                    index: i,
                    label: LandingHowItWorks.steps[i].$2,
                    selected: _step == i,
                    onTap: () => _select(i),
                  ),
                ),
            ],
          ),
          Gaps.v16,
          panel,
        ],
      );
    }

    return LandingWidth(
      padding: EdgeInsets.symmetric(vertical: wide ? 80 : Space.xl + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          SizedBox(height: wide ? 48 : 24),
          body,
        ],
      ),
    );
  }
}

/// The numbered circle of a step.
class _StepNumber extends StatelessWidget {
  final int index;
  final bool selected;
  final double size;
  const _StepNumber({
    required this.index,
    required this.selected,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AnimatedContainer(
      duration: _motion(context),
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? AppColors.vest : cs.surfaceContainerHigh,
        border: Border.all(
          color: selected ? AppColors.vest : cs.outlineVariant,
        ),
      ),
      child: Text(
        '${index + 1}',
        style: (size > 48 ? t.titleLarge : t.titleMedium)?.copyWith(
          color: selected ? AppColors.vestInk : cs.onSurface,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The short yellow line under the selected step.
class _Underline extends StatelessWidget {
  final bool selected;
  final double width;
  const _Underline({required this.selected, required this.width});

  @override
  Widget build(BuildContext context) => AnimatedContainer(
    duration: _motion(context),
    margin: const EdgeInsets.only(top: 6),
    width: selected ? width : 0,
    height: 3,
    decoration: BoxDecoration(
      color: AppColors.vest,
      borderRadius: BorderRadius.circular(Radii.pill),
    ),
  );
}

/// Wide layout: a step in the left column.
class _StepButton extends StatelessWidget {
  final int index;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  const _StepButton({
    required this.index,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Step ${index + 1}: $title',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: _motion(context),
        decoration: BoxDecoration(
          color: selected ? cs.surfaceContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.lg),
          border: Border.all(
            color: selected ? cs.outlineVariant : Colors.transparent,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.lg),
            child: Padding(
              padding: const EdgeInsets.all(Space.sm),
              child: Row(
                children: [
                  _StepNumber(index: index, selected: selected, size: 52),
                  Gaps.h16,
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: t.titleMedium?.copyWith(
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                          ),
                        ),
                        _Underline(selected: selected, width: 64),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Phone layout: one of the four equal step columns.
class _StepColumn extends StatelessWidget {
  final int index;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _StepColumn({
    required this.index,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      label: 'Step ${index + 1}: $label',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.md),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: Space.xs,
            horizontal: 2,
          ),
          child: Column(
            children: [
              _StepNumber(index: index, selected: selected, size: 44),
              Gaps.v8,
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: t.labelMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
              _Underline(selected: selected, width: 32),
            ],
          ),
        ),
      ),
    );
  }
}

/// The selected step: its question, the two paragraphs and the actions.
class _StepPanel extends StatelessWidget {
  final int index;
  final VoidCallback onSeeReports;
  final VoidCallback onDonateAsGuest;
  const _StepPanel({
    super.key,
    required this.index,
    required this.onSeeReports,
    required this.onDonateAsGuest,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);
    final s = LandingHowItWorks.steps[index];
    return _Panel(
      padding: EdgeInsets.all(wide ? Space.xl : Space.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Step ${index + 1} of ${LandingHowItWorks.steps.length}',
            style: t.labelLarge?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          Gaps.v8,
          Semantics(
            header: true,
            child: Text(
              s.$3,
              style: (wide ? t.headlineSmall : t.titleLarge)?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Gaps.v12,
          Text(s.$4, style: t.bodyLarge),
          Gaps.v12,
          Text(s.$5, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
          if (index == LandingHowItWorks.steps.length - 1) ...[
            Gaps.v16,
            Wrap(
              spacing: Space.xs,
              runSpacing: Space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (var i = 0; i < LandingHowItWorks.statuses.length; i++) ...[
                  if (i > 0)
                    Icon(
                      Icons.arrow_forward,
                      size: 14,
                      color: cs.onSurfaceVariant,
                    ),
                  _StatusStep(i + 1, LandingHowItWorks.statuses[i]),
                ],
              ],
            ),
          ],
          Gaps.v24,
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              AppButton(
                'See reports that need help',
                icon: Icons.search,
                variant: AppButtonVariant.donate,
                onPressed: onSeeReports,
              ),
              // "a guest", so it is not mistaken for the hero's link.
              AppButton(
                'Donate as a guest',
                icon: Icons.volunteer_activism_outlined,
                variant: AppButtonVariant.secondary,
                onPressed: onDonateAsGuest,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusStep extends StatelessWidget {
  final int number;
  final String label;
  const _StatusStep(this.number, this.label);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 10,
            backgroundColor: cs.primary,
            child: Text(
              '$number',
              style: t.labelSmall?.copyWith(
                color: cs.onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Gaps.h8,
          Flexible(child: Text(label, style: t.labelMedium)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 3: Reports (same card as the signed-in report lists)
// ---------------------------------------------------------------------------

/// Report cards in rows: as many 360 px columns as fit (1 to 3), and every
/// card in a row as tall as the tallest.
class LandingReportGrid extends StatelessWidget {
  final List<Widget> children;
  const LandingReportGrid({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = (box.maxWidth / 360).floor().clamp(1, 3);
        return _EvenGrid(columns: cols, gap: Space.md, children: children);
      },
    );
  }
}

/// The report pop-out: a centered dialog on Chrome and tablets, a bottom
/// sheet on phones. Shows what donors need to decide, never who reported.
class LandingReportDetails extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDonate;
  const LandingReportDetails({
    super.key,
    required this.report,
    required this.onDonate,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final needed = (r['total_items_needed'] as num?) ?? 0;
    final delivered = (r['total_items_delivered'] as num?) ?? 0;
    final percent = num.tryParse('${r['fulfillment_percentage'] ?? ''}');
    final pct = (percent ?? (needed > 0 ? delivered * 100 / needed : 0))
        .clamp(0, 100)
        .round();
    final guidance = '${r['priority_guidance'] ?? ''}'.trim();
    final description = '${r['description'] ?? ''}'.trim();
    final families = r['affected_families'];
    // Per-item needs: count the needs, never add kg + L + pcs together.
    final needCount = (r['needs'] as List?)?.length ?? 0;
    final reportId = (r['report_id'] ?? r['id']) as num?;

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.xs),
      child: Text(text, style: t.titleSmall),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Report #${r['report_id'] ?? r['id']}',
                    style: t.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  Gaps.v4,
                  Text(
                    '${r['disaster'] ?? 'Disaster'} in Barangay '
                    '${r['barangay'] ?? '-'}',
                    style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        Gaps.v8,
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          children: [
            PriorityChip(r['priority_level'] as String?),
            const StatusChip('Validated'),
          ],
        ),
        Gaps.v16,
        Row(
          children: [
            Expanded(
              child: _StatBox(
                families == null ? '–' : _fmt((families as num).toInt()),
                'families affected',
              ),
            ),
            Gaps.h8,
            Expanded(
              child: needCount > 0
                  ? _StatBox('$needCount', needCount == 1 ? 'need' : 'needs')
                  : _StatBox(_fmt(needed.toInt()), 'items needed'),
            ),
            Gaps.h8,
            Expanded(child: _StatBox('$pct%', 'delivered')),
          ],
        ),
        if (NeedChips.split(r['assistance_needed']).isNotEmpty) ...[
          label('Reported needs'),
          NeedChips(NeedChips.split(r['assistance_needed'])),
        ],
        label('Fulfillment progress'),
        FulfillmentBar(
          delivered: delivered,
          needed: needed,
          percent: percent,
          label: 'Delivered so far',
        ),
        if (reportId != null) ...[
          Gaps.v16,
          NeedsProgress(reportId: reportId.toInt()),
        ],
        if (description.isNotEmpty) ...[
          label('About this report'),
          Text(description, style: t.bodyMedium),
        ],
        if (guidance.isNotEmpty) ...[
          Gaps.v16,
          Container(
            padding: const EdgeInsets.all(Space.sm),
            decoration: BoxDecoration(
              color: cs.primaryContainer.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.auto_awesome, size: 18, color: cs.primary),
                Gaps.h8,
                Expanded(
                  child: Text(
                    'AI guidance: $guidance',
                    style: t.bodyMedium?.copyWith(color: cs.onPrimaryContainer),
                  ),
                ),
              ],
            ),
          ),
        ],
        Gaps.v24,
        AppButton(
          'Donate to this report',
          icon: Icons.volunteer_activism_outlined,
          variant: AppButtonVariant.donate,
          large: true,
          expand: true,
          onPressed: onDonate,
        ),
      ],
    );
  }
}

class _StatBox extends StatelessWidget {
  final String value;
  final String label;
  const _StatBox(this.value, this.label);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: t.titleLarge?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Text(label, style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section 4: Questions, one open at a time
// ---------------------------------------------------------------------------

class LandingFaq extends StatefulWidget {
  const LandingFaq({super.key});

  /// Keep in line with how the system works (and core/priority_engine.py
  /// for the priority answer).
  static const items = [
    (
      'How do I donate?',
      'Pick a report, choose the items and how many you can give, then drop '
          'them off at the CSWS Main Office or ask for a pickup. You can '
          'donate as a guest, or register to keep track of everything you '
          'give.',
    ),
    (
      'Who checks the reports?',
      'The CSWS Disaster Unit reports what a barangay needs, and the '
          'administrator checks it before it appears here.',
    ),
    (
      'Can I track my donation?',
      'Yes. After you sign in, your Reports tab shows when CSWS receives '
          'your goods and when the delivery reaches the barangay.',
    ),
    (
      'Can my organization donate?',
      'Yes. Register as a relief organization. Once your account is '
          'approved, you donate under your organization\'s name.',
    ),
    (
      'Will my name be shown publicly?',
      'No. The public page only shows the goods and the barangay. Your name '
          'stays inside NexaAid.',
    ),
    (
      'What do Critical, High, Medium and Low mean?',
      'Each report gets a score from the families affected (30%), how much '
          'is needed (20%), how severe the disaster is (25%) and how much is '
          'still undelivered (25%). Critical is 80 to 100, High 60 to 79, '
          'Medium 35 to 59 and Low below 35. Critical reports need help '
          'first.',
    ),
  ];

  @override
  State<LandingFaq> createState() => _LandingFaqState();
}

class _LandingFaqState extends State<LandingFaq> {
  int? _open = 0;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);
    final duration = _motion(context);

    final heading = Row(
      children: [
        Expanded(child: Divider(color: cs.outlineVariant)),
        Flexible(
          flex: 6,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.md),
            child: Semantics(
              header: true,
              child: Text.rich(
                const TextSpan(
                  children: [
                    TextSpan(text: 'Frequently asked '),
                    TextSpan(
                      text: 'questions',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
                textAlign: TextAlign.center,
                style: (wide ? t.headlineSmall : t.titleLarge)?.copyWith(
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        ),
        Expanded(child: Divider(color: cs.outlineVariant)),
      ],
    );

    return LandingWidth(
      maxWidth: 760,
      padding: EdgeInsets.symmetric(vertical: wide ? 80 : Space.xl + 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          heading,
          Gaps.v24,
          for (var i = 0; i < LandingFaq.items.length; i++) ...[
            if (i > 0) Gaps.v12,
            _FaqItem(
              question: LandingFaq.items[i].$1,
              answer: LandingFaq.items[i].$2,
              open: _open == i,
              duration: duration,
              onTap: () => setState(() => _open = _open == i ? null : i),
            ),
          ],
        ],
      ),
    );
  }
}

class _FaqItem extends StatelessWidget {
  final String question;
  final String answer;
  final bool open;
  final Duration duration;
  final VoidCallback onTap;

  const _FaqItem({
    required this.question,
    required this.answer,
    required this.open,
    required this.duration,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: duration,
      decoration: BoxDecoration(
        color: cs.surfaceContainer,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: open ? cs.primary.withValues(alpha: 0.6) : cs.outlineVariant,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.lg),
          onTap: onTap,
          child: Semantics(
            button: true,
            expanded: open,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Space.md + 4,
                vertical: Space.xs,
              ),
              child: AnimatedSize(
                duration: duration,
                alignment: Alignment.topCenter,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              question,
                              style: t.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Gaps.h8,
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: open ? cs.primary : cs.outlineVariant,
                              ),
                            ),
                            child: AnimatedRotation(
                              turns: open ? 0.5 : 0,
                              duration: duration,
                              child: Icon(
                                Icons.expand_more,
                                size: 20,
                                color: open ? cs.primary : cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (open)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: Space.xxs,
                          bottom: Space.sm,
                        ),
                        child: Text(
                          answer,
                          style: t.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Closing band
// ---------------------------------------------------------------------------

class LandingClosingBand extends StatelessWidget {
  final VoidCallback onStart;
  final VoidCallback onRegister;
  const LandingClosingBand({
    super.key,
    required this.onStart,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wide = landingWide(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Every pledge reaches a real family.',
          style: (wide ? t.headlineMedium : t.titleLarge)?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        Gaps.v8,
        Text(
          'One place for donors, CSWS and the barangays of Mandaue City.',
          style: t.bodyLarge?.copyWith(color: AppColors.harborMist),
        ),
      ],
    );
    final start = FilledButton(
      onPressed: onStart,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.vest,
        foregroundColor: AppColors.vestInk,
        minimumSize: const Size(0, 52),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 28),
      ),
      child: const Text('Start donating'),
    );
    final register = OutlinedButton(
      onPressed: onRegister,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: const BorderSide(color: Colors.white, width: 1.5),
        minimumSize: const Size(0, 52),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 28),
      ),
      child: const Text('Register'),
    );
    return LandingWidth(
      padding: EdgeInsets.symmetric(vertical: wide ? 72 : Space.xl),
      child: Container(
        padding: EdgeInsets.all(wide ? Space.xxl : Space.lg),
        decoration: BoxDecoration(
          color: AppColors.harborDeep,
          borderRadius: BorderRadius.circular(wide ? 28 : 22),
        ),
        child: wide
            ? Row(
                children: [
                  Expanded(child: text),
                  Gaps.h16,
                  start,
                  Gaps.h12,
                  register,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  text,
                  Gaps.v16,
                  // Stacked on phones so each label stays on one line.
                  start,
                  Gaps.v12,
                  register,
                ],
              ),
      ),
    );
  }
}
