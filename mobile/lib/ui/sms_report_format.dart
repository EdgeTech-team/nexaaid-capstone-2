/// Concerns2.txt (Module 2, SMS reporting): ONE shared SMS format.
///
/// - Barangay Representative (offline): fills a small form, the app builds
///   the text with [SmsReport.toMessage] and opens the phone's SMS app.
/// - CSWS Disaster Unit: pastes the received text, [SmsReport.parse] reads
///   it back and fills the "Encode SMS Report" form (UC-CD1 alt flow 11b:
///   structured SMS report).
///
/// Both sides use this file, so the format can never drift apart.
/// Keypad phones can type the same format by hand:
///
///   NEXAAID REPORT
///   TYPE: Flood
///   BRGY: Banilad
///   SITIO: Whole barangay
///   FAMILIES: 150
///   NEEDS: Rice 50 kg; Drinking Water 20 gallons
///   DETAILS: Waist-deep flood near the chapel
///
/// The reader is forgiving: keys can be in any order and any case, and
/// common alternatives work (BARANGAY for BRGY, DESCRIPTION for DETAILS...).
library;

const smsReportHeader = 'NEXAAID REPORT';
const smsWholeBarangay = 'Whole barangay';

/// One line of NEEDS: "Rice 50 kg" -> item Rice, quantity 50, unit kg.
class SmsNeed {
  final String item;
  final int quantity;
  final String unit;
  const SmsNeed(this.item, this.quantity, [this.unit = '']);

  @override
  String toString() =>
      unit.isEmpty ? '$item $quantity' : '$item $quantity $unit';
}

class SmsReport {
  final String? disasterType;
  final String? barangay;

  /// null means the whole barangay.
  final String? sitio;
  final int? families;
  final List<SmsNeed> needs;
  final String? details;

  /// Parts of a pasted text that could not be read (shown to the
  /// Disaster Unit so they can fix them by hand).
  final List<String> problems;

  const SmsReport({
    this.disasterType,
    this.barangay,
    this.sitio,
    this.families,
    this.needs = const [],
    this.details,
    this.problems = const [],
  });

  /// The text the Barangay Representative sends.
  String toMessage() {
    String clean(String? s) => (s ?? '').replaceAll('\n', ' ').trim();
    return [
      smsReportHeader,
      'TYPE: ${clean(disasterType)}',
      'BRGY: ${clean(barangay)}',
      'SITIO: ${sitio == null || sitio!.trim().isEmpty ? smsWholeBarangay : clean(sitio)}',
      'FAMILIES: ${families ?? ''}',
      'NEEDS: ${needs.map((n) => n.toString()).join('; ')}',
      if (clean(details).isNotEmpty) 'DETAILS: ${clean(details)}',
    ].join('\n');
  }

  /// Required fields that are still empty, in plain words.
  List<String> get missing => [
    if ((disasterType ?? '').trim().isEmpty) 'disaster type',
    if ((barangay ?? '').trim().isEmpty) 'barangay',
    if (families == null || families! <= 0) 'number of families',
    if (needs.isEmpty) 'what they need',
  ];

  static const _keys = <String, String>{
    'TYPE': 'type',
    'DISASTER': 'type',
    'DISASTER TYPE': 'type',
    'BRGY': 'brgy',
    'BARANGAY': 'brgy',
    'SITIO': 'sitio',
    'FAMILIES': 'families',
    'FAMILY': 'families',
    'AFFECTED FAMILIES': 'families',
    'NEEDS': 'needs',
    'NEED': 'needs',
    'DETAILS': 'details',
    'DETAIL': 'details',
    'DESCRIPTION': 'details',
  };

  static final _line = RegExp(r'^\s*([A-Za-z ]+?)\s*:\s*(.*)$');
  static final _need = RegExp(r'^(.+?)\s+(\d+)\s*(.*)$');

  /// Reads a pasted SMS. Returns null when no NexaAid field is found
  /// (then the Disaster Unit encodes it by hand, as before).
  static SmsReport? parse(String text) {
    final values = <String, String>{};
    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final m = _line.firstMatch(raw);
      if (m == null) continue;
      final key = _keys[m.group(1)!.trim().toUpperCase()];
      if (key != null) values[key] = m.group(2)!.trim();
    }
    if (values.isEmpty) return null;

    final problems = <String>[];

    int? families;
    final f = values['families'];
    if (f != null && f.isNotEmpty) {
      families = int.tryParse(f.replaceAll(RegExp(r'[^0-9]'), ''));
      if (families == null || families <= 0) {
        problems.add('FAMILIES is not a number: "$f"');
        families = null;
      }
    }

    final needs = <SmsNeed>[];
    for (final part in (values['needs'] ?? '').split(RegExp(r'[;\n]'))) {
      final p = part.trim();
      if (p.isEmpty) continue;
      final m = _need.firstMatch(p);
      final qty = m == null ? null : int.tryParse(m.group(2)!);
      if (m == null || qty == null || qty <= 0) {
        problems.add('Need has no quantity: "$p"');
        continue;
      }
      needs.add(SmsNeed(m.group(1)!.trim(), qty, m.group(3)!.trim()));
    }

    final s = values['sitio']?.trim() ?? '';
    final whole =
        s.isEmpty ||
        const [
          'whole barangay',
          'whole',
          'all',
          'none',
          '-',
        ].contains(s.toLowerCase());

    String? orNull(String? v) =>
        (v == null || v.trim().isEmpty) ? null : v.trim();

    return SmsReport(
      disasterType: orNull(values['type']),
      barangay: orNull(values['brgy']),
      sitio: whole ? null : s,
      families: families,
      needs: needs,
      details: orNull(values['details']),
      problems: problems,
    );
  }
}

/// Finds the lookup row whose name matches [name] (ignoring case and extra
/// spaces). Used to turn "Banilad" from an SMS into the barangay's id.
/// Returns the row's id as a string, or null when nothing matches.
String? matchLookupId(List<Map> rows, String? name, {String key = 'name'}) {
  final want = (name ?? '').trim().toLowerCase().replaceAll(
    RegExp(r'\s+'),
    ' ',
  );
  if (want.isEmpty) return null;
  for (final r in rows) {
    final n = '${r[key] ?? r['name'] ?? ''}'.trim().toLowerCase().replaceAll(
      RegExp(r'\s+'),
      ' ',
    );
    if (n == want) return '${r['id']}';
  }
  return null;
}
