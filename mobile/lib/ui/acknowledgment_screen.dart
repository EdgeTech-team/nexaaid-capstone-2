// J2 / NF-015 (team agreement A2): the read-only Acknowledgment Receipt
// (GET /deliveries/{id}/acknowledgment).
//
// Full view (CSWS Main Office, Disaster Unit, Administrator, the rep of that
// barangay): reference no., barangay, report, items with packaging and
// sent / received counts, the signer's name and position, the signature,
// the optional slip photo, the date and time, and "Handover code verified".
// Donor view (donors whose goods were on the delivery): items, barangay,
// reference no. and date only. The signature and photo are fetched with the
// login token (Api.download), never from a public link.
import 'package:flutter/material.dart';

import '../api.dart' show ApiResult, Roles;
import 'delivery_widgets.dart' show niceWhen;
import 'private_file_view.dart';
import 'widgets.dart';

/// Who may open the full receipt from a delivery screen.
const receiptReaders = {
  Roles.cswsMain,
  Roles.cswsUnit,
  Roles.admin,
  Roles.barangay,
};

bool canSeeReceipt(String? role) => receiptReaders.contains(role);

Future<void> openAcknowledgment(BuildContext context, int deliveryId) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AcknowledgmentScreen(deliveryId: deliveryId),
      ),
    );

class AcknowledgmentScreen extends StatefulWidget {
  final int deliveryId;
  const AcknowledgmentScreen({super.key, required this.deliveryId});

  @override
  State<AcknowledgmentScreen> createState() => _AcknowledgmentScreenState();
}

class _AcknowledgmentScreenState extends State<AcknowledgmentScreen> {
  late final Future<ApiResult> _load = api.get(
    '/deliveries/${widget.deliveryId}/acknowledgment',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Acknowledgment Receipt')),
      body: FutureBuilder<ApiResult>(
        future: _load,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final r = snap.data!;
          if (!r.ok || r.json is! Map) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  r.status == 0 ? 'Cannot reach the server' : r.errorText,
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return AcknowledgmentView(r.json as Map);
        },
      ),
    );
  }
}

/// The receipt itself, as the server sent it for this viewer.
class AcknowledgmentView extends StatelessWidget {
  final Map receipt;
  const AcknowledgmentView(this.receipt, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final a = receipt;
    final full = a['view'] == 'full';
    final items = (a['items'] as List? ?? const []).cast<Map>();
    final verified = a['handover_verified'] == true;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('Acknowledgment Receipt', style: t.headlineSmall),
        Text('${a['reference_no']}', style: t.titleMedium),
        Gaps.v12,
        _Field('Barangay', '${a['barangay_name']}'),
        _Field('Delivery', '#${a['delivery_id']}'),
        if (full && a['report_label'] != null)
          _Field('Report', '${a['report_label']}'),
        _Field('Received', niceWhen(a['received_at'])),
        Gaps.v12,
        Text('Items', style: t.titleMedium),
        Gaps.v4,
        for (final it in items) _ItemLine(it, full: full),
        if (full) ...[
          const Divider(),
          Text('Received and acknowledged by', style: t.titleMedium),
          Gaps.v4,
          Text('${a['signer_name'] ?? 'Not recorded'}', style: t.bodyLarge),
          if (a['signer_position'] != null)
            Text('${a['signer_position']}', style: t.bodyMedium),
          Gaps.v8,
          if (a['signature_url'] != null)
            PrivateFileTile(
              label: 'Signature',
              url: '${a['signature_url']}',
              contentType: 'image/png',
            )
          else
            Text(
              'No e-signature: confirmed before e-signatures were used.',
              style: t.bodySmall,
            ),
          Gaps.v8,
          Row(
            children: [
              Icon(
                verified ? Icons.verified : Icons.help_outline,
                color: verified ? cs.primary : cs.onSurfaceVariant,
                size: 20,
              ),
              Gaps.h8,
              Text(
                verified
                    ? 'Handover code verified'
                    : 'Handover code not recorded',
              ),
            ],
          ),
          if ((a['remarks'] ?? '').toString().trim().isNotEmpty) ...[
            Gaps.v8,
            _Field('Remarks', '${a['remarks']}'),
          ],
          if (a['slip_photo_url'] != null) ...[
            Gaps.v12,
            PrivateFileTile(
              label: 'Photo of the stamped slip',
              url: '${a['slip_photo_url']}',
              contentType: 'image/jpeg',
            ),
          ],
        ],
        Gaps.v16,
        Text(
          'The e-signature is a record that the barangay acknowledged '
          'receipt in NexaAid. It is not a certified digital signature.',
          style: t.bodySmall,
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  const _Field(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label, style: t.bodySmall)),
          Expanded(child: Text(value, style: t.bodyMedium)),
        ],
      ),
    );
  }
}

class _ItemLine extends StatelessWidget {
  final Map it;
  final bool full;
  const _ItemLine(this.it, {required this.full});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final unit = '${it['unit'] ?? ''}';
    String amount(dynamic n) => '$n $unit'.trim();
    final received = it['received_quantity'];
    final differs = received != null && received != it['expected_quantity'];
    final note = full ? it['discrepancy_note'] : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${it['item_name']}', style: t.titleSmall),
          if (it['packaging'] != null)
            Text('Packaging: ${it['packaging']}', style: t.bodySmall),
          Text(
            'Sent by CSWS: ${amount(it['expected_quantity'])} · '
            'Received: ${received == null ? 'not counted' : amount(received)}',
            style: t.bodyMedium,
          ),
          if (differs)
            Text(
              'Difference: ${it['discrepancy_reason'] ?? ''}'
              '${note != null ? ' · $note' : ''}',
              style: t.bodySmall?.copyWith(color: cs.error),
            ),
        ],
      ),
    );
  }
}
