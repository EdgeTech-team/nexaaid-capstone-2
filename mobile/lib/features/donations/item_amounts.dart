// G-002 (D8, agreement A7): every user who can see a donated item sees its
// packaging and its readable amount ("10 packs x 5 kg"), plus the
// quantities that exist: declared by the donor, counted by CSWS, and
// received by the barangay. The server sends amount_text, packaging,
// declared_quantity, counted_quantity and barangay_received_quantity
// (services/donations/item_quantities.py); older answers only quantity and unit.

/// "10 packs x 5 kg", or "50 kg" when the server sent no breakdown.
/// Nov 22: a kit with contents adds them, "2 kits · Includes: Spoon, Fork",
/// so CSWS and the barangay see what came in (a note only).
String itemAmount(Map i) {
  final text = '${i['amount_text'] ?? ''}'.trim();
  final amount = text.isNotEmpty
      ? text
      : '${i['quantity'] ?? ''} ${i['unit'] ?? ''}'.trim();
  final inside = itemContents(i);
  return inside == null ? amount : '$amount · Includes: $inside';
}

/// What is inside a kit, as the donor wrote it, or null.
String? itemContents(Map i) {
  final text = '${i['contents'] ?? ''}'.trim();
  return i['contents'] == null || text.isEmpty ? null : text;
}

String _n(Object? v) {
  final d = v is num ? v.toDouble() : double.tryParse('$v');
  if (d == null) return '$v';
  return d == d.roundToDouble() ? '${d.round()}' : '$d';
}

/// "Sack · Declared 50 kg · Counted 48 kg · Received by barangay 48 kg".
/// Only the quantities that exist; packaging first when there is one.
String itemQuantities(Map i, {bool packaging = true}) {
  final unit = '${i['unit'] ?? ''}'.trim();
  String q(Object? v) => '${_n(v)} $unit'.trim();
  final declared = i['declared_quantity'] ?? i['quantity'];
  final counted = i['counted_quantity'] ?? i['actual_quantity_received'];
  final received = i['barangay_received_quantity'];
  final pack = '${i['packaging'] ?? ''}'.trim();
  return [
    if (packaging && pack.isNotEmpty) pack,
    if (declared != null) 'Declared ${q(declared)}',
    if (counted != null) 'Counted ${q(counted)}',
    if (received != null) 'Received by barangay ${q(received)}',
  ].join(' · ');
}

/// A delivery line (goods from CSWS stock): "30 kg Rice", plus what the
/// barangay counted at receipt once there is one (J1).
String deliveredLine(Map i, {String? name}) {
  final unit = '${i['unit'] ?? ''}'.trim();
  final what = '${i['quantity'] ?? ''} $unit ${name ?? i['item_name'] ?? ''}'
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  final got = i['barangay_received_quantity'];
  return got == null
      ? what
      : '$what · received by barangay ${_n(got)} $unit'.trim();
}
