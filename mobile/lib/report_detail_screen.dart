import 'package:flutter/material.dart';

import 'api.dart';
import 'report_model.dart';
import 'nexa_widgets.dart';

/// Screen 2: report detail with AI-assisted priority guidance.
/// Styled from the app theme (design/theme.dart) so it matches the rest of
/// the system in both light and dark mode.
class ReportDetailScreen extends StatelessWidget {
  final Report report;

  /// "Support this report" belongs to the donation module (3.5).
  final VoidCallback? onSupport;

  const ReportDetailScreen({super.key, required this.report, this.onSupport});

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String get _reportedLine {
    final d = report.createdAt;
    if (d == null) return '';
    return 'Reported ${_months[d.month - 1]} ${d.day}, ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final muted = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);

    // Logged-in users (for example when this opens from a notification) don't
    // need the guest hint. The support button stays for them only when a
    // donation module supplied onSupport.
    final guest = !Api.instance.loggedIn;
    final showSupport = guest || onSupport != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Report details'),
        leading: BackButton(onPressed: () => Navigator.of(context).pop()),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  report.disasterType,
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: cs.onSurface,
                  ),
                ),
              ),
              PriorityBadge(level: report.priorityLevel, large: true),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            report.title,
            style: TextStyle(fontSize: 18, color: cs.onSurface),
          ),
          const SizedBox(height: 4),
          Text(_reportedLine, style: muted.copyWith(fontSize: 13)),
          const SizedBox(height: 16),
          if (report.description != null) ...[
            _section(
              context,
              title: 'Incident summary',
              child: Text(
                report.description!,
                style: TextStyle(fontSize: 14, color: cs.onSurface),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (report.needs.isNotEmpty) ...[
            _section(
              context,
              title: 'Needs',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final n in report.needs)
                    Chip(
                      label: Text(n),
                      backgroundColor: cs.primaryContainer,
                      labelStyle: TextStyle(color: cs.onPrimaryContainer),
                      side: BorderSide.none,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          _section(
            context,
            title: 'Progress',
            child: FulfillmentBar(percent: report.fulfillmentPercentage),
          ),
          const SizedBox(height: 12),
          _section(
            context,
            title: 'AI guidance',
            icon: Icons.auto_awesome,
            child: Text(
              report.priorityGuidance ??
                  report.aiRecommendation ??
                  'No priority guidance available yet.',
              style: TextStyle(fontSize: 14, color: cs.onSurface),
            ),
          ),
          if (showSupport) ...[
            const SizedBox(height: 22),
            Center(
              child: FilledButton.icon(
                onPressed: onSupport ?? () {},
                icon: const Icon(Icons.arrow_right_alt),
                label: const Text('Support this report'),
                iconAlignment: IconAlignment.end,
              ),
            ),
          ],
          if (guest) ...[
            const SizedBox(height: 8),
            Center(
              child: Text(
                'You can donate as a guest or log in to track it',
                style: muted,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context, {
    required String title,
    required Widget child,
    IconData? icon,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 16, color: cs.primary),
                  const SizedBox(width: 6),
                ],
                Text(
                  title,
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ],
            ),
            const SizedBox(height: 8),
            child,
          ],
        ),
      ),
    );
  }
}
