// J2 / NF-015 (team agreement A2): the handover code, shown once to the
// CSWS Main Office staff (or the DRRMO user who carried the goods) on site.
// The server keeps only a keyed hash, so a lost code cannot be shown again:
// "Handover code" makes a new one, and the old one stops working. The code
// is never shown to the Barangay Receiving Representative's account.
import 'package:flutter/material.dart';

import '../../shared/widgets/widgets.dart';

/// Shows [code] big, for the staff to show the barangay representative.
Future<void> showHandoverCode(
  BuildContext context, {
  required String code,
  required String where,
  int deliveries = 1,
}) {
  final t = Theme.of(context).textTheme;
  final spaced = code.length == 6
      ? '${code.substring(0, 3)} ${code.substring(3)}'
      : code;
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Handover code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Show this code to the barangay representative in $where when '
            'you hand over the goods'
            '${deliveries > 1 ? ' (the $deliveries deliveries at this stop share it)' : ''}.',
          ),
          Gaps.v16,
          Text(
            spaced,
            key: const Key('handover-code-shown'),
            textAlign: TextAlign.center,
            style: t.displaySmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 6,
            ),
          ),
          Gaps.v16,
          Text(
            'It is shown only this once. If it is lost, tap "Handover code" '
            'on the delivery to make a new one; the old one then stops '
            'working. Do not send it by text or chat.',
            style: t.bodySmall,
          ),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// Makes a new handover code for [deliveryId] (POST
/// /deliveries/{id}/handover-code) and shows it. [ask]: confirm first,
/// because the code shown before stops working.
Future<void> newHandoverCode(
  BuildContext context,
  int deliveryId, {
  required String where,
  bool ask = true,
}) async {
  if (ask) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Make a new handover code?'),
        content: const Text(
          'Use this when the code was lost. The code shown before stops '
          'working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Make a new code'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
  }
  final nav = Navigator.of(context, rootNavigator: true);
  final r = await api.post('/deliveries/$deliveryId/handover-code');
  if (!nav.mounted) return;
  if (!r.ok) {
    await act(nav.context, () async => r, success: '');
    return;
  }
  final m = r.json as Map;
  await showHandoverCode(
    nav.context,
    code: '${m['handover_code']}',
    where: where,
    deliveries: (m['delivery_ids'] as List).length,
  );
}
