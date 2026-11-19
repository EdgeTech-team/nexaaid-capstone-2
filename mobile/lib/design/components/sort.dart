import 'package:flutter/material.dart';

import '../tokens.dart';
import 'app_icons.dart';

/// One choice in a sort sheet.
class SortOption<T> {
  final T value;
  final String label;
  const SortOption(this.value, this.label);
}

/// UI redesign: the "Sort: Most urgent" pill above a list. Tapping it opens
/// [showSortSheet]. Always shows the current choice, so people can see how
/// the list is ordered without opening anything.
class SortButton extends StatelessWidget {
  final String current;
  final VoidCallback onPressed;
  const SortButton({super.key, required this.current, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark ? cs.primary : AppColors.harborDeep;
    return Semantics(
      button: true,
      label: 'Sort: $current. Change the order',
      excludeSemantics: true,
      child: OutlinedButton.icon(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 44),
          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          foregroundColor: fg,
          backgroundColor: AppTints.teal.bgFor(Theme.of(context).brightness),
          side: BorderSide(color: cs.primary, width: 1.5),
          shape: const StadiumBorder(),
          textStyle: Theme.of(context).textTheme.labelLarge,
        ),
        icon: AppIcon('sort', size: 18, color: fg),
        label: Text('Sort: $current', overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

/// A bottom sheet with one radio per [options] (a single choice). Returns the
/// picked value, or null when closed without picking.
Future<T?> showSortSheet<T>(
  BuildContext context, {
  required List<SortOption<T>> options,
  required T selected,
  String title = 'Sort by',
}) {
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
      final t = Theme.of(context).textTheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Space.md, 0, Space.md, Space.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: t.titleLarge),
              Gaps.v12,
              RadioGroup<T>(
                groupValue: selected,
                onChanged: (v) => Navigator.of(context).pop(v),
                child: Column(
                  children: [
                    for (final o in options)
                      RadioListTile<T>(
                        key: ValueKey('sort-${o.value}'),
                        value: o.value,
                        title: Text(o.label),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: Space.xs,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
