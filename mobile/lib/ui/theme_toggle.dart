import 'package:flutter/material.dart';

import '../design/design.dart';

/// Ivan (landing page header and Profile, top-right): one tap switches
/// light and dark mode. The icon shows the mode you are in: a moon in dark mode, a sun in light
/// mode (when the phone decides, the icon follows what is on screen).
class SunMoonToggle extends StatelessWidget {
  const SunMoonToggle({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, _, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        return IconButton.filledTonal(
          tooltip: dark
              ? 'Dark mode is on. Switch to light mode'
              : 'Light mode is on. Switch to dark mode',
          onPressed: () =>
              AppTheme.mode.value = dark ? ThemeMode.light : ThemeMode.dark,
          icon: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : Motion.normal,
            transitionBuilder: (child, anim) =>
                RotationTransition(turns: anim, child: child),
            child: Icon(
              dark ? Icons.dark_mode : Icons.light_mode,
              key: ValueKey(dark),
            ),
          ),
        );
      },
    );
  }
}
