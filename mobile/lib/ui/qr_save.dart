import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../design/design.dart';

// ---------------------------------------------------------------------------
// Daniel's note (Oct 10): the donor can save the QR image on their phone,
// so they can show it at the CSWS office (Drop Off) or to the pickup team
// (Door to Door) even without opening the app or having internet.
//
// The saved picture is a small "QR pass": the QR code on white (so it scans
// from any screen), the reference written out, and how to hand it over.
// It is drawn on a canvas, so nothing on screen changes while saving.
// Saving uses the phone's own "Save to" screen (file_picker): no storage
// permission is needed, and the donor chooses Pictures or Downloads.
// ---------------------------------------------------------------------------

/// Builds the QR pass as PNG bytes.
Future<Uint8List> buildQrPass({
  required String qrBase64,
  required String reference,
  String? handover,
  String? forReport,
}) async {
  const w = 720.0, h = 980.0, pad = 48.0;
  final recorder = ui.PictureRecorder();
  final c = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

  // Card
  c.drawRect(const Rect.fromLTWH(0, 0, w, h), Paint()..color = AppColors.paper);
  final card = RRect.fromRectAndRadius(
    const Rect.fromLTWH(24, 24, w - 48, h - 48),
    const Radius.circular(36),
  );
  c.drawRRect(card, Paint()..color = Colors.white);
  c.save();
  c.clipRRect(card);
  c.drawRect(
    const Rect.fromLTWH(24, 24, w - 48, 150),
    Paint()..color = AppColors.harbor,
  );
  c.restore();

  void text(
    String s,
    double y, {
    double size = 28,
    Color color = AppColors.ink,
    FontWeight weight = FontWeight.w500,
    String? family,
    double letter = 0,
  }) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontSize: size,
          color: color,
          fontWeight: weight,
          fontFamily: family,
          letterSpacing: letter,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 2,
      ellipsis: '…',
    )..layout(maxWidth: w - pad * 2 - 48);
    tp.paint(c, Offset((w - tp.width) / 2, y));
  }

  text('NexaAid', 58, size: 44, color: Colors.white, weight: FontWeight.w800);
  text('Mandaue City donation QR', 116, size: 24, color: AppColors.harborMist);

  // QR code
  final codec = await ui.instantiateImageCodec(base64Decode(qrBase64));
  final frame = await codec.getNextFrame();
  const qrSize = 470.0;
  const qrTop = 220.0;
  final src = Rect.fromLTWH(
    0,
    0,
    frame.image.width.toDouble(),
    frame.image.height.toDouble(),
  );
  c.drawImageRect(
    frame.image,
    src,
    const Rect.fromLTWH((w - qrSize) / 2, qrTop, qrSize, qrSize),
    Paint()..filterQuality = FilterQuality.none, // keep the squares sharp
  );

  text(
    reference,
    qrTop + qrSize + 24,
    size: 34,
    weight: FontWeight.w800,
    family: 'monospace',
    letter: 1.5,
  );
  final how = handover == 'Door to Door'
      ? 'Show this to the CSWS team when they pick up your goods.'
      : 'Show this at the CSWS office when you drop off your goods.';
  text(how, qrTop + qrSize + 84, size: 24, color: AppColors.ink);
  if (forReport != null && forReport.trim().isNotEmpty) {
    text(
      'For $forReport',
      qrTop + qrSize + 154,
      size: 22,
      color: const Color(0xFF5B6B69),
    );
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(w.toInt(), h.toInt());
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// "Save QR image" button. Shows a message when it is saved (or why not).
class SaveQrButton extends StatefulWidget {
  final String? qrBase64;
  final String reference;
  final String? handover;
  final String? forReport;

  const SaveQrButton({
    super.key,
    required this.qrBase64,
    required this.reference,
    this.handover,
    this.forReport,
  });

  @override
  State<SaveQrButton> createState() => _SaveQrButtonState();
}

class _SaveQrButtonState extends State<SaveQrButton> {
  bool _busy = false;

  Future<void> _save() async {
    final b64 = widget.qrBase64;
    if (b64 == null) return;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    String message;
    try {
      final bytes = await buildQrPass(
        qrBase64: b64,
        reference: widget.reference,
        handover: widget.handover,
        forReport: widget.forReport,
      );
      final where = await FilePicker.saveFile(
        dialogTitle: 'Save your donation QR',
        fileName: 'NexaAid-QR-${widget.reference}.png',
        bytes: bytes,
        mimeType: 'image/png',
        type: FileType.image,
      );
      message = where == null
          ? 'Not saved.'
          : 'QR image saved. You can show it even without internet.';
    } catch (_) {
      message = 'Could not save the QR image. Take a screenshot instead.';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: widget.qrBase64 == null || _busy ? null : _save,
      icon: _busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined),
      label: const Text('Save QR image'),
    );
  }
}
