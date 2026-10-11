import 'package:flutter/material.dart';

import '../design/design.dart';

/// The light/dark picker for people who are not signed in: the rightmost
/// button of the landing page header (never inside the sign-in pop-out).
/// It offers the same three choices as Profile > Appearance (System,
/// Light, Dark) and changes the same [AppTheme.mode], so the choice
/// carries over after signing in.
class ThemeToggleButton extends StatelessWidget {
  /// Icon color, e.g. white on the dark landing hero.
  final Color? color;
  const ThemeToggleButton({super.key, this.color});

  static const _choices = [
    (ThemeMode.system, Icons.brightness_auto_outlined, 'System'),
    (ThemeMode.light, Icons.light_mode_outlined, 'Light'),
    (ThemeMode.dark, Icons.dark_mode_outlined, 'Dark'),
  ];

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final cs = Theme.of(context).colorScheme;
        return PopupMenuButton<ThemeMode>(
          tooltip: 'Light or dark mode',
          initialValue: mode,
          onSelected: (m) => AppTheme.mode.value = m,
          icon: Icon(
            dark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
            color: color,
          ),
          itemBuilder: (_) => [
            for (final (value, icon, label) in _choices)
              PopupMenuItem<ThemeMode>(
                value: value,
                child: Row(
                  children: [
                    Icon(icon, size: 20),
                    Gaps.h12,
                    Expanded(child: Text(label)),
                    if (value == mode)
                      Icon(Icons.check, size: 18, color: cs.primary),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Ivan (Profile, top-right corner): one tap switches light and dark mode.
/// The icon shows the mode you are in: a moon in dark mode, a sun in light
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
