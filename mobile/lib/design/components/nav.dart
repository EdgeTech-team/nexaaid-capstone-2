import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens.dart';

class FloatingNavItem {
  final IconData icon;
  final String label;
  const FloatingNavItem(this.icon, this.label);
}

/// Floating dark pill navigation. Icons only; the selected tab sits in a
/// white circle and also shows its name when there is room. Every button
/// has a tooltip (long-press) and a screen-reader label.
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

  static const double _item = 48;
  static const double _pad = 6;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final labelStyle = Theme.of(context).textTheme.labelLarge
        ?.copyWith(color: AppColors.ink, fontWeight: FontWeight.w700);

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: Space.sm),
      child: LayoutBuilder(
        builder: (context, c) {
          // Show the selected tab's name only if the whole pill still fits.
          final tp = TextPainter(
            text: TextSpan(text: items[selectedIndex].label, style: labelStyle),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
          )..layout();
          final needed =
              items.length * _item + _pad * 2 + tp.width + Space.xs + Space.md;
          final showLabel = needed <= c.maxWidth - Space.lg * 2;
          tp.dispose();

          return Align(
            alignment: Alignment.bottomCenter,
            heightFactor: 1,
            child: Container(
              padding: const EdgeInsets.all(_pad),
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++)
                    _NavButton(
                      item: items[i],
                      selected: i == selectedIndex,
                      showLabel: showLabel && i == selectedIndex,
                      labelStyle: labelStyle,
                      onTap: () {
                        if (i == selectedIndex) return;
                        HapticFeedback.selectionClick();
                        onSelected(i);
                      },
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  final FloatingNavItem item;
  final bool selected;
  final bool showLabel;
  final TextStyle? labelStyle;
  final VoidCallback onTap;

  const _NavButton({
    required this.item,
    required this.selected,
    required this.showLabel,
    required this.labelStyle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final still = MediaQuery.disableAnimationsOf(context);
    final duration = still ? Duration.zero : Motion.normal;
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
            customBorder: const StadiumBorder(),
            child: AnimatedContainer(
              duration: duration,
              curve: Motion.curve,
              height: FloatingNavBar._item,
              constraints: const BoxConstraints(minWidth: FloatingNavBar._item),
              padding: EdgeInsets.symmetric(horizontal: showLabel ? 16 : 0),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? Colors.white : Colors.transparent,
                borderRadius: BorderRadius.circular(Radii.pill),
              ),
              child: AnimatedSize(
                duration: duration,
                curve: Motion.curve,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      item.icon,
                      size: 22,
                      color: selected
                          ? AppColors.ink
                          : Colors.white.withValues(alpha: 0.85),
                    ),
                    if (showLabel) ...[
                      Gaps.h8,
                      Text(item.label, style: labelStyle, maxLines: 1),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
