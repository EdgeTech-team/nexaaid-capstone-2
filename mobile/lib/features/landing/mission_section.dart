import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'landing_band.dart';

/// Mission, vision and core values on the landing page.
class MissionSection extends StatelessWidget {
  const MissionSection({super.key});

  static const _mission =
      'To connect donors with the relief offices of Mandaue City so the '
      'right goods reach the families who need them, and every donation can '
      'be followed until it arrives.';

  static const _vision =
      'A Mandaue where help after a disaster arrives quickly, fairly and in '
      'the open.';

  /// (icon, value, what it means in NexaAid)
  static const _values = [
    (
      Icons.visibility_outlined,
      'Transparency',
      'Every report and donation can be followed from start to finish.',
    ),
    (
      Icons.balance_outlined,
      'Fairness',
      'Help goes first to the reports with the greatest need.',
    ),
    (
      Icons.fact_check_outlined,
      'Accountability',
      'Every step is confirmed by the office or barangay that handled it.',
    ),
    (
      Icons.diversity_3_outlined,
      'Bayanihan',
      'Donors, organizations and the City working together for one '
          'community.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LandingBand(
          title: 'Our mission and vision',
          child: LayoutBuilder(
            builder: (context, c) {
              const mission = _Statement(
                icon: Icons.flag_outlined,
                label: 'Mission',
                text: _mission,
              );
              const vision = _Statement(
                icon: Icons.wb_twilight_outlined,
                label: 'Vision',
                text: _vision,
              );
              if (c.maxWidth >= Breakpoints.medium) {
                return const IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: mission),
                      Gaps.h12,
                      Expanded(child: vision),
                    ],
                  ),
                );
              }
              return const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [mission, Gaps.v12, vision],
              );
            },
          ),
        ),
        LandingBand(
          title: 'What we stand for',
          child: LayoutBuilder(
            builder: (context, c) {
              final cols = c.maxWidth >= Breakpoints.medium ? 2 : 1;
              final w = (c.maxWidth - Space.sm * (cols - 1)) / cols;
              return Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  for (final v in _values)
                    SizedBox(
                      width: w,
                      child: _Value(icon: v.$1, name: v.$2, meaning: v.$3),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Statement extends StatelessWidget {
  final IconData icon;
  final String label;
  final String text;
  const _Statement({
    required this.icon,
    required this.label,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Icon(icon, size: 20, color: cs.onPrimaryContainer),
              ),
              Gaps.h12,
              Text(label, style: t.titleLarge),
            ],
          ),
          Gaps.v12,
          Text(text, style: t.bodyLarge),
        ],
      ),
    );
  }
}

class _Value extends StatelessWidget {
  final IconData icon;
  final String name;
  final String meaning;
  const _Value({required this.icon, required this.name, required this.meaning});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.primary),
          Gaps.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: t.titleMedium),
                Gaps.v4,
                Text(
                  meaning,
                  style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
