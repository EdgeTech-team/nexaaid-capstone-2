import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Ivan (dashboard design): reports have no photos, so every report card
/// shows a flat illustration for its disaster type. Drawn in code (no image
/// files), in NexaAid's colors, and it scales to any size like a cover
/// image.
enum DisasterKind { flood, fire, typhoon, earthquake, landslide, other }

/// Picks the illustration from a disaster type name ("Flood", "Fire", ...).
DisasterKind disasterKind(Object? name) {
  final n = '${name ?? ''}'.toLowerCase();
  if (n.contains('flood')) return DisasterKind.flood;
  if (n.contains('fire')) return DisasterKind.fire;
  if (n.contains('typhoon') || n.contains('storm') || n.contains('wind')) {
    return DisasterKind.typhoon;
  }
  if (n.contains('quake')) return DisasterKind.earthquake;
  if (n.contains('slide')) return DisasterKind.landslide;
  return DisasterKind.other;
}

/// The disaster type from a "Flood in Banilad" style label.
DisasterKind disasterKindOfLabel(Object? label) =>
    disasterKind('${label ?? ''}'.split(' in ').first);

/// Decorative picture for a disaster type. Screen readers skip it: the card
/// next to it already says what the disaster is.
class DisasterArt extends StatelessWidget {
  final DisasterKind kind;
  final double? width;
  final double height;
  final BorderRadius borderRadius;

  const DisasterArt(
    this.kind, {
    super.key,
    this.width,
    this.height = 120,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: SizedBox(
          width: width ?? double.infinity,
          height: height,
          child: CustomPaint(painter: _ArtPainter(kind)),
        ),
      ),
    );
  }
}

// All scenes are drawn on a 252 x 140 board, scaled to cover the box.
const _w = 252.0;
const _h = 140.0;

const _teal = Color(0xFF0B6E69);
const _tealLight = Color(0xFF3E9C96);
const _ink = Color(0xFF12312F);
const _wood = Color(0xFF7A5A44);
const _red = Color(0xFFC0362C);
const _orange = Color(0xFFD9480F);
const _yellow = Color(0xFFF5B82E);
const _ochre = Color(0xFFB7791F);
const _green = Color(0xFF2E8B3E);
const _storm = Color(0xFF3B5B7A);

class _ArtPainter extends CustomPainter {
  final DisasterKind kind;
  const _ArtPainter(this.kind);

