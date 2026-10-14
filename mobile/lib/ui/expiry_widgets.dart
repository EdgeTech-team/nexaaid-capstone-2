import 'package:flutter/material.dart';

import 'widgets.dart';

// ---------------------------------------------------------------------------
// Donation deadlines, expiry and cancellation (backend:
// services/donation_expiry.py, api/v1/donation_lifecycle_routes.py).
//
// Drop Off: hand over within 14 days. Door to Door: CSWS has 7 days after
// the preferred pickup time. After that the donation is marked Expired.
// Donors can cancel while it is still waiting; CSWS can reopen it.
// Nothing is deleted.
// ---------------------------------------------------------------------------

bool isClosedEntry(Map e) =>
    e['status'] == 'Expired' || e['status'] == 'Cancelled';

/// True while at least one item is still waiting to be handed over.
bool hasWaitingItems(Map e) {
  final pending = e['pending_items'];
  if (pending is num) return pending > 0;
  return (e['items'] as List? ?? const []).any(
    (i) => (i as Map)['status'] == 'Pending',
  );
}

String _short(dynamic iso) {
  final d = DateTime.tryParse('${iso ?? ''}');
  if (d == null) return '';
  const m = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final l = d.toLocal();
  return '${m[l.month - 1]} ${l.day}';
}

/// One line under a donation that says what happens next, in plain words:
///   "Hand over by Fri, Oct 23 · 5 days left"
///   "Only 2 days left to hand this over (by Fri, Oct 23)"
///   "Expired on Oct 3. Not brought to the CSWS office by Oct 3."
class ExpiryNote extends StatelessWidget {
  final Map entry;

  /// Staff see what to do about it; donors see who to contact.
  final bool forStaff;
  const ExpiryNote(this.entry, {super.key, this.forStaff = false});

  @override
  Widget build(BuildContext context) {
    final e = entry;
    final t = Theme.of(context).textTheme;
    final b = Theme.of(context).brightness;

    if (isClosedEntry(e)) {
      final expired = e['status'] == 'Expired';
      final tone = StatusColors.of(e['status'] as String?, b);
      final when = _short(e['closed_at']);
      final reason = '${e['close_reason'] ?? ''}'.trim();
      final next = forStaff
          ? (expired
                ? 'If the donor is here with the goods, tap Reopen.'
                : 'Tap Reopen if the donor changes their mind.')
          : (expired
                ? 'Contact CSWS if you still want to give it.'
                : 'Contact CSWS if this was a mistake.');
      return _Box(
        tone: tone,
        title: '${expired ? 'Expired' : 'Cancelled'}${when.isEmpty ? '' : ' on $when'}',
        lines: [if (reason.isNotEmpty) reason, next],
        style: t,
      );
    }

    final label = e['expires_label'] as String?;
    if (label == null || !hasWaitingItems(e)) {
      final closed = (e['closed_items'] as num? ?? 0).toInt();
      if (closed == 0) return const SizedBox.shrink();
      return Text(
        '$closed ${closed == 1 ? 'item was' : 'items were'} not handed over '
        '(expired or cancelled).',
        style: t.bodySmall,
      );
    }

    final days = (e['days_left'] as num?)?.toInt();
    final urgent = days != null && days <= 3;
    final tone = StatusColors.of(urgent ? 'On Hold' : 'Pending', b);
    final dropOff = e['handover_method'] != 'Door to Door';
    final String title;
    if (days == 0) {
      title = 'Last day today ($label)';
    } else if (urgent) {
      title = 'Only $days ${days == 1 ? 'day' : 'days'} left (by $label)';
    } else {
      title = '${dropOff ? 'Hand over by' : 'Pickup window ends'} $label'
          '${days == null ? '' : ' · $days days left'}';
    }
    return _Box(
      tone: tone,
      icon: urgent ? Icons.timer_outlined : Icons.event_outlined,
      title: title,
      lines: [
        if (urgent && !forStaff)
          dropOff
              ? 'Bring it to the CSWS office before then, or it will expire.'
              : 'CSWS will try to collect it before then.',
        if (urgent && forStaff)
          dropOff
              ? 'Expires automatically if not received by then.'
              : 'Collect it before then or it expires automatically.',
      ],
      style: t,
    );
  }
}

