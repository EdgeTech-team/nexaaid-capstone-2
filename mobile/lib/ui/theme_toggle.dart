import 'package:flutter/material.dart';

import '../design/design.dart';

/// Sun / moon button that flips between light and dark mode.
///
/// Signed out: rightmost button of the landing page header.
/// Signed in: Profile > Appearance (the System / Light / Dark picker).
/// Both change the same [AppTheme.mode].
class ThemeToggleButton extends StatelessWidget {
  /// Icon color, e.g. on the dark landing hero.
  final Color? color;
  const ThemeToggleButton({super.key, this.color});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return IconButton(
          tooltip: dark ? 'Switch to light mode' : 'Switch to dark mode',
          color: color,
          onPressed: () =>
              AppTheme.mode.value = dark ? ThemeMode.light : ThemeMode.dark,
          icon: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.normal,
            transitionBuilder: (child, anim) => RotationTransition(
              turns: Tween(begin: 0.75, end: 1.0).animate(anim),
              child: FadeTransition(opacity: anim, child: child),
            ),
            child: Icon(
              dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              key: ValueKey(dark),
            ),
          ),
        );
      },
    );
  }
}
