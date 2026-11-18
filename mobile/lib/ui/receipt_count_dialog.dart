// J1 / NF-009 (team agreement Nov 18, 2026): the Barangay Receiving
// Representative counts every item before confirming receipt (UC-B1).
//
// Every count field starts empty. When a count differs from what CSWS sent,
// a reason is needed: "Over" when more arrived; Short, Damaged or Wrong item
// when fewer arrived; none when it matches. The server checks the same rules
// (POST /deliveries/{id}/confirm-receipt and POST /trips/{id}/confirm-receipt).
//
// J2 / NF-015 (team agreement A2): the same form takes the proof of
// receipt: the 6-digit handover code the CSWS staff (or the DRRMO driver) on
// site shows, the representative's full name and position, a signature
// drawn on the pad (signature_pad.dart), and an optional photo of the
// stamped paper slip (a document only: no people, no goods). With [submit],
// the form stays open until the server accepts it, so a wrong code or a
// lock is shown in the form and nothing has to be typed again.
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../api.dart';
import '../design/design.dart';
import 'signature_pad.dart';

/// Reasons for a count lower than what CSWS sent.
const shortReasons = ['Short', 'Damaged', 'Wrong item'];

/// The only reason for a count higher than what CSWS sent.
const overReason = 'Over';

/// The largest slip photo the server accepts (core/uploads.py).
const maxSlipPhotoBytes = 1024 * 1024;

/// The reasons that fit [received] against [sent]; empty when they match.
List<String> reasonsFor(int received, int sent) {
  if (received < sent) return shortReasons;
  if (received > sent) return const [overReason];
  return const [];
}

/// One delivery to count: its number, a title and its lines as
/// GET /deliveries/ sends them (delivery_item_id, quantity, item_name, unit).
class CountTarget {
  final int deliveryId;
  final String title;
  final List<Map> lines;
  const CountTarget(this.deliveryId, this.title, this.lines);

  factory CountTarget.fromDelivery(Map d) => CountTarget(
    d['delivery_id'] as int,
    'Delivery #${d['delivery_id']}',
    (d['items'] as List? ?? const []).cast<Map>(),
  );
}

/// What the rep counted and the proof of receipt, ready to send.
class ReceiptCounts {
  /// delivery_id -> the "items" list of its request body.
  final Map<int, List<Map<String, dynamic>>> items;
  final String? remarks;

  /// At least one line differs from what CSWS sent.
  final bool hasDifference;

  final String handoverCode;
  final String signerName;
  final String signerPosition;
  final SignatureDrawing signature;
  final Uint8List? slipPhoto;

  const ReceiptCounts(
    this.items,
    this.remarks, {
    required this.hasDifference,
    required this.handoverCode,
    required this.signerName,
    required this.signerPosition,
    required this.signature,
    this.slipPhoto,
  });

  /// The counts part of POST /deliveries/{id}/confirm-receipt.
  Map<String, dynamic> deliveryBody(int deliveryId) => {
    'items': items[deliveryId] ?? const [],
    if (remarks != null) 'remarks': remarks,
  };

  /// The counts part of POST /trips/{id}/confirm-receipt.
  Map<String, dynamic> tripBody() => {
    'deliveries': [
      for (final e in items.entries) {'delivery_id': e.key, 'items': e.value},
    ],
    if (remarks != null) 'remarks': remarks,
  };
}

/// Uploads the signature PNG (and the slip photo, if any) as the signed-in
/// user, then calls [send] with the proof fields to merge into the body.
/// Returns the first failed upload, or what [send] returns.
Future<ApiResult> sendWithProof(
  ReceiptCounts counted,
  Future<ApiResult> Function(Map<String, dynamic> proof) send,
) async {
  final png = await counted.signature.toPng();
  if (png == null) {
    return ApiResult(422, {'detail': 'Sign in the box.'}, '');
  }
  final api = Api.instance;
  final signature = await api.upload(
    purpose: 'receipt_signature',
    bytes: png,
    filename: 'signature.png',
  );
  if (!signature.ok) return signature;
  String? slipId;
  if (counted.slipPhoto != null) {
    final slip = await api.upload(
      purpose: 'receipt_slip_photo',
      bytes: counted.slipPhoto!,
      filename: 'slip.jpg',
    );
    if (!slip.ok) return slip;
    slipId = (slip.json as Map)['file_id'] as String;
  }
  return send({
    'handover_code': counted.handoverCode,
    'signer_name': counted.signerName,
    'signer_position': counted.signerPosition,
    'signature_file_id': (signature.json as Map)['file_id'],
    'slip_photo_file_id': ?slipId,
  });
}

