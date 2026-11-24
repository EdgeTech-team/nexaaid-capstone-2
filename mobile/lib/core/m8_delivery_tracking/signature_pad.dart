// J2 / NF-015 (team agreement A2): the Barangay Receiving Representative's
// e-signature. Drawn with a finger on a white box, kept as strokes, and
// turned into a small PNG only when the receipt is sent. Built with
// Flutter's CustomPainter, no extra package.
//
// The e-signature is a record that the representative acknowledged the
// goods in NexaAid; it is not a certified digital signature.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// What was drawn: the strokes, in the pad's coordinates, and the pad's size.
class SignatureDrawing {
  final List<List<Offset>> strokes;
  final Size size;
  const SignatureDrawing(this.strokes, this.size);

  bool get isEmpty => strokes.every((s) => s.isEmpty);

  /// Black strokes on white, at the pad's size, as PNG bytes; null when empty.
  Future<Uint8List?> toPng() async {
    if (isEmpty || size.isEmpty) return null;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Offset.zero & size);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    paintSignature(canvas, strokes);
    final image = await recorder.endRecording().toImage(
      size.width.ceil(),
      size.height.ceil(),
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }
}

/// Draws [strokes] with a dark round pen.
void paintSignature(Canvas canvas, List<List<Offset>> strokes) {
  final pen = Paint()
    ..color = const Color(0xFF111111)
    ..strokeWidth = 2.5
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..style = PaintingStyle.stroke;
  for (final s in strokes) {
    if (s.isEmpty) continue;
    if (s.length == 1) {
      canvas.drawCircle(s.first, 1.5, Paint()..color = pen.color);
      continue;
    }
    final path = Path()..moveTo(s.first.dx, s.first.dy);
    for (final p in s.skip(1)) {
      path.lineTo(p.dx, p.dy);
    }
    canvas.drawPath(path, pen);
  }
}

/// The strokes on one pad. [drawing] is a copy that can be kept after the
/// pad is gone.
class SignatureController extends ChangeNotifier {
  final List<List<Offset>> _strokes = [];
  Size _size = Size.zero;

  bool get isEmpty => _strokes.every((s) => s.isEmpty);

  SignatureDrawing get drawing =>
      SignatureDrawing([for (final s in _strokes) List.of(s)], _size);

  void clear() {
    _strokes.clear();
    notifyListeners();
  }

  void _start(Offset p) {
    _strokes.add([p]);
    notifyListeners();
  }

  void _extend(Offset p) {
    if (_strokes.isEmpty) return;
    _strokes.last.add(p);
    notifyListeners();
  }
}

/// Takes the touch at once, so drawing inside a scrolling form does not
/// scroll the form instead.
class _DrawGesture extends PanGestureRecognizer {
  _DrawGesture({super.debugOwner});

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

class SignaturePad extends StatelessWidget {
  final SignatureController controller;
  final double height;

  /// Red border: the form was sent without a signature.
  final bool error;

  const SignaturePad({
    super.key,
    required this.controller,
    this.height = 160,
    this.error = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, height);
        controller._size = size;
        Offset inside(Offset p) =>
            Offset(p.dx.clamp(0.0, size.width), p.dy.clamp(0.0, size.height));
        return Semantics(
          label: 'Signature box. Sign here with your finger.',
          child: Container(
            height: height,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: error ? cs.error : cs.outline,
                width: error ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: RawGestureDetector(
                behavior: HitTestBehavior.opaque,
                gestures: {
                  _DrawGesture:
                      GestureRecognizerFactoryWithHandlers<_DrawGesture>(
                        () => _DrawGesture(debugOwner: this),
                        (g) {
                          g.onStart = (d) =>
                              controller._start(inside(d.localPosition));
                          g.onUpdate = (d) =>
                              controller._extend(inside(d.localPosition));
                        },
                      ),
                },
                child: Stack(
                  children: [
                    CustomPaint(
                      painter: _SignaturePainter(controller),
                      size: size,
                    ),
                    IgnorePointer(
                      child: ListenableBuilder(
                        listenable: controller,
                        builder: (context, _) => controller.isEmpty
                            ? const Center(
                                child: Text(
                                  'Sign here',
                                  style: TextStyle(color: Colors.black38),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SignaturePainter extends CustomPainter {
  final SignatureController controller;
  _SignaturePainter(this.controller) : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) =>
      paintSignature(canvas, controller._strokes);

  @override
  bool shouldRepaint(_SignaturePainter oldDelegate) =>
      oldDelegate.controller != controller;
}
