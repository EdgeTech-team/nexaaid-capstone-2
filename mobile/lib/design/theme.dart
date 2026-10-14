import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

/// Builds the NexaAid light and dark themes.
///
/// Type: Lexend for headings and titles (designed for reading ease, which
/// also helps the Phase 4 accessibility testing) and Source Sans 3 for body
/// text and labels.
abstract final class AppTheme {
  /// Widget tests cannot download fonts, so they set this to false.
  static bool useGoogleFonts = true;

  /// The user's choice in Profile > Appearance.
  static final mode = ValueNotifier<ThemeMode>(ThemeMode.system);

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness b) {
    final dark = b == Brightness.dark;
    final seeded = ColorScheme.fromSeed(
      seedColor: AppColors.harbor,
      brightness: b,
    );
    final cs = dark
        ? seeded.copyWith(
            surface: AppColors.night,
            tertiary: AppColors.vest,
            onTertiary: AppColors.vestInk,
          )
        : seeded.copyWith(
            primary: AppColors.harbor,
            onPrimary: Colors.white,
            surface: AppColors.paper,
            surfaceContainerLowest: Colors.white,
            tertiary: AppColors.vest,
            onTertiary: AppColors.vestInk,
            error: AppColors.danger,
          );
    final cardColor = dark ? cs.surfaceContainer : cs.surfaceContainerLowest;
    final text = _textTheme(b, cs);

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.md),
    );
    final buttonText = text.labelLarge?.copyWith(fontSize: 15);
    OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(Radii.md),
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: cs,
      scaffoldBackgroundColor: cs.surface,
      textTheme: text,
      appBarTheme: AppBarTheme(
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.7)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          padding: const EdgeInsets.symmetric(horizontal: Space.lg),
          shape: buttonShape,
          textStyle: buttonText,
          side: BorderSide(color: cs.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, 44),
          shape: buttonShape,
          textStyle: buttonText,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? cs.surfaceContainerHigh : Colors.white,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: 14,
        ),
        border: field(cs.outlineVariant),
        enabledBorder: field(cs.outlineVariant),
        focusedBorder: field(cs.primary, 2),
        errorBorder: field(cs.error),
        focusedErrorBorder: field(cs.error, 2),
        helperMaxLines: 3,
        errorMaxLines: 3,
      ),
      chipTheme: ChipThemeData(
        labelStyle: text.labelLarge,
        side: BorderSide(color: cs.outlineVariant),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.sm),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 68,
        elevation: 0,
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        indicatorColor: cs.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (s) => text.labelSmall?.copyWith(
            fontSize: 12,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: cardColor,
        indicatorColor: cs.primaryContainer,
        selectedLabelTextStyle: text.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: text.labelLarge,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.xl),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: cardColor,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
        ),
      ),
      dividerTheme: DividerThemeData(color: cs.outlineVariant, space: 1),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    );
  }

  static TextTheme _textTheme(Brightness b, ColorScheme cs) {
    var t = ThemeData(brightness: b, useMaterial3: true).textTheme;
    if (useGoogleFonts) {
      t = GoogleFonts.sourceSans3TextTheme(t);
      final h = GoogleFonts.lexendTextTheme(t);
      t = t.copyWith(
        displayLarge: h.displayLarge,
        displayMedium: h.displayMedium,
        displaySmall: h.displaySmall,
        headlineLarge: h.headlineLarge,
        headlineMedium: h.headlineMedium,
        headlineSmall: h.headlineSmall,
        titleLarge: h.titleLarge,
        titleMedium: h.titleMedium,
      );
    }
    t = t.copyWith(
      displaySmall: t.displaySmall?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.5,
      ),
      headlineMedium: t.headlineMedium?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.15,
        letterSpacing: -0.3,
      ),
      headlineSmall: t.headlineSmall?.copyWith(
        fontWeight: FontWeight.w700,
        height: 1.2,
      ),
      titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: t.bodyLarge?.copyWith(fontSize: 17, height: 1.45),
      bodyMedium: t.bodyMedium?.copyWith(fontSize: 15, height: 1.4),
      bodySmall: t.bodySmall?.copyWith(fontSize: 13, height: 1.35),
      labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: t.labelMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    return t.apply(bodyColor: cs.onSurface, displayColor: cs.onSurface);
  }
}
