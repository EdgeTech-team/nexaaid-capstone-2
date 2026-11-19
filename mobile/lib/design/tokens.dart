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
  /// UI redesign (Nov 2026): a little less saturated (was 0xFFF5B82E).
  static const vest = Color(0xFFEEC25A);
  static const vestInk = Color(0xFF3A2A00); // text/icons on vest

  /// Deep teal ink for text on light backgrounds.
  static const ink = Color(0xFF12312F);

  /// Light page background (cool off-white) and dark page background.
  static const paper = Color(0xFFF5F8F7);
  static const night = Color(0xFF0E1B1A);

  /// UI redesign: cards, inputs and sheets are a very light off-white, never
  /// pure white, and text on teal is off-white too (easier on the eyes).
  static const surface = Color(0xFFFBFCFC);
  static const onDark = Color(0xFFF4F8F7);

  static const success = Color(0xFF2E8B3E);
  /// UI redesign: slightly softer red (was 0xFFC0362C), still 5.3:1 on the card color.
  static const danger = Color(0xFFB8423A);
}

/// A status color pair: [fg] for text and icons, [bg] for the soft tint
/// behind them. In dark mode the tint is the same hue at low opacity.
class Tint {
  final Color fg;
  final Color bg;
  const Tint(this.fg, this.bg);

  Color fgFor(Brightness b) =>
      b == Brightness.dark ? Color.lerp(fg, Colors.white, 0.45)! : fg;
  Color bgFor(Brightness b) =>
      b == Brightness.dark ? fg.withValues(alpha: 0.24) : bg;
}

/// UI redesign: the tints of icon tiles, badges and count pills. Each [Tint.fg]
/// passes 4.5:1 on its [Tint.bg]. Meaning, not decoration:
/// amber = waiting, blue = moving / info, red = late or failed,
/// green = done, teal = NexaAid / neutral action, neutral = no state.
abstract final class AppTints {
  static const amber = Tint(Color(0xFFB54708), Color(0xFFFFFAEB));
  static const blue = Tint(Color(0xFF175CD3), Color(0xFFEFF8FF));
  static const red = Tint(Color(0xFFB42318), Color(0xFFFEF3F2));
  static const green = Tint(Color(0xFF067647), Color(0xFFECFDF3));
  static const teal = Tint(AppColors.harborDeep, AppColors.harborMist);
  static const neutral = Tint(Color(0xFF475467), Color(0xFFF2F4F7));
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
