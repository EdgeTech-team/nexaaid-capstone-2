  import 'package:flutter/material.dart';
  import 'package:flutter/services.dart';

  import '../tokens.dart';
  import 'app_icons.dart';

  class FloatingNavItem {
    final IconData icon;
    final String label;

    /// UI redesign: the [AppIcon] name to draw instead of [icon]. Null keeps
    /// the Material icon.
    final String? art;
    const FloatingNavItem(this.icon, this.label, {this.art});
  }

  /// Floating dark pill navigation that spans the screen width, with the
  /// icons spread evenly. The selected tab sits in a white circle. Every
  /// button has a tooltip (long-press) and a screen-reader label.
  class FloatingNavBar extends StatelessWidget {
    final List<FloatingNavItem> items;
    final int selectedIndex;
    final ValueChanged<int> onSelected;

    const FloatingNavBar({
      super.key,
      required this.items,
      required this.selectedIndex,
      required this.onSelected,
    });

   static const double _height = 60;
   static const double _circle = 48;

    @override
    Widget build(BuildContext context) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return SafeArea(
      top: false,
      // UI concern: less empty space around the bar.
      minimum: const EdgeInsets.only(bottom: Space.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          child: Container(
            height: _height,
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF243130) : const Color(0xFF161B1B),
              borderRadius: BorderRadius.circular(Radii.pill),
              border: dark ? Border.all(color: Colors.white12) : null,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  Expanded(
                    child: _NavButton(
                      item: items[i],
                      selected: i == selectedIndex,
                      onTap: () {
                        if (i == selectedIndex) return;
                        HapticFeedback.selectionClick();
                        onSelected(i);
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
  }

  class _NavButton extends StatelessWidget {
    final FloatingNavItem item;
    final bool selected;
    final VoidCallback onTap;

    const _NavButton({
      required this.item,
      required this.selected,
      required this.onTap,
    });

    @override
    Widget build(BuildContext context) {
      final still = MediaQuery.disableAnimationsOf(context);
      return Tooltip(
        message: item.label,
        excludeFromSemantics: true,
        child: Semantics(
          button: true,
          selected: selected,
          label: item.label,
          excludeSemantics: true,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              customBorder: const CircleBorder(),
              child: Center(
                child: AnimatedContainer(
                  duration: still ? Duration.zero : Motion.normal,
                  curve: Motion.curve,
                  width: FloatingNavBar._circle,
                  height: FloatingNavBar._circle,
                  decoration: BoxDecoration(
                    color: selected ? AppColors.onDark : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                  child: item.art != null && AppIcon.has(item.art!)
                      ? AppIcon(
                          item.art!,
                          color: selected
                              ? AppColors.ink
                              : AppColors.onDark.withValues(alpha: 0.85),
                        )
                      : Icon(
                          item.icon,
                          size: 24,
                          color: selected
                              ? AppColors.ink
                              : Colors.white.withValues(alpha: 0.85),
                        ),
                ),
              ),
            ),
          ),
        ),
      );
    }
  }