  static Paint _fill(Color c) => Paint()..color = c;
  static Paint _stroke(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  static Path _tri(double ax, double ay, double bx, double by, double cx,
      double cy) =>
      Path()
        ..moveTo(ax, ay)
        ..lineTo(bx, by)
        ..lineTo(cx, cy)
        ..close();

  /// A simple house: roof triangle, white wall, optional door.
  static void _house(
    Canvas c, {
    required double left,
    required double top,
    required double width,
    required double height,
    required Color roof,
    bool door = true,
  }) {
    c.drawPath(
      _tri(left - 12, top + 2, left + width / 2, top - 34, left + width + 12,
          top + 2),
      _fill(roof),
    );
    c.drawRect(Rect.fromLTWH(left, top, width, height), _fill(Colors.white));
    if (door) {
      c.drawRect(
        Rect.fromLTWH(left + width / 2 - 7, top + height - 26, 14, 26),
        _fill(_ink),
      );
    }
  }

  static Path _wave(double y, double dip) {
    final p = Path()..moveTo(0, y);
    for (double x = 0; x < _w; x += 50) {
      p.quadraticBezierTo(x + 25, y - dip, x + 50, y);
    }
    return p
      ..lineTo(_w, _h)
      ..lineTo(0, _h)
      ..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    // Cover: fill the box, crop the overflow, keep the scene centered.
    final s = math.max(size.width / _w, size.height / _h);
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.translate((size.width - _w * s) / 2, (size.height - _h * s) / 2);
    canvas.scale(s);
    switch (kind) {
      case DisasterKind.flood:
        _flood(canvas);
      case DisasterKind.fire:
        _fire(canvas);
      case DisasterKind.typhoon:
        _typhoon(canvas);
      case DisasterKind.earthquake:
        _earthquake(canvas);
      case DisasterKind.landslide:
        _landslide(canvas);
      case DisasterKind.other:
        _other(canvas);
    }
    canvas.restore();
  }

  void _bg(Canvas c, Color color) =>
      c.drawRect(const Rect.fromLTWH(0, 0, _w, _h), _fill(color));

  void _flood(Canvas c) {
    _bg(c, const Color(0xFFD5ECE9));
    c.drawCircle(
      const Offset(210, 32),
      14,
      _fill(Colors.white.withValues(alpha: 0.8)),
    );
    _house(c, left: 62, top: 86, width: 66, height: 40, roof: _red);
    _house(
      c,
      left: 160,
      top: 92,
      width: 50,
      height: 34,
      roof: _ochre,
      door: false,
    );
    c.drawPath(_wave(104, 8), _fill(_tealLight));
    c.drawPath(_wave(116, 8), _fill(_teal));
  }

  void _fire(Canvas c) {
    _bg(c, const Color(0xFFFCE6D6));
    _house(c, left: 88, top: 98, width: 76, height: 42, roof: _wood);
    c.drawPath(
      Path()
        ..moveTo(142, 80)
        ..cubicTo(132, 62, 146, 52, 144, 36)
        ..cubicTo(160, 48, 168, 62, 160, 80)
        ..close(),
      _fill(_orange),
    );
    c.drawPath(
      Path()
        ..moveTo(146, 80)
        ..cubicTo(142, 70, 148, 64, 148, 54)
        ..cubicTo(156, 62, 158, 70, 154, 80)
        ..close(),
      _fill(_yellow),
    );
    c.drawPath(
      Path()
        ..moveTo(104, 86)
        ..cubicTo(96, 72, 106, 64, 104, 54)
        ..cubicTo(116, 64, 118, 74, 114, 86)
        ..close(),
      _fill(_orange),
    );
  }

  void _typhoon(Canvas c) {
    _bg(c, const Color(0xFFDCE7F2));
    final swirl = _stroke(_storm, 5);
    c.drawArc(
      Rect.fromCircle(center: const Offset(172, 48), radius: 18),
      0,
      math.pi * 1.6,
      false,
      swirl,
    );
    c.drawArc(
      Rect.fromCircle(center: const Offset(172, 48), radius: 8),
      math.pi,
      math.pi * 1.4,
      false,
      swirl,
    );
    final rain = _stroke(_storm, 3);
    for (final x in [40.0, 60, 80, 100]) {
      c.drawLine(Offset(x, 30), Offset(x - 8, 48), rain);
    }
    c.drawPath(
      Path()
        ..moveTo(78, 140)
        ..cubicTo(80, 116, 86, 98, 96, 86),
      _stroke(_wood, 6),
    );
    final leaf = _stroke(_green, 6);
    c.drawPath(Path()..moveTo(96, 86)..cubicTo(112, 78, 126, 82, 132, 90), leaf);
    c.drawPath(Path()..moveTo(96, 86)..cubicTo(86, 70, 74, 68, 62, 72), leaf);
    c.drawPath(Path()..moveTo(96, 86)..cubicTo(104, 70, 116, 66, 128, 68), leaf);
    c.drawRect(
      const Rect.fromLTWH(0, 128, _w, 12),
      _fill(const Color(0xFFB8C9DA)),
    );
  }

  void _earthquake(Canvas c) {
    _bg(c, const Color(0xFFEFE7DA));
    c.drawRect(
      const Rect.fromLTWH(0, 108, _w, 32),
      _fill(const Color(0xFFC9B79C)),
    );
    c.drawPath(
      Path()
        ..moveTo(60, 108)
        ..lineTo(96, 108)
        ..lineTo(108, 96)
        ..lineTo(118, 118)
        ..lineTo(140, 108)
        ..lineTo(190, 108),
      _stroke(const Color(0xFF5E4532), 3),
    );
    c.save();
    c.translate(126, 78);
    c.rotate(-8 * math.pi / 180);
    c.translate(-126, -78);
    _house(c, left: 96, top: 76, width: 60, height: 34, roof: _ochre);
    c.restore();
  }

  void _landslide(Canvas c) {
    _bg(c, const Color(0xFFE3EDDC));
    c.drawPath(
      Path()
        ..moveTo(0, 140)
        ..lineTo(0, 60)
        ..quadraticBezierTo(60, 20, 130, 50)
        ..lineTo(_w, 140)
        ..close(),
      _fill(const Color(0xFF8A6B4E)),
    );
    c.drawPath(
      Path()
        ..moveTo(60, 40)
        ..quadraticBezierTo(90, 30, 120, 48),
      _stroke(_green, 6),
    );
    final rock = _fill(const Color(0xFF6E5440));
    c.drawCircle(const Offset(150, 104), 10, rock);
    c.drawCircle(const Offset(176, 118), 8, rock);
    c.drawCircle(const Offset(130, 122), 7, rock);
    _house(
      c,
      left: 196,
      top: 116,
      width: 36,
      height: 24,
      roof: _red,
      door: false,
    );
  }

  void _other(Canvas c) {
    _bg(c, const Color(0xFFEEF3F2));
    final line = _stroke(const Color(0xFF4A615E), 4);
    c.drawPath(_tri(126, 34, 160, 94, 92, 94), line);
    c.drawLine(const Offset(126, 58), const Offset(126, 76), line);
    c.drawLine(const Offset(126, 84), const Offset(126, 86), line);
  }

  @override
  bool shouldRepaint(_ArtPainter old) => old.kind != kind;
}
