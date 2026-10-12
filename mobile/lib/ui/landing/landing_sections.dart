import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../disaster_art.dart';
import '../theme_toggle.dart';
import 'landing_extras.dart' show kImpactImage;
import 'public_data.dart';

// Ivan: landing page redesign ("NexaAid landing page redesign" canvas).
// A charity-site layout: header, big two-line headline with a photo, a
// stats strip, "How it works" with a circle photo collage, report cards,
// questions that open and close, and a closing band. Side by side on
// Chrome and tablets, stacked on phones.

/// Widest the landing content gets on Chrome.
const double kLandingMax = 1200;

/// Two columns from tablet width up, one column on phones.
bool landingWide(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= Breakpoints.expanded;

String _fmt(int n) => n.toString().replaceAllMapped(
  RegExp(r'\B(?=(\d{3})+(?!\d))'),
  (_) => ',',
);

/// Centers a section at [kLandingMax] with side padding.
class LandingWidth extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const LandingWidth({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final side = landingWide(context) ? Space.lg : Space.md + 4;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kLandingMax),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: side).add(padding),
          child: child,
        ),
      ),
    );
  }
}

/// Small teal label above a section title, e.g. "How it works".
class LandingEyebrow extends StatelessWidget {
  final String text;
  const LandingEyebrow(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: Theme.of(context).textTheme.labelLarge?.copyWith(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.1,
    ),
  );
}

/// Section title with one word in teal: [before] [accent] [after].
class LandingTitle extends StatelessWidget {
  final String before;
  final String accent;
  final String after;
  const LandingTitle(this.before, this.accent, {this.after = '', super.key});

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
            TextSpan(
              text: accent,
              style: TextStyle(color: cs.primary),
            ),
            TextSpan(text: after),
          ],
        ),
        style: (wide ? t.headlineLarge : t.headlineSmall)?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

class LandingHeader extends StatelessWidget {
  final VoidCallback onLogIn;
  final VoidCallback onHowItWorks;
  final VoidCallback onReports;
  final VoidCallback onQuestions;

  const LandingHeader({
    super.key,
    required this.onLogIn,
    required this.onHowItWorks,
    required this.onReports,
    required this.onQuestions,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final wide = landingWide(context);
    return Material(
      color: cs.surfaceContainerLowest,
      child: SafeArea(
        bottom: false,
        child: Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: cs.outlineVariant)),
          ),
          child: LandingWidth(
            padding: const EdgeInsets.symmetric(vertical: Space.sm),
            child: Row(
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
                const Spacer(),
                if (wide) ...[
                  TextButton(
                    onPressed: onHowItWorks,
                    child: const Text('How it works'),
                  ),
                  TextButton(onPressed: onReports, child: const Text('Reports')),
                  TextButton(
                    onPressed: onQuestions,
                    child: const Text('Questions'),
                  ),
                  Gaps.h8,
                ],
                // One tap switches light and dark (sun in light mode,
                // moon in dark), same button as Profile. Not inside the
                // login pop-up.
                const SunMoonToggle(),
                Gaps.h8,
                FilledButton(
                  onPressed: onLogIn,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    shape: const StadiumBorder(),
                  ),
                  child: const Text('Log in'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero: headline, photo and the three ways in
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
                  style: (wide ? t.displayMedium : t.headlineLarge)?.copyWith(
                    color: AppColors.vestInk,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
              ),
            ),
          ],
        ),
        style: (wide ? t.displayMedium : t.headlineLarge)?.copyWith(
          fontWeight: FontWeight.w700,
          height: 1.15,
        ),
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

    // Register stands out (yellow), Log in is outlined, guest is a link.
    final register = FilledButton.icon(
      onPressed: onCreateAccount,
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.vest,
        foregroundColor: AppColors.vestInk,
        minimumSize: const Size(0, 52),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
      icon: const Icon(Icons.favorite_border),
      label: const Text('Register as donor or organization'),
    );
    final logIn = OutlinedButton.icon(
      onPressed: onLogIn,
      style: OutlinedButton.styleFrom(
        foregroundColor: cs.primary,
        side: BorderSide(color: cs.primary, width: 2),
        minimumSize: const Size(0, 52),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24),
      ),
      icon: const Icon(Icons.login),
      label: const Text('Log in to your account'),
    );
    final guest = TextButton.icon(
      onPressed: onDonateAsGuest,
      icon: const Icon(Icons.volunteer_activism_outlined, size: 18),
      label: const Text('Donate as guest'),
    );
    final guestNote = Text(
      'No account needed',
      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
    );

    final photo = _HeroPhoto(height: wide ? 440 : 230);

