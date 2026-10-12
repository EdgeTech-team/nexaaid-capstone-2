import 'package:flutter/material.dart';

import 'widgets.dart';

/// One disaster report as a card: "#id  Flood in Banilad", its status, the
/// priority and source chips, families / needs / quantity, the description,
/// the AI guidance and the fulfillment bar, then the actions.
///
/// Presentational only: it takes values that are already resolved, so the
/// logged-in report lists ([ReportCard] in report_screens.dart) and the
/// public landing page show the same card.
class ReportSummaryCard extends StatelessWidget {
  final int? reportId;
  final String disaster;
  final String barangay;
  final String? status;
  final String? priority;

  /// How the report came in (Web / Mobile / SMS). Null hides the chip.
  final String? source;
  final int? affectedFamilies;
  final String? assistanceNeeded;
  final num? quantity;
  final String? description;
  final String? guidance;
  final String? rejectionReason;

  /// Fulfillment. [needed] null = the report has no fulfillment yet.
  final num? delivered;
  final num? needed;
  final num? percent;

  /// Appendix H 3.2: every role except DRRMO sees priority and guidance.
  final bool showPriority;

  /// Outlined: the report a notification pointed at.
  final bool highlighted;
  final List<Widget> actions;

  /// Actions share the card width (each Expanded) instead of sitting on the
  /// right, and they stay at the bottom when the card is stretched to the
  /// height of a grid row.
  final bool fillActions;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry margin;

  const ReportSummaryCard({
    super.key,
    required this.reportId,
    required this.disaster,
    required this.barangay,
    this.status,
    this.priority,
    this.source,
    this.affectedFamilies,
    this.assistanceNeeded,
    this.quantity,
    this.description,
    this.guidance,
    this.rejectionReason,
    this.delivered,
    this.needed,
    this.percent,
    this.showPriority = true,
    this.highlighted = false,
    this.actions = const [],
    this.fillActions = false,
    this.onTap,
    this.margin = const EdgeInsets.only(bottom: 12),
  });

  @override
  Widget build(BuildContext context) {
    final details = [
      if (affectedFamilies != null) '$affectedFamilies families',
      if (assistanceNeeded != null) 'Needs: $assistanceNeeded',
      if (quantity != null) 'Qty: $quantity',
    ];
    final body = Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '#$reportId  $disaster in $barangay',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              StatusChip(status),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (showPriority && priority != null) PriorityChip(priority),
              if (source != null)
                Chip(
                  avatar: const Icon(Icons.input, size: 16),
                  label: Text('via $source'),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: 8),
          // The needs stand out (bold label), like "Assistance Needed" on
          // the donor Reports tab.
          Text.rich(
            TextSpan(
              children: [
                for (var i = 0; i < details.length; i++) ...[
                  if (i > 0) const TextSpan(text: '  ·  '),
                  if (details[i].startsWith('Needs: ')) ...[
                    TextSpan(
                      text: 'Needs: ',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                    TextSpan(
                      text: details[i].substring(7),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ] else
                    TextSpan(text: details[i]),
                ],
              ],
            ),
          ),
          if (description != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                description!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (showPriority && guidance != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.auto_awesome,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'AI guidance: $guidance',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (rejectionReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Rejected: $rejectionReason',
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          if (needed != null) ...[
            const SizedBox(height: 10),
            Progress(
              delivered: delivered ?? 0,
              needed: needed!,
              percent: percent,
            ),
          ],
          if (actions.isNotEmpty) ...[
            if (fillActions) const Spacer() else const SizedBox(height: 8),
            if (fillActions) const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < actions.length; i++)
                  if (fillActions) ...[
                    if (i > 0) Gaps.h8,
                    Expanded(child: actions[i]),
                  ] else
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: actions[i],
                    ),
              ],
            ),
          ],
        ],
      ),
    );
    return Card(
      margin: margin,
      clipBehavior: onTap == null ? Clip.none : Clip.antiAlias,
      shape: highlighted
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(Radii.lg),
              side: BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 2,
              ),
            )
          : null,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}
