import 'package:flutter/material.dart';

/// NexaAid design tokens.
///
/// Screens should read colors from `Theme.of(context).colorScheme` so they
/// work in light and dark mode. Use these raw values only inside the theme,
/// the status palette, and illustrations.
abstract final class AppColors {
  /// Harbor teal: primary brand color (buttons, selected tabs, links).
  static const harbor = Color(0xFF0B6E69);
  static const harborDeep = Color(0xFF07514D);
  static const harborMist = Color(0xFFD5ECE9);

  /// Life-vest yellow: reserved for "Donate" actions so they stand out.
  static const vest = Color(0xFFF5B82E);
  static const vestInk = Color(0xFF3A2A00); // text/icons on vest

  /// Deep teal ink for text on light backgrounds.
  static const ink = Color(0xFF12312F);

  /// Light page background (cool off-white) and dark page background.
  static const paper = Color(0xFFF5F8F7);
  static const night = Color(0xFF0E1B1A);

  static const success = Color(0xFF2E8B3E);
  static const danger = Color(0xFFC0362C);
}

/// 8-point spacing scale. Use these instead of arbitrary numbers.
abstract final class Space {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;

  /// Default padding around a screen's content.
  static const page = EdgeInsets.fromLTRB(md, md, md, lg);
}

/// Ready-made gaps for Column (v) and Row (h).
abstract final class Gaps {
  static const v4 = SizedBox(height: 4);
  static const v8 = SizedBox(height: 8);
  static const v12 = SizedBox(height: 12);
  static const v16 = SizedBox(height: 16);
  static const v24 = SizedBox(height: 24);
  static const v32 = SizedBox(height: 32);
  static const h4 = SizedBox(width: 4);
  static const h8 = SizedBox(width: 8);
  static const h12 = SizedBox(width: 12);
  static const h16 = SizedBox(width: 16);
}

/// Corner radius scale. Smaller things get smaller radii.
abstract final class Radii {
  static const double sm = 8; // chips inside cards, skeleton lines
  static const double md = 12; // buttons, inputs
  static const double lg = 16; // cards
  static const double xl = 24; // dialogs, bottom sheets, hero
  static const double pill = 999;
}

/// Motion. Keep animations short and only where they explain a change.
abstract final class Motion {
  static const fast = Duration(milliseconds: 150);
  static const normal = Duration(milliseconds: 250);
  static const curve = Curves.easeOutCubic;
}

/// Width breakpoints for adaptive layouts.
abstract final class Breakpoints {
  static const double medium = 600; // large phones landscape, small tablets
  static const double expanded = 840; // tablets, Chrome: switch to a rail
  static const double contentMax = 720; // max width of reading content
}
