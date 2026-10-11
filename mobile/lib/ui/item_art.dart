import 'package:flutter/material.dart';

import '../design/design.dart';

// ---------------------------------------------------------------------------
// Ivan (dashboard canvas): a small picture for each donated item, so a
// donation card shows "a sack of rice" or "a hygiene kit" at a glance.
// Chosen from the item's name (items have no photos); drawn with Material
// icons on a soft tint, so it works in light and dark mode.
// ---------------------------------------------------------------------------

/// Icon and tint for an item name such as "Rice", "Bottled water".
(IconData, Color) itemLook(Object? itemName) {
  final n = '${itemName ?? ''}'.toLowerCase();
  bool has(List<String> words) => words.any(n.contains);
  if (has(['rice', 'grain', 'noodle', 'pasta', 'bread', 'flour'])) {
    return (Icons.rice_bowl_outlined, const Color(0xFFB7791F));
  }
  if (has(['water', 'juice', 'drink', 'milk'])) {
    return (Icons.water_drop_outlined, const Color(0xFF1F5FA8));
  }
  if (has(['can', 'sardine', 'tuna', 'corned', 'food', 'meal', 'biscuit'])) {
    return (Icons.lunch_dining_outlined, const Color(0xFFD9480F));
  }
  if (has(['hygiene', 'soap', 'shampoo', 'tooth', 'sanitary', 'alcohol'])) {
    return (Icons.soap_outlined, const Color(0xFF0B6E69));
  }
  if (has(['medic', 'first aid', 'vitamin', 'mask'])) {
    return (Icons.medication_outlined, const Color(0xFFC0362C));
  }
  if (has(['cloth', 'shirt', 'pants', 'dress', 'shoe', 'slipper'])) {
    return (Icons.checkroom_outlined, const Color(0xFF7A4FA8));
  }
  if (has(['blanket', 'mat', 'pillow', 'tent', 'tarp', 'sleep'])) {
    return (Icons.bed_outlined, const Color(0xFF5B6B7A));
  }
  if (has(['diaper', 'baby', 'infant'])) {
    return (Icons.child_friendly_outlined, const Color(0xFFB0457A));
  }
  return (Icons.inventory_2_outlined, const Color(0xFF4A615E));
}

/// The picture for a donation entry: its first item's look.
class ItemArt extends StatelessWidget {
  final Object? itemName;
  final double size;
  const ItemArt(this.itemName, {super.key, this.size = 52});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = itemLook(itemName);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color.withValues(alpha: dark ? 0.28 : 0.14),
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Icon(
          icon,
          size: size * 0.52,
          color: dark ? Color.lerp(color, Colors.white, 0.45) : color,
        ),
      ),
    );
  }
}

/// "120 kg Rice, 60 jugs Water +2 more" for a donation entry's items.
String itemsSummary(Map entry, {int show = 2}) {
  final items = (entry['items'] as List? ?? const []).cast<Map>();
  String one(Map i) {
    final q = i['quantity'];
    final unit = '${i['unit'] ?? ''}'.trim();
    return [
      if (q != null) '$q',
      if (unit.isNotEmpty) unit,
      '${i['item_name'] ?? 'Item'}',
    ].join(' ');
  }

  final shown = items.take(show).map(one).join(', ');
  final more = items.length - show;
  return more > 0 ? '$shown +$more more' : shown;
}
