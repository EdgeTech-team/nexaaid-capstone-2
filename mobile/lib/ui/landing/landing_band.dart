import 'package:flutter/material.dart';

import '../../design/design.dart';

/// A landing-page section: an uppercase title with a yellow accent bar,
/// and optionally a teal gradient background (`filled: true`) for the
/// section that should stand out most (Our impact).
class LandingBand extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;
  final bool filled;
  final Widget? trailing;

  const LandingBand({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.filled = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final titleColor = filled ? Colors.white : cs.onSurface;
    final subColor = filled ? AppColors.harborMist : cs.onSurfaceVariant;

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 5,
              height: 30,
              decoration: BoxDecoration(
                color: AppColors.vest,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Gaps.h12,
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  title.toUpperCase(),
                  style: t.headlineSmall?.copyWith(
                    color: titleColor,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        if (subtitle != null) ...[
          Gaps.v8,
          Text(subtitle!, style: t.bodyMedium?.copyWith(color: subColor)),
        ],
        Gaps.v16,
        child,
      ],
    );

    if (!filled) {
      return Padding(
        padding: const EdgeInsets.only(top: Space.xl),
        child: content,
      );
    }
    return Container(
      margin: const EdgeInsets.only(top: Space.xl),
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.xl),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF3FB0A8), AppColors.harborDeep],
        ),
      ),
      child: content,
    );
  }
}

/// Big number with a sentence under it; numbers inside the sentence are
/// highlighted. Write the sentence with [segments]: (text, highlight).
class ImpactStat extends StatelessWidget {
  final String number;
  final List<(String, bool)> segments;
  const ImpactStat({super.key, required this.number, required this.segments});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final base = t.bodyLarge;
    final strong = base?.copyWith(
      color: cs.primary,
      fontWeight: FontWeight.w800,
    );
    return Semantics(
      label: '$number ${segments.map((s) => s.$1).join()}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: CountUpText(
              number,
              style: t.displaySmall?.copyWith(
                color: cs.primary,
                fontWeight: FontWeight.w800,
                height: 1.05,
              ),
            ),
          ),
          Gaps.v4,
          Text.rich(
            TextSpan(
              children: [
                for (final s in segments)
                  TextSpan(text: s.$1, style: s.$2 ? strong : base),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
