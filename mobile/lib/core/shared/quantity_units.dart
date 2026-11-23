import 'package:flutter/material.dart';

// ---------------------------------------------------------------------------
// Testing fix 4.1: one unit list for "how much", used by the donation form
// and the report needs list. A sack is packaging (its own field on the
// donation form), so it is not a quantity unit.
// Same list as QUANTITY_UNITS in backend/app/schemas/physical_donation_schema.py.
// ---------------------------------------------------------------------------
// Per-item fulfillment: these are base units. Weight is always kg and
// volume always L (grams, ml and gallons are entered as the size of each,
// e.g. 500 ml bottles), so the same goods are never counted in two units.
const quantityUnits = [
  'kg',
  'L',
  'pcs',
  'packs',
  'cans',
  'bottles',
  'boxes',
  'kits',
  'sets',
  'pairs',
];

const _aliases = {
  'kilo': 'kg',
  'kilos': 'kg',
  'kgs': 'kg',
  'kilogram': 'kg',
  'kilograms': 'kg',
  'liter': 'L',
  'liters': 'L',
  'litre': 'L',
  'litres': 'L',
  'pc': 'pcs',
  'piece': 'pcs',
  'pieces': 'pcs',
  'pack': 'packs',
  'can': 'cans',
  'bottle': 'bottles',
  'box': 'boxes',
  'kit': 'kits',
  'set': 'sets',
  'pair': 'pairs',
};

/// True for words that describe packaging, not an amount.
bool isPackagingUnit(String? unit) =>
    const {'sack', 'sacks'}.contains((unit ?? '').trim().toLowerCase());

/// "KG" / "kilos" -> "kg". Null when it is not a unit from the list
/// (including "sack"), so the person has to choose one.
String? normalizeUnit(String? unit) {
  final u = (unit ?? '').trim();
  if (u.isEmpty) return null;
  for (final x in quantityUnits) {
    if (x.toLowerCase() == u.toLowerCase()) return x;
  }
  return _aliases[u.toLowerCase()];
}

/// Unit dropdown for an item that is not in the list ("Something else" /
/// "Other"). Keeps [controller] in sync, so code that reads
/// `controller.text` keeps working.
class QuantityUnitField extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback? onChanged;
  const QuantityUnitField({
    super.key,
    required this.controller,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final current = normalizeUnit(controller.text);
    return DropdownButtonFormField<String>(
      // A new key when the value is set from outside (SMS fill, draft,
      // edit), so the dropdown shows it.
      key: ValueKey('unit-${identityHashCode(controller)}-$current'),
      initialValue: current,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Unit'),
      items: [
        for (final u in quantityUnits)
          DropdownMenuItem(value: u, child: Text(u)),
      ],
      onChanged: (v) {
        controller.text = v ?? '';
        onChanged?.call();
      },
      validator: (v) {
        if (v != null) return null;
        return isPackagingUnit(controller.text)
            ? 'Sack is packaging. Choose kg, pcs…'
            : 'Choose a unit';
      },
    );
  }
}
