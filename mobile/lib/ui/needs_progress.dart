import 'package:flutter/material.dart';

import '../api.dart';

/// Per-item fulfillment (Oct 2026): one bar per need of the report.
/// Data comes from GET /reports/{id}/needs (services/fulfillment.py).
/// Each bar has three layers: pledged (lightest), in stock / CMO-confirmed,
/// and delivered (darkest, the official figure).
class NeedsProgress extends StatefulWidget {
  final int reportId;
  const NeedsProgress({super.key, required this.reportId});

  @override
  State<NeedsProgress> createState() => _NeedsProgressState();
}

class _NeedsProgressState extends State<NeedsProgress> {
  late final Future<ApiResult> _load = Api.instance.get(
    '/reports/${widget.reportId}/needs',
  );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<ApiResult>(
      future: _load,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          );
        }
        final r = snap.data!;
        if (!r.ok || r.json is! Map) {
          return Text(
            'Per-item progress is not available (${r.status}).',
            style: TextStyle(color: cs.error, fontSize: 13),
          );
        }
        final data = r.json as Map;
        // An unexpected answer (e.g. an older server) shows nothing
        // instead of crashing the sheet it is in.
        final needs = (data['needs'] as List? ?? const []).cast<Map>();
        final extra = (data['additional_goods'] as List? ?? const [])
            .cast<Map>();
        final overall =
            (data['fulfillment_percentage'] as num?)?.toDouble() ?? 0;
        if (needs.isEmpty) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Delivered overall: ${overall.toStringAsFixed(0)}% '
              '(average of the items below)',
              style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final n in needs) _NeedRow(need: n),
            if (extra.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                'Also received (not requested, does not count):',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
              for (final g in extra)
                Text(
                  '• ${g['item_name']}: ${g['pledged']} ${g['unit'] ?? ''}',
                  style: const TextStyle(fontSize: 13),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _NeedRow extends StatelessWidget {
  final Map need;
  const _NeedRow({required this.need});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final unit = need['unit'] ?? '';
    double pct(String key) => ((need[key] as num).toDouble() / 100).clamp(0, 1);

    Widget layer(double factor, Color color) => FractionallySizedBox(
      widthFactor: factor,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${need['item_name']}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                '${need['delivered']} / ${need['needed']} $unit',
                style: const TextStyle(fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 14,
            child: Container(
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Stack(
                children: [
                  layer(
                    pct('pledged_percentage'),
                    cs.primary.withValues(alpha: 0.25),
                  ),
                  layer(
                    pct('confirmed_percentage'),
                    cs.primary.withValues(alpha: 0.55),
                  ),
                  layer(pct('delivered_percentage'), cs.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Pledged ${need['pledged']} · In stock ${need['confirmed']} · '
            'Delivered ${need['delivered']} $unit',
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

/// What each need still lacks (needed minus delivered), for report cards:
/// "Rice 400 kg · Drinking Water 131 L", or '' when every need is
/// delivered. Null for an older report with one "General needs" total.
String? stillNeededText(Map r) {
  final needs = [
    for (final n in (r['needs'] as List? ?? const []))
      if (n is Map) n,
  ];
  if (needs.isEmpty || needs.any((n) => n['item_id'] == null)) return null;
  return [
    for (final n in needs)
      if (((n['needed'] as num?) ?? 0) > ((n['delivered'] as num?) ?? 0))
        '${n['item_name']} '
                '${((n['needed'] as num) - ((n['delivered'] as num?) ?? 0)).toInt()} '
                '${n['unit'] ?? ''}'
            .trim(),
  ].join(' · ');
}