/// Shows the count and proof form for [deliveries]: one delivery, or every
/// delivery of a trip that arrived at the barangay. With [submit], the form
/// stays open until [submit] succeeds and shows the server's message when it
/// does not. Returns what was entered, or null if cancelled.
Future<ReceiptCounts?> showReceiptCountDialog(
  BuildContext context, {
  required String title,
  String? message,
  required List<CountTarget> deliveries,
  Future<ApiResult> Function(ReceiptCounts counted)? submit,
}) => showDialog<ReceiptCounts>(
  context: context,
  barrierDismissible: false,
  builder: (_) => ReceiptCountDialog(
    title: title,
    message: message,
    deliveries: deliveries,
    submit: submit,
  ),
);

class ReceiptCountDialog extends StatefulWidget {
  final String title;
  final String? message;
  final List<CountTarget> deliveries;
  final Future<ApiResult> Function(ReceiptCounts counted)? submit;
  const ReceiptCountDialog({
    super.key,
    required this.title,
    this.message,
    required this.deliveries,
    this.submit,
  });

  @override
  State<ReceiptCountDialog> createState() => _ReceiptCountDialogState();
}

/// One line being counted.
class _Line {
  final int id;
  final int sent;
  final String name;
  final String unit;
  final count = TextEditingController(); // starts empty: no default count
  final note = TextEditingController();
  String? reason;

  _Line(Map m)
    : id = m['delivery_item_id'] as int,
      sent = (m['quantity'] as num).toInt(),
      name = '${m['item_name'] ?? 'Item #${m['item_id']}'}',
      unit = '${m['unit'] ?? ''}';

  int? get received => int.tryParse(count.text.trim());

  List<String> get fits {
    final r = received;
    return r == null ? const [] : reasonsFor(r, sent);
  }

  String amount(int n) => '$n $unit'.trim();
}

class _ReceiptCountDialogState extends State<ReceiptCountDialog> {
  final _form = GlobalKey<FormState>();
  final _remarks = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _position = TextEditingController();
  final _signature = SignatureController();
  Uint8List? _slip;
  bool _signatureMissing = false;
  bool _busy = false;
  String? _error;

  late final Map<int, List<_Line>> _lines = {
    for (final t in widget.deliveries)
      t.deliveryId: [for (final m in t.lines) _Line(m)],
  };

  @override
  void initState() {
    super.initState();
    _signature.addListener(_signed);
  }

  void _signed() {
    if (_signatureMissing && !_signature.isEmpty) {
      setState(() => _signatureMissing = false);
    }
  }

  @override
  void dispose() {
    for (final l in _lines.values.expand((x) => x)) {
      l.count.dispose();
      l.note.dispose();
    }
    _remarks.dispose();
    _code.dispose();
    _name.dispose();
    _position.dispose();
    _signature.removeListener(_signed);
    _signature.dispose();
    super.dispose();
  }

  /// A new count: drop a reason that no longer fits (e.g. Short -> Over).
  void _counted(_Line l) => setState(() {
    if (!l.fits.contains(l.reason)) l.reason = null;
  });

