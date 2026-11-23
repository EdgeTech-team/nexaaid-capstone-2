import 'package:flutter/material.dart';

import '../../design/design.dart';
import 'landing_band.dart';

/// "Why you can trust NexaAid" + "About NexaAid" on the landing page.
///
/// Trust comes from true, checkable statements. Keep every line here
/// accurate to how the system really works; no made-up numbers,
/// testimonials or partnerships.
class AboutSection extends StatelessWidget {
  const AboutSection({super.key});

  /// How the system protects reports and donations.
  static const _promises = [
    (
      Icons.verified_user_outlined,
      'Every report is checked',
      'Reports come from the CSWS Disaster Unit, and the administrator '
          'validates each one before it appears here.',
    ),
    (
      Icons.qr_code_2,
      'Every donation is traceable',
      'Each donation gets its own QR code, scanned when CSWS receives it '
          'and again when it is delivered.',
    ),
    (
      Icons.route_outlined,
      'You can follow it to the end',
      'Donors see each step, from pledge to the barangay confirming the '
          'goods arrived.',
    ),
    (
      Icons.history,
      'Every change is recorded',
      'Status changes are saved in an audit log that the City can review.',
    ),
    (
      Icons.lock_outline,
      'Your details stay private',
      'Public pages show reports and totals only, never donor contact '
          'details.',
    ),
  ];

  /// The team. Edit names and roles to match your group.
  static const _team = [
    ('Castillo', 'Developer'),
    ('Fernandez', 'UI/UX lead'),
    ('Hoyohoy', 'Developer'),
    ('Mariquit', 'Developer'),
  ];

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final muted = t.bodyMedium?.copyWith(color: cs.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LandingBand(
          title: 'Why you can trust NexaAid',
          subtitle: 'How reports and donations are checked at every step.',
          child: AppCard(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Column(
              children: [
                for (var i = 0; i < _promises.length; i++) ...[
                  if (i > 0) const Divider(indent: 72, endIndent: Space.md),
                  _Promise(
                    icon: _promises[i].$1,
                    title: _promises[i].$2,
                    body: _promises[i].$3,
                  ),
                ],
              ],
            ),
          ),
        ),
        LandingBand(
          title: 'About NexaAid',
          child: AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'NexaAid connects donors with the barangays of Mandaue City '
                  'that need help after a disaster, and lets everyone follow '
                  'each donation until it arrives.',
                  style: t.bodyLarge,
                ),
                Gaps.v12,
                Text(
                  'It is a capstone project by EdgeTech, a team of BSIS '
                  'students at Cebu Technological University Main Campus '
                  '(College of Computer, Information and Communications '
                  'Technology), designed for the City\'s relief offices: '
                  'CSWS, CMO and DRRMO.',
                  style: muted,
                ),
                Gaps.v16,
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.sm,
                  children: [
                    for (final m in _team) _Member(name: m.$1, role: m.$2),
                  ],
                ),
                Gaps.v16,
                const Divider(),
                Gaps.v12,
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.support_agent, size: 20, color: cs.primary),
                    Gaps.h12,
                    Expanded(
                      child: Text(
                        'Questions about a report or a delivery? Contact the '
                        'CSWS Main Office or your barangay hall.',
                        style: muted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Promise extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  const _Promise({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 20, color: cs.onPrimaryContainer),
          ),
          Gaps.h16,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: t.titleMedium),
                Gaps.v4,
                Text(
                  body,
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

class _Member extends StatelessWidget {
  final String name;
  final String role;
  const _Member({required this.name, required this.role});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, Space.md, 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 16,
            backgroundColor: cs.primary,
            child: Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: t.labelLarge?.copyWith(color: cs.onPrimary),
            ),
          ),
          Gaps.h8,
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, style: t.labelLarge),
                Text(
                  role,
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
