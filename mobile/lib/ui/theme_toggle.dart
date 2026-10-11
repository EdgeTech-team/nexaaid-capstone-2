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
