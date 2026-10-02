import 'package:flutter/material.dart';

/// Colors sampled from the Nexaaid design (Nexaaid.pdf).
class NexaColors {
  static const coral = Color(0xFFFF5A57); // header bar, primary buttons
  static const pink = Color(0xFFFF69C0); // progress fill, accent pills
  static const teal = Color(0xFF3E8A9E); // progress track
  static const orange = Color(0xFFFF8C4B); // Medium badge, need chips
  static const red = Color(0xFFFF3B30); // High badge
  static const gradientStart = Color(0xFFFFF6B0);
  static const gradientEnd = Color(0xFFFFA8F5);
}

Color priorityColor(String? level) {
  switch (level) {
    case 'Critical':
      return const Color(0xFFC62828);
    case 'High':
      return NexaColors.red;
    case 'Medium':
      return NexaColors.orange;
    case 'Low':
      return NexaColors.teal;
    default:
      return Colors.grey; // Needs Review / Review Required / null
  }
}

String priorityText(String? level) {
  if (level == null) return 'Unrated';
  if (level == 'Needs Review' || level == 'Review Required') return level;
  return '$level Priority';
}