    if (wide) {
      return LandingWidth(
        padding: const EdgeInsets.only(top: Space.xxl + 16, bottom: Space.xl),
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
                  Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [register, logIn],
                  ),
                  Gaps.v12,
                  Row(children: [guest, Gaps.h4, guestNote]),
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
      padding: const EdgeInsets.only(top: Space.lg + 4),
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
          register,
          Gaps.v12,
          logIn,
          Gaps.v8,
          Center(child: guest),
          Center(child: guestNote),
          Gaps.v16,
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
                    const ColoredBox(color: AppColors.harborMist),
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
// Stats strip: live numbers from /public/stats (or the reports)
// ---------------------------------------------------------------------------

class LandingStatsBand extends StatelessWidget {
  final PublicStats? stats;
  const LandingStatsBand({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final wide = landingWide(context);
    final s = stats;
    final items = <(String, String)>[
      (s == null ? '–' : _fmt(s.activeReports), 'Reports needing help'),
      (s == null ? '–' : _fmt(s.familiesAffected), 'Families affected'),
      if (s?.deliveriesCompleted != null)
        (_fmt(s!.deliveriesCompleted!), 'Deliveries completed')
      else
        (s == null ? '–' : _fmt(s.barangays), 'Barangays with reports'),
    ];
    return LandingWidth(
      padding: EdgeInsets.only(
        top: wide ? 0 : Space.md,
        bottom: wide ? Space.xxl + 16 : Space.xl,
      ),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: wide ? Space.xl : Space.md,
          vertical: wide ? Space.lg + 4 : Space.md + 4,
        ),
        decoration: BoxDecoration(
          color: AppColors.harborDeep,
          borderRadius: BorderRadius.circular(wide ? 24 : 20),
        ),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (value, label) in items)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: wide
                          ? CrossAxisAlignment.start
                          : CrossAxisAlignment.center,
                      children: [
                        Text(
                          value,
                          style: (wide ? t.displaySmall : t.headlineSmall)
                              ?.copyWith(
                                color: AppColors.vest,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                        Text(
                          label,
                          textAlign: wide ? TextAlign.start : TextAlign.center,
                          style: (wide ? t.bodyLarge : t.bodySmall)?.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            if (kDemoData) ...[
              Gaps.v12,
              Align(
                alignment: wide ? Alignment.centerLeft : Alignment.center,
                child: Text(
                  'Demo data: test numbers until the system goes live.',
                  style: t.bodySmall?.copyWith(color: AppColors.harborMist),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// How it works: circle photo collage + three numbered steps
// ---------------------------------------------------------------------------

class LandingHowItWorks extends StatelessWidget {
  final PublicStats? stats;
  const LandingHowItWorks({super.key, required this.stats});

  static const _steps = [
    (
      'Pick a barangay',
      'The City checks each disaster report and shows what the families '
          'still need.',
    ),
    (
      'Pledge your items',
      'Choose food, water or supplies. Drop them off at the CSWS Main Office '
          'or ask for a pickup, and show your QR code.',
    ),
    (
      'Follow it to the families',
      'See when CSWS receives it, when the delivery leaves, and when the '
          'barangay confirms it arrived.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final wide = landingWide(context);

    final steps = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingEyebrow('How it works'),
        Gaps.v12,
        const LandingTitle('From your pledge to a ', "family's door"),
        Gaps.v24,
        for (var i = 0; i < _steps.length; i++) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: wide ? 24 : 20,
                backgroundColor: AppColors.harbor,
                child: Text(
                  '${i + 1}',
                  style: t.titleMedium?.copyWith(color: Colors.white),
                ),
              ),
              Gaps.h16,
              Expanded(
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
            ],
          ),
          if (i < _steps.length - 1) Gaps.v24,
        ],
      ],
    );

    return Material(
      color: cs.surfaceContainerLowest,
      child: LandingWidth(
        padding: EdgeInsets.symmetric(vertical: wide ? 80 : Space.xl + 4),
        child: wide
            ? Row(
                children: [
                  Expanded(child: _Collage(stats: stats, size: 460)),
                  const SizedBox(width: Space.xxl + 8),
                  Expanded(child: steps),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Collage(stats: stats, size: 260),
                  Gaps.v24,
                  steps,
                ],
              ),
      ),
    );
  }
}

/// Big circle photo, a small flood picture circle (wide only) and a yellow
/// circle with the items delivered so far.
class _Collage extends StatelessWidget {
  final PublicStats? stats;
  final double size; // height of the collage
  const _Collage({required this.stats, required this.size});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final big = size > 300;
    final photo = big ? 340.0 : 220.0;
    final yellow = big ? 200.0 : 140.0;
    final delivered = stats?.itemsDelivered;
    return SizedBox(
      height: size,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            child: Container(
              width: photo,
              height: photo,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: cs.primaryContainer, width: 8),
              ),
              child: ClipOval(
                child: Image.asset(
                  kImpactImage,
                  fit: BoxFit.cover,
                  semanticLabel: 'Relief goods being handed to a family',
                  errorBuilder: (_, _, _) =>
                      const ColoredBox(color: AppColors.harborMist),
                ),
              ),
            ),
          ),
          if (big)
            Positioned(
              right: 20,
              top: 40,
              child: Container(
                width: 170,
                height: 170,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: cs.surfaceContainerLowest, width: 6),
                ),
                child: const ClipOval(
                  child: DisasterArt(DisasterKind.flood, height: 170),
                ),
              ),
            ),
          if (delivered != null && delivered > 0)
            Positioned(
              right: big ? 60 : 0,
              bottom: 0,
              child: Container(
                width: yellow,
                height: yellow,
                padding: const EdgeInsets.all(Space.md),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.vest,
                  border: Border.all(color: cs.surfaceContainerLowest, width: 6),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FittedBox(
                      child: Text(
                        _fmt(delivered),
                        style: (big ? t.headlineLarge : t.headlineSmall)
                            ?.copyWith(
                              color: AppColors.vestInk,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    Text(
                      big ? 'items delivered to families' : 'items delivered',
                      textAlign: TextAlign.center,
                      style: t.labelMedium?.copyWith(
                        color: AppColors.vestInk,
                        fontWeight: FontWeight.w600,
                      ),
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
// Report cards: picture, priority tag, progress, Donate
// ---------------------------------------------------------------------------

/// Lays report cards out 3 across on Chrome, 2 on tablets, 1 on phones.
class LandingReportGrid extends StatelessWidget {
  final List<Widget> children;
  const LandingReportGrid({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final cols = box.maxWidth >= 960
            ? 3
            : box.maxWidth >= 600
            ? 2
            : 1;
        const gap = Space.lg;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final c in children) SizedBox(width: w, child: c),
          ],
        );
      },
    );
  }
}

class LandingReportCard extends StatelessWidget {
  final Map<String, dynamic> report;
  final VoidCallback onDonate;
  final VoidCallback onOpen;

  const LandingReportCard({
    super.key,
    required this.report,
    required this.onDonate,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final r = report;
    final needed = (r['total_items_needed'] as num?) ?? 0;
    final delivered = (r['total_items_delivered'] as num?) ?? 0;
    final pct = needed > 0
        ? (delivered / needed * 100).clamp(0, 100).round()
        : 0;
    final priority = r['priority_level'] as String?;
    final needs = '${r['assistance_needed'] ?? ''}'.trim();
    final families = r['affected_families'];
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Stack(
            children: [
              DisasterArt(disasterKind(r['disaster']), height: 170),
              if (priority != null)
                Positioned(
                  left: Space.sm,
                  top: Space.sm,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: PriorityColors.base(priority),
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                    child: Text(
                      priority,
                      style: t.labelMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.all(Space.md + 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${r['disaster'] ?? 'Disaster'}'
                  '${families == null ? '' : ' · $families families'}',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                Gaps.v4,
                Text(
                  'Barangay ${r['barangay'] ?? '-'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleLarge,
                ),
                if (needs.isNotEmpty) ...[
                  Gaps.v4,
                  Text(
                    'Needs $needs',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
                Gaps.v12,
                ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.pill),
                  child: LinearProgressIndicator(
                    value: pct / 100,
                    minHeight: 10,
                    backgroundColor: cs.surfaceContainerHighest,
                  ),
                ),
                Gaps.v8,
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        needed > 0
                            ? '$delivered of $needed items'
                            : 'No item count yet',
                        style: t.bodyMedium,
                      ),
                    ),
                    Text(
                      '$pct%',
                      style: t.titleSmall?.copyWith(color: cs.primary),
                    ),
                  ],
                ),
                Gaps.v16,
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
                    OutlinedButton(
                      onPressed: onOpen,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 48),
                      ),
                      child: const Text('Details'),
                    ),
                  ],
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
// Questions: tap to open, one at a time
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
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : Motion.normal;

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
    );

    final intro = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const LandingEyebrow('Questions'),
        Gaps.v12,
        const LandingTitle('Before you ', 'donate'),
        Gaps.v12,
        Text(
          'Short answers to what donors and organizations ask most.',
          style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant),
        ),
        if (wide) ...[
          Gaps.v24,
          ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: Image.asset(
              kImpactImage,
              height: 240,
              width: double.infinity,
              fit: BoxFit.cover,
              semanticLabel: 'Relief goods packed and ready',
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ],
      ],
    );

    return Material(
      color: cs.surfaceContainerLowest,
      child: LandingWidth(
        padding: EdgeInsets.symmetric(vertical: wide ? 80 : Space.xl + 4),
        child: wide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: intro),
                  const SizedBox(width: Space.xxl),
                  Expanded(child: list),
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [intro, Gaps.v16, list],
              ),
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
    final fg = open ? Colors.white : cs.onSurface;
    return AnimatedContainer(
      duration: duration,
      decoration: BoxDecoration(
        color: open ? AppColors.harbor : cs.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: open ? AppColors.harbor : cs.outlineVariant,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Semantics(
            button: true,
            expanded: open,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
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
                              style: t.titleMedium?.copyWith(color: fg),
                            ),
                          ),
                          Gaps.h8,
                          Icon(
                            open ? Icons.remove : Icons.add,
                            color: open ? Colors.white : cs.primary,
                          ),
                        ],
                      ),
                    ),
                    if (open)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Space.md),
                        child: Text(
                          answer,
                          style: t.bodyMedium?.copyWith(
                            color: const Color(0xFFE6F4F2),
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
  const LandingClosingBand({super.key, required this.onStart});

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
    final button = FilledButton(
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
                  button,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [text, Gaps.v16, button],
              ),
      ),
    );
  }
}
