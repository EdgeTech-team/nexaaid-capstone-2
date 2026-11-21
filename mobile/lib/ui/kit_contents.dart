import 'package:flutter/material.dart';

import 'widgets.dart';

// ---------------------------------------------------------------------------
// Nov 22, 2026: what is inside a kit or set. A donor giving a Kitchen Set
// can say "Spoon, Fork, Plate"; a Hygiene Kit "Bath soap, Toothbrush".
//
// A NOTE ONLY. The item stays the kit (Kitchen Set, Hygiene Kit...), so the
// report's needs, fulfillment, inventory and the suggested needs never read
// it. It is saved on the donation line (physical_donations.contents) and
// shown to CSWS and the barangay with the item, so they know what came in.
// ---------------------------------------------------------------------------

/// Common contents per kit, by item name (lower case). Items not listed
/// here have no contents picker.
const kitContentOptions = <String, List<String>>{
  'kitchen set': [
    'Spoon',
    'Fork',
    'Plate',
    'Bowl',
    'Cup',
    'Cooking pot',
    'Frying pan',
    'Ladle',
    'Knife',
  ],
  'hygiene kit': [
    'Bath soap',
    'Laundry soap',
    'Shampoo',
    'Toothbrush',
    'Toothpaste',
    'Sanitary pads',
    'Towel',
    'Comb',
    'Alcohol',
  ],
  // Nov 22: one Clothing item (no Upper / Lower items); which pieces is a
  // note here.
  'clothing': [
    'T-shirt',
    'Blouse',
    'Pants',
    'Shorts',
    'Skirt',
    'Dress',
    'Underwear',
    'Jacket',
    'Baby clothes',
    'Socks',
  ],
  'medicine kit': [
    'Paracetamol',
    'Oral rehydration salts',
    'Vitamins',
    'Antiseptic',
    'Bandages',
    'Cotton',
    'Face masks',
  ],
};

/// The contents choices for an item, or null when it is not a kit.
List<String>? kitContentsFor(String? itemName) {
  final key = (itemName ?? '')
      .replaceAll(RegExp(r'\s*\(.*\)$'), '')
      .trim()
      .toLowerCase();
  return kitContentOptions[key];
}

/// "Spoon, Fork" -> the chosen options and the rest as typed text.
(Set<String>, String) splitKitContents(String? text, List<String> options) {
  final chosen = <String>{};
  final other = <String>[];
  for (final part in (text ?? '').split(',')) {
    final p = part.trim();
    if (p.isEmpty) continue;
    final match = options
        .where((o) => o.toLowerCase() == p.toLowerCase())
        .firstOrNull;
    if (match != null) {
      chosen.add(match);
    } else {
      other.add(p);
    }
  }
  return (chosen, other.join(', '));
}

/// The chosen options (in list order) and the typed extras as one line,
/// e.g. "Spoon, Fork, Plastic tumbler". Null when nothing was given.
String? joinKitContents(
  Set<String> chosen,
  String other,
  List<String> options,
) {
  final parts = [
    for (final o in options)
      if (chosen.contains(o)) o,
    for (final p in other.split(','))
      if (p.trim().isNotEmpty) p.trim(),
  ];
  final text = parts.join(', ');
  if (text.isEmpty) return null;
  return text.length > 300 ? text.substring(0, 300) : text;
}

/// "What's inside? (optional)" under a kit on the donation form: chips for
/// the usual contents and a box for anything else.
class KitContentsPicker extends StatelessWidget {
  final List<String> options;
  final Set<String> chosen;
  final TextEditingController other;
  final VoidCallback onChanged;
  const KitContentsPicker({
    super.key,
    required this.options,
    required this.chosen,
    required this.other,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text("What's included? (optional)", style: t.titleSmall),
        Gaps.v4,
        Text(
          'Tell CSWS and the barangay what is included. It is a note '
          'only: the donation still counts as this item.',
          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        Gaps.v8,
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final o in options)
              FilterChip(
                key: ValueKey('kit-$o'),
                label: Text(o),
                selected: chosen.contains(o),
                onSelected: (on) {
                  on ? chosen.add(o) : chosen.remove(o);
                  onChanged();
                },
              ),
          ],
        ),
        Gaps.v8,
        TextFormField(
          key: const ValueKey('kit-other'),
          controller: other,
          maxLength: 150,
          onChanged: (_) => onChanged(),
          decoration: const InputDecoration(
            labelText: 'Something else (optional)',
            hintText: 'e.g. Plastic tumbler, Rice scoop',
            counterText: '',
          ),
        ),
      ],
    );
  }
}
