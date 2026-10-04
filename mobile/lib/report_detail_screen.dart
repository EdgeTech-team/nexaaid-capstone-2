import 'package:flutter/material.dart';

import 'api.dart';
import 'report_model.dart';
import 'nexa_theme.dart';
import 'nexa_widgets.dart';

/// Dark text for the light gradient page and white cards. Without an explicit
/// colour, Text inherits the (light) text colour of the app's dark theme, which
/// is unreadable on this screen.
const Color _ink = Color(0xFF2D2A32);
const Color _muted = Color(0xFF6B6674);

/// Screen 2: report detail with AI-assisted priority guidance.
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
    // Logged-in users (for example when this opens from a notification) don't
    // need the guest "Log in" pill or the guest hint. The support button stays
    // for them only when a donation module supplied onSupport.
final guest = !Api.instance.loggedIn;
    final showSupport = guest || onSupport != null;

    return GradientPage(
      child: Column(
        children: [
          NexaHeader(
            actions: [
              HeaderPill(
                label: 'back',
                onTap: () => Navigator.of(context).pop(),
              ),
              if (guest) const HeaderPill(label: 'Log in', filled: true),
            ],
          ),
          Expanded(
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: _ink),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          report.disasterType,
                          style: const TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w800,
                            color: _ink,
                          ),
                        ),
                      ),
                      PriorityBadge(level: report.priorityLevel, large: true),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    report.title,
                    style: const TextStyle(fontSize: 19, color: _ink),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _reportedLine,
                    style: const TextStyle(fontSize: 13, color: _muted),
                  ),
                  const SizedBox(height: 16),
                  if (report.description != null) ...[
                    WhiteCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Incident summary',
                            style: TextStyle(fontSize: 12, color: _muted),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            report.description!,
                            style: const TextStyle(fontSize: 14, color: _ink),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  if (report.needs.isNotEmpty) ...[
                    WhiteCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'NEEDS',
                            style: TextStyle(fontSize: 12, color: _muted),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final n in report.needs)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: NexaColors.orange,
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  child: Text(
                                    n,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  WhiteCard(
                    child: FulfillmentBar(
                      percent: report.fulfillmentPercentage,
                    ),
                  ),
                  const SizedBox(height: 14),
                  WhiteCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AI-assisted priority guidance',
                          style: TextStyle(fontSize: 11, color: _muted),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          report.aiRecommendation ??
                              'No priority guidance available yet.',
                          style: const TextStyle(fontSize: 14, color: _ink),
                        ),
                      ],
                    ),
                  ),
                  if (showSupport) ...[
                    const SizedBox(height: 22),
                    Center(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: NexaColors.coral,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 36,
                            vertical: 16,
                          ),
                          shape: const StadiumBorder(),
                        ),
                        onPressed: onSupport ?? () {},
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'SUPPORT THIS REPORT',
                              style: TextStyle(fontSize: 16),
                            ),
                            SizedBox(width: 10),
                            Icon(Icons.arrow_right_alt),
                          ],
                        ),
                      ),
                    ),
                  ],
                  if (guest) ...[
                    const SizedBox(height: 8),
                    const Center(
                      child: Text(
                        'You can donate as a guest or log in to track it',
                        style: TextStyle(fontSize: 12, color: _muted),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