class _Box extends StatelessWidget {
  final ToneStyle tone;
  final IconData? icon;
  final String title;
  final List<String> lines;
  final TextTheme style;
  const _Box({
    required this.tone,
    required this.title,
    required this.lines,
    required this.style,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon ?? tone.icon, size: 20, color: tone.fg),
          Gaps.h8,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: style.bodyMedium?.copyWith(
                    color: tone.fg,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                for (final l in lines)
                  Text(l, style: style.bodySmall?.copyWith(color: tone.fg)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<String>? _reasons;

Future<List<String>> _cancelReasons() async {
  if (_reasons != null) return _reasons!;
  final r = await api.get('/donations/expiry-rules');
  _reasons = r.ok && r.json is Map
      ? ((r.json as Map)['cancel_reasons'] as List).cast<String>()
      : const [
          'I changed my mind',
          'The items are no longer available',
          'I gave the items another way',
          'I cannot bring them in time',
        ];
  return _reasons!;
}

/// Ask why, confirm, then cancel the waiting items of a donation.
/// [staff]: CSWS cancelling for a donor who called or messaged.
/// [askPhone]: a guest donor proves it is theirs with their phone number.
/// Returns true when it was cancelled.
Future<bool> cancelDonation(
  BuildContext context,
  Map entry, {
  bool staff = false,
  bool askPhone = false,
}) async {
  final reasons = await _cancelReasons();
  if (!context.mounted) return false;
  String? picked;
  final other = TextEditingController();
  final phone = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final reasonText = picked == '__other' ? other.text.trim() : picked;
        final canConfirm = (reasonText ?? '').isNotEmpty &&
            (!askPhone || phone.text.trim().length >= 10);
        return AlertDialog(
          title: Text(staff ? 'Cancel for the donor?' : 'Cancel this donation?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  staff
                      ? 'CSWS will stop waiting for ${entry['batch_reference']}. '
                            'Items already received are not affected.'
                      : 'CSWS will stop waiting for your donation. Items '
                            'already received are not affected.',
                ),
                Gaps.v12,
                Text(
                  'Why?',
                  style: Theme.of(ctx).textTheme.titleSmall,
                ),
                RadioGroup<String>(
                  groupValue: picked,
                  onChanged: (v) => setLocal(() => picked = v),
                  child: Column(
                    children: [
                      for (final r in [
                        ...reasons,
                        if (staff) 'The donor asked CSWS to cancel',
                      ])
                        RadioListTile<String>(
                          value: r,
                          title: Text(r),
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                        ),
                      const RadioListTile<String>(
                        value: '__other',
                        title: Text('Another reason'),
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ],
                  ),
                ),
                if (picked == '__other')
                  TextField(
                    controller: other,
                    maxLength: 300,
                    decoration: const InputDecoration(
                      labelText: 'Type the reason',
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                if (askPhone) ...[
                  Gaps.v8,
                  TextField(
                    controller: phone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Your mobile number',
                      helperText: 'The number you gave when you donated',
                    ),
                    onChanged: (_) => setLocal(() {}),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep donation'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
              ),
              onPressed: canConfirm ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Yes, cancel it'),
            ),
          ],
        );
      },
    ),
  );
  // Not disposed here: the dialog may still be animating out with them.
  final reason = picked == '__other' ? other.text.trim() : picked;
  final phoneText = phone.text.trim();
  if (ok != true || !context.mounted) return false;
  final r = await act(
    context,
    () => api.post(
      '/donations/entries/${Uri.encodeComponent('${entry['batch_reference']}')}/cancel',
      body: {
        'reason': reason,
        if (askPhone) 'contact_number': phoneText,
      },
    ),
    success: 'Donation cancelled',
  );
  return r.ok;
}

/// CSWS: reopen an Expired or Cancelled donation (e.g. the donor arrived
/// late with the QR). It goes back to waiting with a new deadline.
Future<bool> reinstateDonation(BuildContext context, Map entry) async {
  final v = await formDialog(
    context,
    title: 'Reopen this donation?',
    message:
        'Use this when the donor is here with the goods, or still wants to '
        'give them. ${entry['batch_reference']} goes back to waiting and the '
        'donor gets a new deadline.',
    fields: const [
      DialogField(
        'note',
        'Note (optional)',
        required: false,
        hint: 'e.g. Donor arrived late with the QR',
      ),
    ],
    confirm: 'Reopen',
  );
  if (v == null || !context.mounted) return false;
  final r = await act(
    context,
    () => api.post(
      '/donations/entries/${Uri.encodeComponent('${entry['batch_reference']}')}/reinstate',
      body: {'note': (v['note'] ?? '').isEmpty ? null : v['note']},
    ),
    success: 'Donation reopened. You can receive it now.',
  );
  return r.ok;
}
