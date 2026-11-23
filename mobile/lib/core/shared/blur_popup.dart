import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// UI concern (new notes): log in and registration open as pop-up cards
/// over the landing page, which stays visible behind them with a slight
/// blur.
///
/// [dismissible]: tapping outside the card or pressing Esc closes it. Turn
/// it off for long forms so a stray tap doesn't throw away what was typed;
/// the card's own close button still works.
///
/// The card grows to fit [child] up to [maxWidth] x [maxHeight] (and the
/// screen). A child with its own Scaffold fills that space and scrolls.
Future<T?> showBlurPopup<T>(
  BuildContext context, {
  required String label,
  required Widget child,
  bool dismissible = true,
  double maxWidth = 440,
  double maxHeight = double.infinity,
}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: label,
    barrierColor: Colors.transparent, // the blur below draws the backdrop
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, _, _) {
      final cs = Theme.of(ctx).colorScheme;
      return SafeArea(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 120),
          padding: MediaQuery.viewInsetsOf(ctx), // room for the keyboard
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: maxHeight,
                ),
                child: Material(
                  color: cs.surface,
                  elevation: 12,
                  borderRadius: BorderRadius.circular(24),
                  clipBehavior: Clip.antiAlias,
                  child: child,
                ),
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (ctx, anim, _, card) {
      final still = MediaQuery.disableAnimationsOf(ctx);
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return AnimatedBuilder(
        animation: curved,
        child: card,
        builder: (bctx, inner) {
          final v = still ? 1.0 : curved.value;
          return Stack(
            children: [
              // The landing page behind: slightly blurred and dimmed.
              Positioned.fill(
                child: GestureDetector(
                  onTap: dismissible
                      ? () => Navigator.of(bctx).maybePop()
                      : null,
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 6 * v, sigmaY: 6 * v),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.3 * v),
                    ),
                  ),
                ),
              ),
              Opacity(
                opacity: v,
                child: Transform.scale(scale: 0.96 + 0.04 * v, child: inner),
              ),
            ],
          );
        },
      );
    },
  );
}