  Future<void> _pickSlip() async {
    final file = await ImagePicker().pickImage(
      source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
      imageQuality: 70,
      maxWidth: 1600,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    if (bytes.length > maxSlipPhotoBytes) {
      setState(
        () => _error =
            'The photo is larger than 1 MB. Take it again a little farther '
            'from the slip.',
      );
      return;
    }
    setState(() {
      _slip = bytes;
      _error = null;
    });
  }

  Future<void> _confirm() async {
    final formOk = _form.currentState!.validate();
    setState(() => _signatureMissing = _signature.isEmpty);
    if (!formOk || _signature.isEmpty) return;
    var differs = false;
    final items = <int, List<Map<String, dynamic>>>{};
    for (final e in _lines.entries) {
      items[e.key] = [
        for (final l in e.value)
          {
            'delivery_item_id': l.id,
            'received_quantity': l.received,
            if (l.received != l.sent) ...{
              'discrepancy_reason': l.reason,
              if (l.note.text.trim().isNotEmpty)
                'discrepancy_note': l.note.text.trim(),
            },
          },
      ];
      differs = differs || e.value.any((l) => l.received != l.sent);
    }
    final remarks = _remarks.text.trim();
    final counted = ReceiptCounts(
      items,
      remarks.isEmpty ? null : remarks,
      hasDifference: differs,
      handoverCode: _code.text.trim(),
      signerName: _name.text.trim(),
      signerPosition: _position.text.trim(),
      signature: _signature.drawing,
      slipPhoto: _slip,
    );
    final submit = widget.submit;
    if (submit == null) {
      Navigator.pop(context, counted);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final r = await submit(counted);
    if (!mounted) return;
    if (r.ok) {
      Navigator.pop(context, counted);
      return;
    }
    setState(() {
      _busy = false;
      _error = r.status == 0
          ? 'Cannot reach the server. Try again.'
          : r.errorText;
    });
  }

  Widget _lineFields(BuildContext context, _Line l) {
    final t = Theme.of(context).textTheme;
    final fits = l.fits;
    final direction = fits.isEmpty
        ? 'same'
        : (fits.first == overReason ? 'over' : 'short');
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.name, style: t.titleSmall),
          Text('Sent by CSWS: ${l.amount(l.sent)}', style: t.bodySmall),
          Gaps.v4,
          TextFormField(
            key: Key('count-${l.id}'),
            controller: l.count,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(9),
            ],
            decoration: InputDecoration(
              labelText: 'Received${l.unit.isEmpty ? '' : ' (${l.unit})'}',
              hintText: 'Count it',
            ),
            onChanged: (_) => _counted(l),
            validator: (v) => (v ?? '').trim().isEmpty
                ? 'Enter the number you counted'
                : null,
          ),
          if (fits.isNotEmpty) ...[
            Gaps.v8,
            DropdownButtonFormField<String>(
              // A new key when the count turns from fewer to more (or back),
              // so the menu shows only the reasons that fit.
              key: ValueKey('reason-${l.id}-$direction'),
              initialValue: l.reason,
              items: [
                for (final r in fits)
                  DropdownMenuItem(value: r, child: Text(r)),
              ],
              onChanged: (v) => setState(() => l.reason = v),
              decoration: InputDecoration(
                labelText: 'Why is it different?',
                helperText:
                    'You counted ${l.amount(l.received!)}; '
                    'CSWS sent ${l.amount(l.sent)}.',
              ),
              validator: (v) => v == null ? 'Choose a reason' : null,
            ),
            Gaps.v8,
            TextFormField(
              key: Key('note-${l.id}'),
              controller: l.note,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ],
        ],
      ),
    );
  }

  /// J2 / NF-015: the handover code, the signer and the signature.
  List<Widget> _proofFields(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return [
      const Divider(),
      Text('Proof of receipt', style: t.titleMedium),
      Gaps.v8,
      TextFormField(
        key: const Key('handover-code'),
        controller: _code,
        keyboardType: TextInputType.number,
        inputFormatters: [
          FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(6),
        ],
        decoration: const InputDecoration(
          labelText: 'Handover code',
          helperText:
              'Ask the CSWS staff (or the DRRMO driver) handing over the '
              'goods to show you the 6-digit code.',
          helperMaxLines: 3,
        ),
        validator: (v) => RegExp(r'^[0-9]{6}$').hasMatch((v ?? '').trim())
            ? null
            : 'Enter the 6-digit code',
      ),
      Gaps.v8,
      TextFormField(
        key: const Key('signer-name'),
        controller: _name,
        maxLength: 150,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(labelText: 'Your full name'),
        validator: (v) =>
            (v ?? '').trim().length < 2 ? 'Enter your full name' : null,
      ),
      TextFormField(
        key: const Key('signer-position'),
        controller: _position,
        maxLength: 100,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Your position',
          hintText: 'e.g. Barangay Secretary',
        ),
        validator: (v) =>
            (v ?? '').trim().length < 2 ? 'Enter your position' : null,
      ),
      Gaps.v8,
      Text('Your signature', style: t.titleSmall),
      Gaps.v4,
      SignaturePad(
        key: const Key('signature-pad'),
        controller: _signature,
        error: _signatureMissing,
      ),
      Row(
        children: [
          Expanded(
            child: _signatureMissing
                ? Text(
                    'Sign in the box',
                    style: t.bodySmall?.copyWith(color: cs.error),
                  )
                : const SizedBox.shrink(),
          ),
          TextButton(
            key: const Key('signature-clear'),
            onPressed: _busy ? null : _signature.clear,
            child: const Text('Clear'),
          ),
        ],
      ),
      OutlinedButton.icon(
        key: const Key('slip-photo'),
        onPressed: _busy ? null : _pickSlip,
        icon: Icon(
          _slip == null ? Icons.photo_camera_outlined : Icons.check_circle,
        ),
        label: Text(
          _slip == null
              ? 'Add a photo of the stamped slip (optional)'
              : 'Slip photo added. Take it again',
        ),
      ),
      Gaps.v4,
      Text(
        'Only the paper acknowledgment slip with the barangay seal. '
        'Do not photograph people or the goods.',
        style: t.bodySmall,
      ),
      if (_slip != null)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _busy ? null : () => setState(() => _slip = null),
            child: const Text('Remove the photo'),
          ),
        ),
      Gaps.v8,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final many = widget.deliveries.length > 1;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.message != null) ...[
                  Text(widget.message!),
                  Gaps.v12,
                ],
                for (final target in widget.deliveries) ...[
                  if (many)
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 8),
                      child: Text(target.title, style: t.titleMedium),
                    ),
                  for (final l in _lines[target.deliveryId]!)
                    _lineFields(context, l),
                ],
                ..._proofFields(context),
                TextFormField(
                  key: const Key('remarks'),
                  controller: _remarks,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Remarks (optional)',
                  ),
                ),
                if (_error != null) ...[
                  Gaps.v12,
                  Text(
                    _error!,
                    key: const Key('receipt-error'),
                    style: t.bodyMedium?.copyWith(color: cs.error),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-counts'),
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(many ? 'Confirm all' : 'Confirm receipt'),
        ),
      ],
    );
  }
}

/// On a delivery card: the lines the barangay counted differently, e.g.
/// "Barangay count differs: Rice: 40 of 50 kg (Short)". Nothing when every
/// count matched or nothing was counted yet.
class ReceiptDifferences extends StatelessWidget {
  final Map delivery;
  const ReceiptDifferences(this.delivery, {super.key});

  static String _line(Map it) {
    final sent = '${it['quantity']} ${it['unit'] ?? ''}'.trim();
    final why = it['discrepancy_reason'] != null
        ? ' (${it['discrepancy_reason']})'
        : '';
    return '${it['item_name'] ?? 'Item'}: ${it['received_quantity']} of $sent$why';
  }

  @override
  Widget build(BuildContext context) {
    final lines = [
      for (final it in (delivery['items'] as List? ?? const []).cast<Map>())
        if (it['received_quantity'] != null &&
            it['received_quantity'] != it['quantity'])
          _line(it),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.error;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.report_problem_outlined, size: 16, color: color),
          Gaps.h4,
          Expanded(
            child: Text(
              'Barangay count differs: ${lines.join('; ')}',
              style: TextStyle(fontSize: 12, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
