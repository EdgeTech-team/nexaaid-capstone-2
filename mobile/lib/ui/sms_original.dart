// J7 / NF-012 (team agreement Nov 18, 2026, A5): SMS reports are locked.
// On Report Validation the Administrator sees the SMS exactly as it was
// received beside the fields that were encoded from it. Nothing here can
// be edited: a wrong SMS report is rejected with a reason so the Disaster
// Unit can resend it.
//
// J8 / NF-014: an SMS from a number that matches no active CSWS Disaster
// Unit member is encoded only with a reason; the panel shows it as a
// warning until the report is validated.
import 'package:flutter/material.dart';

import '../api.dart' show ApiResult;
import 'widgets.dart';

/// J8: part of the server's 422 detail for an unregistered sender.
const unregisteredSenderText = 'matches no active CSWS Disaster Unit member';

bool isUnregisteredSender(ApiResult r) =>
    r.status == 422 &&
    r.json is Map &&
    r.json['detail'] is String &&
    (r.json['detail'] as String).contains(unregisteredSenderText);

/// POST /reports/sms. When the sender number is not a registered Disaster
/// Unit member's, asks the Administrator for the reason and sends it again
/// with unregistered_sender_reason (cancel = nothing is saved).
Future<ApiResult> encodeSmsReport(
  BuildContext context,
  Map<String, dynamic> body, {
  required String success,
}) async {
  final first = await api.post('/reports/sms', body: body);
  if (!context.mounted) return first;
  if (!isUnregisteredSender(first)) {
    return act(context, () async => first, success: success);
  }
  final v = await formDialog(
    context,
    title: 'Unregistered sender',
    message:
        '${body['contact_number']} matches no active CSWS Disaster Unit '
        'member. Give the reason to encode it anyway. The report shows it '
        'as a warning until it is validated.',
    fields: const [DialogField('reason', 'Reason', multiline: true)],
    confirm: 'Encode with reason',
  );
  if (v == null || !context.mounted) return first;
  return act(
    context,
    () => api.post(
      '/reports/sms',
      body: {...body, 'unregistered_sender_reason': v['reason']},
    ),
    success: '$success It shows a warning until it is validated.',
  );
}

/// [card] (the encoded fields) with the original SMS of report [reportId]
/// beside it on a wide screen, or under it on a phone.
class SmsBeside extends StatelessWidget {
  final Widget card;
  final int reportId;
  const SmsBeside({super.key, required this.card, required this.reportId});

  /// From this width the two sit side by side.
  static const wide = 720.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final sms = SmsOriginalPanel(reportId);
      if (box.maxWidth < wide) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [card, sms],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: card),
          Gaps.h12,
          Expanded(flex: 2, child: sms),
        ],
      );
    },
  );
}

/// The SMS as received (GET /reports/{id}/sms-metadata), read-only.
class SmsOriginalPanel extends StatefulWidget {
  final int reportId;
  const SmsOriginalPanel(this.reportId, {super.key});

  @override
  State<SmsOriginalPanel> createState() => _SmsOriginalPanelState();
}

class _SmsOriginalPanelState extends State<SmsOriginalPanel> {
  late Future<ApiResult> _sms = _load();

  Future<ApiResult> _load() =>
      api.get('/reports/${widget.reportId}/sms-metadata');

  @override
  void didUpdateWidget(SmsOriginalPanel old) {
    super.didUpdateWidget(old);
    if (old.reportId != widget.reportId) _sms = _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      margin: const EdgeInsets.only(bottom: Space.sm),
      color: cs.surfaceContainerHighest,
      child: FutureBuilder<ApiResult>(
        future: _sms,
        builder: (context, snap) {
          final r = snap.data;
          final m = r != null && r.ok && r.json is Map ? r.json as Map : null;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.sms_outlined, size: 18, color: cs.primary),
                  Gaps.h8,
                  Text('Original SMS', style: t.titleSmall),
                ],
              ),
              Gaps.v8,
              if (r == null)
                const LinearProgressIndicator()
              else if (m == null)
                Text(
                  'The original SMS could not be loaded.',
                  style: t.bodySmall?.copyWith(color: cs.error),
                )
              else ...[
                if (m['warning'] != null) ...[
                  Container(
                    padding: const EdgeInsets.all(Space.xs),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(Radii.sm),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: cs.onErrorContainer,
                        ),
                        Gaps.h8,
                        Expanded(
                          child: Text(
                            '${m['warning']}',
                            style: t.bodySmall?.copyWith(
                              color: cs.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Gaps.v8,
                ],
                Text(
                  'From ${m['contact_number'] ?? '?'}'
                  '${m['encoded_at'] == null ? '' : ' · encoded ${niceDate(m['encoded_at'])}'}',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                Gaps.v8,
                SelectableText(
                  '${m['raw_message'] ?? ''}',
                  style: t.bodyMedium?.copyWith(fontFamily: 'monospace'),
                ),
                Gaps.v8,
                Text(
                  'SMS reports cannot be edited. If the encoded fields do '
                  'not match this SMS, reject it with a reason so the '
                  'Disaster Unit can resend.',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
