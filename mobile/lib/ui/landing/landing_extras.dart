import 'package:flutter/material.dart';

import '../../design/design.dart';
import '../widgets.dart' show api;
import 'landing_band.dart';
import 'public_data.dart';

/// Photo beside the impact numbers, e.g. 'assets/images/impact.jpg'.
/// Leave empty for no photo. Use your own photos (or ones you have
/// permission for), and get consent before showing identifiable people.
const kImpactImage = 'assets/images/exampleimg.jpg';

String _n(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

String _plural(int n, String one, String many) => n == 1 ? one : many;

// ---------------------------------------------------------------------------
// 2. Impact as sentences, with an "as of" time
// ---------------------------------------------------------------------------

/// Real numbers only: a big number and a sentence for each, with the
/// time they were loaded. Shows a "Demo data" label while kDemoData is true.
class ImpactSection extends StatelessWidget {
  final PublicStats stats;
  final DateTime asOf;
  const ImpactSection({super.key, required this.stats, required this.asOf});

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final items = <ImpactStat>[
      if (s.itemsDelivered > 0)
        ImpactStat(
          number: _n(s.itemsDelivered),
          segments: [
            (
              'relief ${_plural(s.itemsDelivered, 'item', 'items')} '
                  'delivered to ',
              false,
            ),
            (_n(s.barangaysReached), true),
            (
              ' ${_plural(s.barangaysReached, 'barangay', 'barangays')} '
                  'in Mandaue City.',
              false,
            ),
          ],
        ),
      if (s.deliveriesCompleted != null && s.deliveriesCompleted! > 0)
        ImpactStat(
          number: _n(s.deliveriesCompleted!),
          segments: [
            (
              '${_plural(s.deliveriesCompleted!, 'delivery', 'deliveries')} '
                  'confirmed by the barangay that received them.',
              false,
            ),
          ],
        ),
      if (s.donationsReceived != null && s.donationsReceived! > 0)
        ImpactStat(
          number: _n(s.donationsReceived!),
          segments: [
            (
              '${_plural(s.donationsReceived!, 'donation', 'donations')} '
                  'received and checked by the CSWS Main Office.',
              false,
            ),
          ],
        ),
      if (s.activeReports > 0)
        ImpactStat(
          number: _n(s.familiesAffected),
          segments: [
            (
              '${_plural(s.familiesAffected, 'family is', 'families are')} '
                  'covered by ',
              false,
            ),
            (_n(s.activeReports), true),
            (
              ' validated ${_plural(s.activeReports, 'report', 'reports')} '
                  'that still need help.',
              false,
            ),
          ],
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;

    final numbers = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0) Gaps.v24,
          items[i],
        ],
        Gaps.v24,
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'As of ${formatAsOf(asOf)}',
              style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
            if (kDemoData) const _DemoBadge(),
          ],
        ),
      ],
    );

    Widget photo(double? height) => ClipRRect(
      borderRadius: BorderRadius.circular(Radii.lg),
      child: Image.asset(
        kImpactImage,
        height: height,
        width: double.infinity,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );

    return LandingBand(
      title: 'Our impact',
      filled: true,
      child: AppCard(
        padding: const EdgeInsets.all(Space.lg),
        child: LayoutBuilder(
          builder: (context, c) {
            if (kImpactImage.isEmpty) return numbers;
            if (c.maxWidth >= Breakpoints.medium) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: numbers),
                  const SizedBox(width: Space.lg),
                  Expanded(flex: 2, child: photo(320)),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [numbers, Gaps.v24, photo(200)],
            );
          },
        ),
      ),
    );
  }
}

class _DemoBadge extends StatelessWidget {
  const _DemoBadge();

  @override
  Widget build(BuildContext context) {
    return const Tooltip(
      message: 'These numbers come from test data, not real donations.',
      child: StatusChip('On Hold', label: 'Demo data', showIcon: false),
    );
  }
}

// ---------------------------------------------------------------------------
// 3. Recently delivered feed
// ---------------------------------------------------------------------------

/// Latest deliveries confirmed by barangays.
///
/// Needs GET /public/recent-deliveries (Mariquit or Hoyohoy). Until that
/// endpoint exists, or if it returns nothing, this section stays hidden.
/// Expected shape, newest first, max 5, no donor names:
/// [{"summary": "Food packs", "barangay": "Basak",
///   "confirmed_at": "2026-10-01T14:30:00"}]
class RecentDeliveriesSection extends StatefulWidget {
  const RecentDeliveriesSection({super.key});

  @override
  State<RecentDeliveriesSection> createState() =>
      _RecentDeliveriesSectionState();
}

class _RecentDeliveriesSectionState extends State<RecentDeliveriesSection> {
  late final Future<List<Map<String, dynamic>>> _future = _load();

