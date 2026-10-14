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

  final int? affectedFamilies;
  final String? assistanceNeeded;
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
    this.affectedFamilies,
    this.assistanceNeeded,
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
    final needs = NeedChips.split(assistanceNeeded);
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
            ],
          ),
          const SizedBox(height: 8),
          if (affectedFamilies != null)
            Text(
              '$affectedFamilies ${affectedFamilies == 1 ? 'family' : 'families'} affected',
            ),
          // problema_napud 2.1 / 2.4: every need on its own, highlighted,
          // instead of one total quantity.
          if (needs.isNotEmpty) ...[
            const SizedBox(height: 8),
            NeedChips(needs),
          ],
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

/// The items a report needs, each one highlighted on its own
/// ("Rice: 150 sacks", "Drinking Water: 500 gallons").
class NeedChips extends StatelessWidget {
  final List<String> needs;
  const NeedChips(this.needs, {super.key});

  /// "Rice: 50 kg, Drinking Water: 20 gallons" -> one entry per need.
  static List<String> split(Object? raw) => (raw ?? '')
      .toString()
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      label: 'Needs: ${needs.join(', ')}',
      excludeSemantics: true,
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final n in needs)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.inventory_2_outlined,
                    size: 15,
                    color: cs.onPrimaryContainer,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      n,
                      style: t.labelLarge?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