  Future<List<Map<String, dynamic>>> _load() async {
    final r = await api.get('/public/recent-deliveries');
    if (!r.ok || r.json is! List) return const [];
    return [
      for (final e in (r.json as List).take(5))
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _future,
      builder: (context, snap) {
        final items = snap.data ?? const [];
        if (items.isEmpty) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        final t = Theme.of(context).textTheme;
        return LandingBand(
          title: 'Recently delivered',
          subtitle: 'Confirmed by the barangay that received them.',
          child: AppCard(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0) const Divider(indent: 64),
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: StatusColors.of(
                        'Acknowledged',
                        Theme.of(context).brightness,
                      ).bg,
                      child: Icon(
                        Icons.task_alt,
                        color: StatusColors.of(
                          'Acknowledged',
                          Theme.of(context).brightness,
                        ).fg,
                      ),
                    ),
                    title: Text(
                      '${items[i]['summary'] ?? 'Relief goods'} delivered '
                      'to Brgy. ${items[i]['barangay'] ?? '-'}',
                      style: t.titleSmall,
                    ),
                    subtitle: Text(
                      _confirmed(items[i]['confirmed_at']),
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  static String _confirmed(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}');
    return d == null
        ? 'Confirmed by the barangay'
        : 'Confirmed by the barangay, ${formatAsOf(d.toLocal())}';
  }
}

// ---------------------------------------------------------------------------
// 5. Ways to help
// ---------------------------------------------------------------------------

class WaysToHelpSection extends StatelessWidget {
  final VoidCallback onDonate;
  final void Function(bool org) onRegister;
  const WaysToHelpSection({
    super.key,
    required this.onDonate,
    required this.onRegister,
  });

  @override
  Widget build(BuildContext context) {
    final ways = [
      (
        Icons.volunteer_activism_outlined,
        'Donate goods',
        'Pick a validated report and pledge food, water, hygiene kits or '
            'other goods. No account needed.',
        AppButton(
          'Start donating',
          variant: AppButtonVariant.donate,
          expand: true,
          onPressed: onDonate,
        ),
      ),
      (
        Icons.route_outlined,
        'Track your donations',
        'Create a free donor account to see every step, from pledge to the '
            'barangay confirming it arrived.',
        AppButton(
          'Create donor account',
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: () => onRegister(false),
        ),
      ),
      (
        Icons.groups_outlined,
        'Bring your organization',
        'Relief groups, churches, schools and companies can register and '
            'donate as an organization after a quick review.',
        AppButton(
          'Register organization',
          variant: AppButtonVariant.secondary,
          expand: true,
          onPressed: () => onRegister(true),
        ),
      ),
    ];

    return LandingBand(
      title: 'Ways to help',
      child: LayoutBuilder(
        builder: (context, c) {
          final cols = c.maxWidth >= Breakpoints.medium ? 3 : 1;
          final w = (c.maxWidth - Space.sm * (cols - 1)) / cols;
          return Wrap(
            spacing: Space.sm,
            runSpacing: Space.sm,
            children: [
              for (final way in ways)
                SizedBox(
                  width: w,
                  child: _Way(
                    icon: way.$1,
                    title: way.$2,
                    text: way.$3,
                    button: way.$4,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Way extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final Widget button;
  const _Way({
    required this.icon,
    required this.title,
    required this.text,
    required this.button,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: cs.primary, size: 28),
          Gaps.v12,
          Text(title, style: t.titleMedium),
          Gaps.v4,
          Text(text, style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
          Gaps.v16,
          button,
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 4. Credentials: only what is true
// ---------------------------------------------------------------------------

/// Fill these in. Leave a value empty to hide that line.
/// Only list an office if it actually gave input to the project.
const _university =
    'Cebu Technological University Main Campus, College of Computer, '
    'Information and Communications Technology';
const _program = 'BS Information Systems capstone project, 2026';
const _adviser = ''; // e.g. 'Adviser: Dr. Juan Dela Cruz'
const _consultedOffices = <String>[]; // e.g. ['CSWS Mandaue']

class CredentialsCard extends StatelessWidget {
  const CredentialsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final rows = <(IconData, String)>[
      (Icons.school_outlined, _university),
      (Icons.workspace_premium_outlined, _program),
      if (_adviser.isNotEmpty) (Icons.person_outline, _adviser),
      if (_consultedOffices.isNotEmpty)
        (
          Icons.apartment_outlined,
          'Consulted with: ${_consultedOffices.join(', ')}',
        ),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: Space.sm),
      child: AppCard(
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Gaps.v12,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(rows[i].$1, size: 20, color: cs.onSurfaceVariant),
                  Gaps.h12,
                  Expanded(
                    child: Text(
                      rows[i].$2,
                      style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
