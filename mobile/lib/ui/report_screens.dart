import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'kept_views.dart';
import '../app_routes.dart';
import '../api.dart';
import 'donation_info.dart' show NewReportDonationInfo;
import 'form_draft.dart';
import 'input_formatters.dart';
import 'paged_reports.dart';
import 'report_filters.dart';
import 'report_summary_card.dart';
import 'sitio_picker.dart';
import 'quantity_units.dart';
import 'sms_report_format.dart';
import 'widgets.dart';
import 'home_nav.dart';
import 'hazard_barangay_field.dart';
import 'multi_report.dart';
import 'sms_original.dart';

// ---------------------------------------------------------------------------
// Concerns2.txt 2.1: number limits. Must match the backend
// (app/schemas/report.py: MAX_AFFECTED_FAMILIES, MAX_ESTIMATED_QUANTITY).
// ---------------------------------------------------------------------------
const maxAffectedFamilies = 20000;
// Testing (Oct 28): no limit on how much a report needs, per item or in
// total; only what the database can store (9 digits per need).
const maxEstimatedQuantity = 999999999;
const _maxTotalQuantity = 2147483647;

/// Whole numbers only. A typed or pasted dot, letter or minus sign is
/// refused (the field keeps what it had). digitsOnly used to strip them, so
/// a pasted "2.5" quietly became 25.
final _digitsOrNothing = TextInputFormatter.withFunction(
  (old, value) => RegExp(r'^\d*$').hasMatch(value.text) ? value : old,
);

/// Affected families: up to 6 digits.
final _wholeNumberInput = <TextInputFormatter>[
  _digitsOrNothing,
  LengthLimitingTextInputFormatter(6),
];

/// How many of one need: up to 9 digits (see [maxEstimatedQuantity]).
final _quantityInput = <TextInputFormatter>[
  _digitsOrNothing,
  LengthLimitingTextInputFormatter(9),
];

/// 20000 -> "20,000"
String _withCommas(int n) =>
    n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');

/// Validator: a whole number from 1 to [max]. 0, 0.0 and 2.5 are refused.
String? Function(String?) _wholeNumber(int max) => (v) {
  final text = v?.trim() ?? '';
  if (text.contains('.') || text.contains(',')) {
    return 'Whole numbers only (no decimals)';
  }
  final n = int.tryParse(text);
  if (n == null || n <= 0) return 'Enter a whole number above 0';
  if (n > max) return 'Maximum is ${_withCommas(max)}';
  return null;
};

/// Card for one disaster report (with fulfillment if available). Resolves
/// the names and the role rule, then draws the shared [ReportSummaryCard]
/// (the landing page uses the same card).
class ReportCard extends StatelessWidget {
  final Map<String, dynamic> r;
  final Names names;
  final List<Widget> actions;

  /// Outlined: the report a notification pointed at.
  final bool highlighted;
  const ReportCard(
    this.r,
    this.names, {
    super.key,
    this.actions = const [],
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final hasFulfillment = r['total_items_needed'] != null;
    // Appendix H 3.2: every role except DRRMO views priority guidance.
    final showPriority = api.role != Roles.drrmo;
    final guidance = r['priority_guidance'] ?? r['ai_recommendation'];
    return ReportSummaryCard(
      reportId: (r['report_id'] as num?)?.toInt(),
      disaster: disasterLabel(r, names),
      barangay: names.of('barangays', r['barangay_id']),
      status: r['status'] as String?,
      priority: r['priority_level'] as String?,
      eventName: r['event_name'] as String?,
      affectedFamilies: (r['affected_families'] as num?)?.toInt(),
      assistanceNeeded: r['assistance_needed']?.toString(),
      description: r['description']?.toString(),
      guidance: guidance?.toString(),
      rejectionReason: r['rejection_reason']?.toString(),
      delivered: hasFulfillment
          ? r['total_items_delivered'] as num? ?? 0
          : null,
      needed: hasFulfillment ? r['total_items_needed'] as num? ?? 0 : null,
      percent: hasFulfillment
          ? num.tryParse('${r['fulfillment_percentage']}')
          : null,
      showPriority: showPriority,
      highlighted: highlighted,
      actions: actions,
    );
  }
}

// ---------------------------------------------------------------------------
// UC-CD1 Submit post-disaster report (CSWS Disaster Unit), and
// Encode SMS report (Administrator, smsEncode: true).
// Scope 2.4, UC-A3 alt 8a, UC-CD1 alt 11b (Oct 15 team, back to the
// manuscript; claude/sms-reporting-decision.md): the Disaster Unit SENDS a
// structured SMS when offline (sms_send_screen.dart); the Administrator
// reviews and ENCODES it here, then validates it on the Validate tab.
// ---------------------------------------------------------------------------
class NewReportScreen extends StatefulWidget {
  /// true = Administrator encoding an SMS report the Disaster Unit sent.
  final bool smsEncode;

  /// Oct 11 (Daniel): the reporter corrects their own report before the
  /// Administrator validates it. The form opens filled in.
  final Map<String, dynamic>? edit;
  const NewReportScreen({super.key, this.smsEncode = false, this.edit});

  @override
  State<NewReportScreen> createState() => _NewReportScreenState();
}

/// One line of the needs list: an item (or "Other"), how many, and the unit.
class _Need {
  String? itemId; // items.item_id, or _other

  /// UAT Nov 10: the amount was filled in by the app (not typed), so it
  /// follows the families and the disaster type. Typing turns it off.
  bool auto = false;
  final qty = TextEditingController();
  final otherName = TextEditingController();
  final otherUnit = TextEditingController();
}

const _other = 'other';

class _NewReportScreenState extends State<NewReportScreen> {
  final _form = GlobalKey<FormState>();
  String? typeId, brgyId;

  /// problema_napud 2.2: one row per sitio hit, '' = not chosen yet. A
  /// single empty row means the whole barangay.
  List<String> sitioRows = [''];
  List<int> get _sitioIds => [
    for (final v in sitioRows.toSet())
      if (v.isNotEmpty) int.parse(v),
  ];

  /// What kind of disaster, when the type is Other (e.g. "Gas leak").
  final typeOther = TextEditingController();
  final desc = TextEditingController();
  final families = TextEditingController();
  final smsSender = TextEditingController();
  final smsText = TextEditingController();
  final needs = <_Need>[_Need()];
  bool busy = false;

  /// NF-003: "Several barangays" (one report per barangay, one event).
  /// Only for a new report typed in the app, not SMS or a correction.
  bool multi = false;
  final BarangayRows multiRows = {};

  /// Nov 22: each barangay has its own needs list (whole quantities), as if
  /// it were reported on its own. Barangay id -> its needs.
  final multiNeeds = <String, List<_Need>>{};

  List<_Need> _needsOf(String id) =>
      multiNeeds.putIfAbsent(id, () => [_Need()]);

  int _familiesOf(String id) =>
      int.tryParse(multiRows[id]?.text.trim() ?? '') ?? 0;
  final eventName = TextEditingController();
  bool get _canMulti => !editing && !sms;

  /// true when encoding a report that arrived by SMS (UC-A3 8a).
  late final bool sms = widget.smsEncode;
  bool get editing => widget.edit != null;
  bool _filledFromEdit = false;

  // Testing fix (UI): what was typed survives a refresh or a closed app.
  // Not used when correcting an existing report.
  late final FormDraft? _draft = editing
      ? null
      : FormDraft(sms ? 'report-sms' : 'report');

  @override
  void initState() {
    super.initState();
    _draft?.load().then((d) async {
      if (d == null || !mounted) return;
      // The lists are needed to check the saved ids (cached after the
      // first load, so this is quick).
      final names = Names(await api.lookups());
      if (!mounted) return;
      setState(() => _applyDraft(d, names));
    });
  }

  @override
  void dispose() {
    _draft?.flush(_snapshot);
    super.dispose();
  }

  Map<String, dynamic> _snapshot() => {
    'type_id': typeId,
    'type_other': typeOther.text,
    'barangay_id': brgyId,
    'sitio_rows': sitioRows,
    'description': desc.text,
    'families': families.text,
    'sms_sender': smsSender.text,
    'sms_text': smsText.text,
    'multi': multi,
    'multi_rows': {for (final e in multiRows.entries) e.key: e.value.text},
    'event_name': eventName.text,
    'needs': [for (final n in needs) _needMap(n)],
    'multi_needs': {
      for (final e in multiNeeds.entries)
        e.key: [for (final n in e.value) _needMap(n)],
    },
  };

  static Map<String, dynamic> _needMap(_Need n) => {
    'item_id': n.itemId,
    'qty': n.qty.text,
    'auto': n.auto,
    'other_name': n.otherName.text,
    'other_unit': n.otherUnit.text,
  };

  void _saveDraft() => _draft?.save(_snapshot);

  /// Fills the form from the saved draft. Ids that no longer exist in the
  /// lists are skipped, so every dropdown gets a valid value.
  void _applyDraft(Map<String, dynamic> d, Names names) {
    bool known(String list, String? id) =>
        id != null && names.rows(list).any((r) => '${r['id']}' == id);
    final t = d.strOrNull('type_id');
    final b = d.strOrNull('barangay_id');
    typeId = known('disaster_types', t) ? t : null;
    brgyId = known('barangays', b) ? b : null;
    final rows = <String>[
      for (final v
          in (d['sitio_rows'] is List ? d['sitio_rows'] as List : const []))
        if (v is String &&
            (v.isEmpty ||
                names
                    .rows('sitios')
                    .any(
                      (st) =>
                          '${st['id']}' == v &&
                          '${st['barangay_id']}' == brgyId,
                    )))
          v,
    ];
    sitioRows = brgyId == null || rows.isEmpty ? [''] : rows;
    typeOther.text = d.str('type_other');
    desc.text = d.str('description');
    families.text = d.str('families');
    smsSender.text = d.str('sms_sender');
    smsText.text = d.str('sms_text');
    multi = _canMulti && d['multi'] == true;
    multiRows.clear();
    if (d['multi_rows'] is Map) {
      for (final e in (d['multi_rows'] as Map).entries) {
        if (known('barangays', '${e.key}')) {
          multiRows['${e.key}'] = TextEditingController(text: '${e.value}');
        }
      }
    }
    eventName.text = d.str('event_name');
    _smsLen = smsText.text.length; // a restored SMS is not a new paste
    _Need fromMap(Map<String, dynamic> m) {
      final id = m.strOrNull('item_id');
      return _Need()
        ..itemId = id == _other || known('items', id) ? id : null
        ..qty.text = m.str('qty')
        ..auto = m['auto'] == true
        ..otherName.text = m.str('other_name')
        ..otherUnit.text = m.str('other_unit');
    }

    final restored = [for (final m in d.maps('needs')) fromMap(m)];
    if (restored.isNotEmpty) {
      needs
        ..clear()
        ..addAll(restored);
    }
    multiNeeds.clear();
    if (d['multi_needs'] is Map) {
      for (final e in (d['multi_needs'] as Map).entries) {
        if (!multiRows.containsKey('${e.key}') || e.value is! List) continue;
        final list = [
          for (final m in e.value as List)
            if (m is Map) fromMap(Map<String, dynamic>.from(m)),
        ];
        if (list.isNotEmpty) multiNeeds['${e.key}'] = list;
      }
    }
    _fills++; // the dropdowns rebuild with these values
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      AppToast.info(
        context,
        'We kept what you typed last time.',
        action: ToastAction('Start over', _startOver),
      );
    });
  }

  /// "Start over": an empty form and no draft.
  void _startOver() {
    _draft?.clear();
    setState(() {
      typeOther.clear();
      desc.clear();
      families.clear();
      smsSender.clear();
      smsText.clear();
      _smsLen = 0;
      needs
        ..clear()
        ..add(_Need());
      typeId = brgyId = null;
      sitioRows = [''];
      _fillNotes = const [];
      multiRows.clear();
      multiNeeds.clear();
      _suggestedForAll = false;
      eventName.clear();
      _fills++;
    });
  }

  /// Fill the form from the report being corrected. Per-item fulfillment
  /// (Oct 2026): the needs come back as rows (`needs`). Older reports only
  /// have one "General needs" row, so their text "Rice: 50 kg, Drinking
  /// Water: 20 L" is read instead.
  void _fillFromReport(Map<String, dynamic> r, Names names) {
    typeId = '${r['disaster_type_id']}';
    typeOther.text = '${r['disaster_type_other'] ?? ''}';
    brgyId = '${r['barangay_id']}';
    final ids =
        (r['sitio_ids'] as List?) ?? [if (r['sitio_id'] != null) r['sitio_id']];
    sitioRows = ids.isEmpty ? [''] : [for (final i in ids) '$i'];
    desc.text = '${r['description'] ?? ''}';
    families.text = '${r['affected_families'] ?? ''}';
    final rows = [
      for (final n in (r['needs'] as List? ?? const []))
        if (n is Map && n['item_id'] != null) n,
    ];
    if (rows.isNotEmpty) {
      final offered = {for (final i in names.rows('items')) '${i['id']}'};
      needs
        ..clear()
        ..addAll([
          for (final n in rows)
            _Need()
              ..qty.text = '${n['quantity']}'
              // A retired item (e.g. the old gallons water) is no longer
              // in the list: the reporter picks the current one again.
              ..itemId = offered.contains('${n['item_id']}')
                  ? '${n['item_id']}'
                  : null,
        ]);
      _fills++;
      return;
    }
    final parsed = <_Need>[];
    for (final part in '${r['assistance_needed'] ?? ''}'.split(',')) {
      final m = RegExp(r'^\s*(.+?):\s*(\d+)\s*(.*)$').firstMatch(part);
      if (m == null) continue;
      final need = _Need()..qty.text = m.group(2)!;
      final id = _idByName(names, 'items', m.group(1));
      if (id != null) {
        need.itemId = id;
      } else {
        need
          ..itemId = _other
          ..otherName.text = m.group(1)!.trim()
          ..otherUnit.text = m.group(3)!.trim();
      }
      parsed.add(need);
    }
    if (parsed.isNotEmpty) {
      needs
        ..clear()
        ..addAll(parsed);
    }
    _fills++;
  }

  /// Module 3 (Oct 2026): suggested needs for a disaster type, from
  /// /lookups `need_templates` (backend services/need_templates.py).
  Map<String, dynamic>? _templateFor(Names names) {
    for (final t in names.rows('need_templates')) {
      if ('${t['id']}' == typeId) return t;
    }
    return null;
  }

  /// Nothing typed or chosen in [list] yet.
  static bool _blank(List<_Need> list) => list.every(
    (n) =>
        n.itemId == null &&
        n.qty.text.trim().isEmpty &&
        n.otherName.text.trim().isEmpty,
  );

  /// Nothing typed or chosen in the needs of the current mode yet.
  bool get _needsBlank =>
      multi ? multiNeeds.values.every(_blank) : _blank(needs);

  /// "Use suggested needs" replaces the list (in "Several barangays", every
  /// barangay's list); lists with something in them are replaced only
  /// after the reporter agrees.
  Future<void> _useSuggested(Names names) async {
    if (!_needsBlank) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace the current needs?'),
          content: const Text(
            'The items you entered will be replaced with the suggested '
            'needs. You can still edit or remove each one afterwards.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep my items'),
            ),
            FilledButton(
              key: const ValueKey('suggested-replace'),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    setState(() => _applyTemplate(names));
    _saveDraft();
  }

  /// "Use suggested needs": fills the needs list with the template of the
  /// chosen disaster type, each amount per family x affected families,
  /// rounded up. Without a family count the amounts are left to type.
  /// Optional: nothing is filled until the reporter taps the button.
  void _applyTemplate(Names names) {
    final t = _templateFor(names);
    if (t == null) return;
    if (multi) {
      // Each barangay its own list, sized to its own families.
      _suggestedForAll = true;
      for (final id in multiRows.keys) {
        multiNeeds[id] = _templateLines(t);
      }
    } else {
      needs
        ..clear()
        ..addAll(_templateLines(t));
    }
    _refillAuto(names);
  }

  /// The template's items as suggested lines (amounts filled by _autoFill).
  static List<_Need> _templateLines(Map<String, dynamic> t) => [
    for (final line in (t['items'] as List).cast<Map>())
      _Need()
        ..itemId = '${line['item_id']}'
        ..auto = true,
  ];

  /// "Several barangays": "Use suggested needs" was tapped, so a barangay
  /// picked afterwards gets its own suggested list too (not an empty one).
  bool _suggestedForAll = false;

  /// Barangays picked after "Use suggested needs" get the suggested list.
  void _suggestForNewBarangays(Names names) {
    final t = _templateFor(names);
    if (!_suggestedForAll || t == null) return;
    for (final id in multiRows.keys) {
      if (!multiNeeds.containsKey(id)) multiNeeds[id] = _templateLines(t);
    }
  }

  /// How much of an item one affected family gets, in hundredths (600 = 6,
  /// 10 = 0.1): the disaster type's preset amount, else the item's general
  /// amount (/lookups items.per_family), else 1 per family.
  int _perFamily(_Need n, Names names) {
    if (n.itemId == null || n.itemId == _other) return 100;
    final t = _templateFor(names);
    for (final line in (t?['items'] as List? ?? const []).cast<Map>()) {
      if ('${line['item_id']}' == n.itemId) {
        return hundredthsOf(line['per_family'] as num);
      }
    }
    for (final it in names.rows('items')) {
      if ('${it['id']}' == n.itemId && it['per_family'] is num) {
        return hundredthsOf(it['per_family'] as num);
      }
    }
    return 100;
  }

  /// The amount of a suggested need (added by "Use suggested needs"):
  /// ceil(the barangay's affected families x per family), a whole number.
  /// In "Several barangays" each barangay uses its own families.
  /// Nov 22: only suggested needs the reporter has not touched. A need the
  /// reporter added, typed in or cleared is never filled by the app, so an
  /// emptied field stays empty (it used to come back as 15).
  void _autoFill(_Need n, Names names, int fams) {
    if (n.itemId == null || !n.auto) return;
    final pf = _perFamily(n, names);
    n.qty.text = fams > 0
        ? '${barangayQuantity(fams, pf).clamp(1, maxEstimatedQuantity)}'
        : '';
  }

  /// Every amount the app filled follows the new families / type.
  void _refillAuto(Names names) {
    if (multi) {
      for (final e in multiNeeds.entries) {
        for (final n in e.value) {
          _autoFill(n, names, _familiesOf(e.key));
        }
      }
    } else {
      final fams = int.tryParse(families.text.trim()) ?? 0;
      for (final n in needs) {
        _autoFill(n, names, fams);
      }
    }
  }

  /// Bumped after "Fill from SMS" so the dropdowns rebuild with the new values.
  int _fills = 0;

  /// What could not be filled from the SMS, shown to the Administrator.
  List<String> _fillNotes = const [];

  /// Length of the SMS box the last time it changed, to tell a paste (many
  /// characters at once) from typing.
  int _smsLen = 0;

  /// Problema 2.2: pasting the received SMS fills the form by itself. The
  /// "Fill the form from this SMS" button stays for hand-typed or edited text.
  void _smsChanged(String value, Names names) {
    final grew = value.length - _smsLen;
    _smsLen = value.length;
    if (grew > 15 && value.toUpperCase().contains(smsReportHeader)) {
      _fillFromSms(names, quiet: true);
    }
  }

  /// "Rice (kg)" / " rice " -> "rice"
  static String _norm(String s) => s
      .replaceAll(RegExp(r'\s*\(.*\)$'), '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), ' ');

  /// Id of the lookup row whose display name matches [name], or null.
  String? _idByName(Names names, String list, String? name) {
    if (name == null) return null;
    final want = _norm(name);
    for (final r in names.rows(list)) {
      if (_norm(names.of(list, r['id'], fallback: '')) == want) {
        return '${r['id']}';
      }
    }
    return null;
  }

  _Need _needFrom(SmsNeed n, Names names) {
    final need = _Need()..qty.text = '${n.quantity}';
    final id = _idByName(names, 'items', n.item);
    if (id != null) {
      need.itemId = id;
    } else {
      need.itemId = _other;
      need.otherName.text = n.item;
      need.otherUnit.text = n.unit;
    }
    return need;
  }

  /// Reads the pasted SMS (sms_report_format.dart) and fills the form.
  /// Nothing is saved: the Administrator still checks every field and taps
  /// "Encode SMS report" (manual review, Scope 2.4).
  void _fillFromSms(Names names, {bool quiet = false}) {
    final parsed = SmsReport.parse(smsText.text);
    if (parsed == null) {
      if (quiet) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This text is not in the NexaAid SMS format. '
            'Fill in the form by hand.',
          ),
        ),
      );
      return;
    }
    final notes = <String>[
      if (parsed.missing.isNotEmpty)
        'The SMS is missing: ${parsed.missing.join(', ')}.',
      ...parsed.problems,
    ];
    // "TYPE: Other - Gas leak": Other, and the field under it says what.
    final otherKind = smsOtherKind(parsed.disasterType);
    final type = _idByName(
      names,
      'disaster_types',
      otherKind != null ? otherDisasterType : parsed.disasterType,
    );
    if (parsed.disasterType != null && type == null) {
      notes.add(
        'Disaster type "${parsed.disasterType}" not found. Choose it below.',
      );
    }
    final brgy = _idByName(names, 'barangays', parsed.barangay);
    if (parsed.barangay != null && brgy == null) {
      notes.add('Barangay "${parsed.barangay}" not found. Choose it below.');
    }
    final sitios = <String>[];
    if (brgy != null) {
      for (final name in parsed.sitios) {
        final want = _norm(name);
        final match = names
            .rows('sitios')
            .where(
              (st) =>
                  '${st['barangay_id']}' == brgy &&
                  _norm('${st['name']}') == want,
            )
            .firstOrNull;
        if (match == null) {
          notes.add(
            'Sitio "$name" not found in this barangay. Choose it below.',
          );
        } else {
          sitios.add('${match['id']}');
        }
      }
    }
    final newNeeds = [for (final n in parsed.needs) _needFrom(n, names)];
    setState(() {
      typeId = type;
      typeOther.text = otherKind ?? '';
      brgyId = brgy;
      sitioRows = sitios.isEmpty ? [''] : sitios;
      if (parsed.families != null) families.text = '${parsed.families}';
      if (parsed.details != null) desc.text = parsed.details!;
      if (newNeeds.isNotEmpty) {
        needs
          ..clear()
          ..addAll(newNeeds);
      }
      _fillNotes = notes;
      _fills++;
    });
  }

  bool _typeIsOther(Names names) =>
      typeId != null &&
      names.of('disaster_types', typeId, fallback: '') == otherDisasterType;

  String _needName(_Need n, Names names) => n.itemId == _other
      ? n.otherName.text.trim()
      : names
            .of('items', n.itemId, fallback: '')
            .replaceAll(RegExp(r'\s*\(.*\)$'), '');

  String _needUnit(_Need n, Names names) {
    if (n.itemId == _other) {
      return normalizeUnit(n.otherUnit.text) ?? n.otherUnit.text.trim();
    }
    for (final i in names.rows('items')) {
      if ('${i['id']}' == n.itemId) return '${i['unit'] ?? ''}';
    }
    return '';
  }

  /// Concerns2 follow-up: the same item can't be listed twice
  /// (it showed up as "Medicine Kit: 1 boxes, Medicine Kit: 2 boxes").
  /// Returns the earlier need number that already has this item, or null.
  int? _duplicateOf(List<_Need> list, int i) {
    final n = list[i];
    for (var j = 0; j < i; j++) {
      final o = list[j];
      if (n.itemId == null || o.itemId != n.itemId) continue;
      if (n.itemId != _other) return j + 1;
      final a = n.otherName.text.trim().toLowerCase();
      if (a.isNotEmpty && a == o.otherName.text.trim().toLowerCase()) {
        return j + 1;
      }
    }
    return null;
  }

  /// Barangays of "Several barangays" with families typed (above 0).
  List<MapEntry<String, int>> get _multiFamilies => [
    for (final e in multiRows.entries)
      if ((int.tryParse(e.value.text.trim()) ?? 0) > 0)
        MapEntry(e.key, int.parse(e.value.text.trim())),
  ];

  int get _multiCount => _multiFamilies.length;

  /// Switches between one and several barangays. Nov 22: amounts are
  /// whole quantities in both modes (each barangay has its own list), so
  /// nothing typed changes meaning or is cleared.
  void _setMulti(bool value, Names names) {
    if (value == multi) return;
    setState(() {
      multi = value;
      _refillAuto(names);
    });
    _saveDraft();
  }

  /// "Several barangays": one barangay's items as a short line under its
  /// families, e.g. "Rice 720 kg · Drinking Water 2,400 L".
  String? _barangayPreview(String id, Names names) {
    final parts = [
      for (final n in multiNeeds[id] ?? const <_Need>[])
        if (n.itemId != null && int.tryParse(n.qty.text.trim()) != null)
          '${_needName(n, names)} '
                  '${withCommas(int.parse(n.qty.text.trim()))} '
                  '${_needUnit(n, names)}'
              .trim(),
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// What is missing in one needs list, e.g. "Need 2: choose an item".
  /// [where] names the barangay in "Several barangays".
  List<String> _missingNeeds(List<_Need> list, Names names, {String? where}) {
    final at = where == null ? '' : '$where, ';
    return [
      for (var i = 0; i < list.length; i++)
        if (list[i].itemId == null ||
            (list[i].itemId == _other && _needName(list[i], names).isEmpty))
          '${at}Need ${i + 1}: choose an item'
        else if (_wholeNumber(maxEstimatedQuantity)(list[i].qty.text) != null)
          '${at}Enter a quantity for ${_needName(list[i], names)}'
        else if (_duplicateOf(list, i) case final dup?)
          '${at}Need ${i + 1}: already in Need $dup',
    ];
  }

  /// UAT post-meeting #6: when something is missing, say what in a pop-up
  /// (the red text under a field can be far up the form).
  List<String> _missing(Names names) {
    final out = <String>[];
    if (sms) {
      if (smsSender.text.trim().isEmpty) out.add('Sender number');
      if (smsText.text.trim().isEmpty) out.add('SMS text');
    }
    if (typeId == null) out.add('Disaster type');
    if (_typeIsOther(names) && typeOther.text.trim().length < 2) {
      out.add('What kind of disaster');
    }
    if (multi) {
      if (_multiCount < 2) {
        out.add('At least 2 barangays with affected families');
      }
    } else {
      if (brgyId == null) out.add('Barangay');
      if (_wholeNumber(maxAffectedFamilies)(families.text) != null) {
        out.add('Affected families');
      }
    }
    if (desc.text.trim().isEmpty) out.add('Short incident description');
    if (multi) {
      for (final row in _multiFamilies) {
        out.addAll(
          _missingNeeds(
            _needsOf(row.key),
            names,
            where: names.of('barangays', row.key),
          ),
        );
      }
    } else {
      out.addAll(_missingNeeds(needs, names));
    }
    return out;
  }

  Future<void> _showMissing(Names names) async {
    final missing = _missing(names);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: const Text('Please complete the form'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (missing.isEmpty)
              const Text('Check the fields marked in red.')
            else
              for (final m in missing)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('•  '),
                      Expanded(child: Text(m)),
                    ],
                  ),
                ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _submit(Names names) async {
    final valid = _form.currentState!.validate();
    // The pop-up's own checks too: in "Several barangays" a collapsed
    // barangay's needs are checked here.
    if (!valid || _missing(names).isNotEmpty) {
      await _showMissing(names);
      return;
    }
    if (multi) return _submitMulti(names);
    final total = needs.fold<int>(
      0,
      (a, n) => a + int.parse(n.qty.text.trim()),
    );
    // No limit on the total (testing, Oct 28); only what can be stored.
    if (total > _maxTotalQuantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'All needs together come to ${_withCommas(total)}, more than '
            'can be saved. Check the amounts.',
          ),
        ),
      );
      return;
    }
    setState(() => busy = true);
    // Per-item fulfillment (Oct 2026): `needs` is one line per item, in the
    // item's own unit, and fulfillment is measured per need. The readable
    // summary "Rice: 50 kg, Drinking Water: 20 L" and the total are still
    // sent for the screens that show them.
    final summary = needs
        .map(
          (n) =>
              '${_needName(n, names)}: ${n.qty.text.trim()} ${_needUnit(n, names)}'
                  .trim(),
        )
        .join(', ');
    final body = {
      'disaster_type_id': int.parse(typeId!),
      'disaster_type_other': _typeIsOther(names) ? typeOther.text.trim() : null,
      'barangay_id': int.parse(brgyId!),
      'sitio_id': _sitioIds.firstOrNull,
      'sitio_ids': _sitioIds,
      'description': desc.text.trim(),
      'affected_families': int.parse(families.text.trim()),
      'assistance_needed': summary,
      'estimated_quantity': total,
      'needs': [
        for (final n in needs)
          if (n.itemId == _other)
            {
              'other_item_name': n.otherName.text.trim(),
              'other_item_unit': _needUnit(n, names),
              'quantity': int.parse(n.qty.text.trim()),
            }
          else
            {
              'item_id': int.parse(n.itemId!),
              'quantity': int.parse(n.qty.text.trim()),
            },
      ],
    };
    if (editing) {
      final r = await act(
        context,
        () => api.put('/reports/${widget.edit!['report_id']}/mine', body: body),
        success: widget.edit!['status'] == 'Rejected'
            ? 'Report corrected and sent back for validation.'
            : 'Report updated. It is still pending validation.',
      );
      if (!mounted) return;
      setState(() => busy = false);
      if (r.ok) Navigator.of(context).pop(true);
      return;
    }
    // J8 / NF-014: encodeSmsReport asks for the reason when the sender is
    // not a registered Disaster Unit member.
    final r = sms
        ? await encodeSmsReport(
            context,
            {
              ...body,
              'contact_number': smsSender.text.trim(),
              'raw_message': smsText.text.trim(),
            },
            success:
                'SMS report encoded. It is now pending on the Validate tab.',
          )
        : await act(
            context,
            () => api.post('/reports/', body: {...body, 'source': 'Mobile'}),
            success: 'Report submitted. It is now pending admin validation.',
          );
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r.ok) {
        _form.currentState!.reset();
        typeOther.clear();
        desc.clear();
        families.clear();
        smsSender.clear();
        smsText.clear();
        _smsLen = 0;
        needs
          ..clear()
          ..add(_Need());
        typeId = brgyId = null;
        sitioRows = [''];
        _fillNotes = const [];
        _fills++;
      }
    });
    if (!r.ok) return _noAnswer(r);
    _draft?.clear(); // submitted: the draft is no longer needed
    _openStatus(
      reportId: r.json is Map ? (r.json['report_id'] as num?)?.toInt() : null,
    );
  }

  /// NF-003 / Nov 22: one barangay's own needs, whole quantities.
  List<Map<String, dynamic>> _multiNeeds(String id, Names names) => [
    for (final n in _needsOf(id))
      {
        if (n.itemId == _other) ...{
          'other_item_name': n.otherName.text.trim(),
          'other_item_unit': _needUnit(n, names),
        } else
          'item_id': int.parse(n.itemId!),
        'quantity': int.parse(n.qty.text.trim()),
      },
  ];

  Future<void> _submitMulti(Names names) async {
    final rows = _multiFamilies;
    final label = _typeIsOther(names)
        ? typeOther.text.trim()
        : names.of('disaster_types', typeId);
    final name = eventName.text.trim().isEmpty
        ? defaultEventName(label, DateTime.now())
        : eventName.text.trim();
    // A clean check of every barangay before anything is saved: its name,
    // its affected families and the whole-number amounts it will ask for.
    final preview = {
      for (final r in rows)
        r.key: PreviewBarangay(names.of('barangays', r.key), r.value, [
          for (final n in _needsOf(r.key))
            PreviewNeed(
              _needName(n, names),
              int.parse(n.qty.text.trim()),
              _needUnit(n, names),
            ),
        ]),
    };
    final ok = await showMultiReportPreview(
      context,
      eventName: name,
      disaster: label,
      barangays: preview.values.toList(),
    );
    if (!ok || !mounted) return;
    setState(() => busy = true);
    final r = await act(
      context,
      () => api.post(
        '/reports/batch',
        // Nov 22: one report per barangay can take longer than the usual
        // 20 seconds (it showed "Cannot reach the server" while saving).
        timeout: const Duration(minutes: 2),
        body: {
          'disaster_type_id': int.parse(typeId!),
          'disaster_type_other': _typeIsOther(names)
              ? typeOther.text.trim()
              : null,
          'description': desc.text.trim(),
          'event_name': eventName.text.trim().isEmpty
              ? null
              : eventName.text.trim(),
          'source': 'Mobile',
          'barangays': [
            for (final row in rows)
              {
                'barangay_id': int.parse(row.key),
                'affected_families': row.value,
                'needs': _multiNeeds(row.key, names),
              },
          ],
        },
      ),
      success:
          '${rows.length} reports submitted as one event. Each is pending '
          'admin validation.',
    );
    // Nov 22: the saved reports in one list, then on to Reports › Status.
    final saved = [
      if (r.ok && r.json is Map && r.json['reports'] is List)
        for (final x in (r.json['reports'] as List).cast<Map>())
          if (preview['${x['barangay_id']}'] case final b?)
            SubmittedReport((x['report_id'] as num).toInt(), b),
    ];
    final savedName = r.ok && r.json is Map && r.json['event'] is Map
        ? '${r.json['event']['event_name'] ?? name}'
        : name;
    if (!mounted) return;
    setState(() {
      busy = false;
      if (r.ok) {
        _form.currentState!.reset();
        typeOther.clear();
        desc.clear();
        eventName.clear();
        for (final c in multiRows.values) {
          c.dispose();
        }
        multiRows.clear();
        multiNeeds.clear();
        _suggestedForAll = false;
        needs
          ..clear()
          ..add(_Need());
        typeId = null;
        _fills++;
      }
    });
    if (!r.ok) return _noAnswer(r);
    _draft?.clear();
    if (saved.isEmpty) return _openStatus();
    final view = await showMultiReportSubmitted(
      context,
      eventName: savedName,
      reports: saved,
    );
    if (view && mounted) _openStatus();
  }

  /// After submitting: Reports › Status, on the Pending reports (the
  /// Disaster Unit follows its reports there). The Administrator encoding
  /// an SMS stays on the form for the next one.
  void _openStatus({int? reportId}) {
    if (!mounted || sms || editing) return;
    HomeNav.go(context, HomeTarget('Reports', view: 'Pending', id: reportId));
  }

  /// Nov 22: no answer from the server (slow connection or a time-out).
  /// The reports may still have been saved, so the reporter checks Report
  /// Status before sending them again (no duplicates). The form keeps what
  /// was typed in case they really were not saved. Other errors (a wrong
  /// field) keep the reporter on the form, with the server's message.
  Future<void> _noAnswer(ApiResult r) async {
    if (r.status != 0 || !mounted || sms || editing) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.wifi_off_outlined),
        title: const Text('No answer from the server'),
        content: const Text(
          'Your reports may already be saved. Check Report Status before '
          'you submit again, so nothing is reported twice. What you typed '
          'is still in the form.',
        ),
        actions: [
          FilledButton(
            key: const ValueKey('no-answer-status'),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Check Report Status'),
          ),
        ],
      ),
    );
    _openStatus();
  }

  /// The disaster type's name for the suggestion texts.
  String _templateName(Names names, Map<String, dynamic> t) =>
      _typeIsOther(names) ? 'other disasters' : '${t['name']}';

  /// "Suggested needs (optional)": tells the reporter NexaAid has a starting
  /// list for the disaster type; the button adds it.
  Widget _suggestedCard(Names names) {
    final t = _templateFor(names);
    final theme = Theme.of(context);
    final noFamilies = multi
        ? _multiCount == 0
        : (int.tryParse(families.text.trim()) ?? 0) <= 0;
    final String text;
    if (typeId == null) {
      text = 'Choose a disaster type to see the suggested needs for it.';
    } else if (t == null) {
      text =
          'There are no suggested needs for this type of disaster. Add '
          'the items the families need below.';
    } else {
      text =
          'Start faster: NexaAid has a ready-made list of what families '
          'usually need after ${_templateName(names, t)}, sized to '
          '${multi ? "each barangay's own families" : 'the families you report'}.'
          '${noFamilies ? ' Enter the affected families first so the amounts can be worked out.' : ''}';
    }
    return Card(
      key: const ValueKey('suggested-needs'),
      margin: const EdgeInsets.only(bottom: 12),
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.lightbulb_outline,
                  size: 20,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Suggested needs (optional)',
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(text, style: theme.textTheme.bodySmall),
            if (t != null) ...[
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                key: const ValueKey('use-suggested'),
                onPressed: () => _useSuggested(names),
                icon: const Icon(Icons.playlist_add),
                label: const Text('Use suggested needs'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Below the needs: what the suggested needs are, in plain words, and a
  /// note to use them with care (no item list, no formula).
  Widget _suggestedHowTo(Names names) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    return Container(
      key: const ValueKey('suggested-how'),
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'About suggested needs',
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Suggested needs are built from relief standards, such as the '
            'DSWD family food pack, so you never have to start from a blank '
            'form. They grow with the number of affected families and give '
            'you a complete first draft in one tap.',
            style: small,
          ),
          const SizedBox(height: 6),
          Text(
            'Use them with care: they are a starting point, not an '
            'assessment of this disaster. Check every item against what the '
            'families actually need, and change or remove anything that does '
            'not fit before you submit.',
            style: small?.copyWith(fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  /// "Several barangays" (Nov 22): one card per barangay with families,
  /// always open, holding its own needs as if it were reported on its own.
  Widget _multiNeedsSection(Names names) {
    final rows = _multiFamilies;
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Text(
          'Enter the affected families of each barangay above. Each one then '
          'gets its own needs list, just like a one-barangay report.',
          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            'Each barangay is its own report with its own needs. Change '
            'the items of any barangay below.',
            style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
        for (final row in rows)
          Builder(
            builder: (context) {
              final list = _needsOf(row.key);
              final name = names.of('barangays', row.key);
              final items = list.where((n) => n.itemId != null).length;
              return Card(
                key: ValueKey('multi-needs-${row.key}'),
                margin: const EdgeInsets.only(bottom: 10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: cs.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                // Nov 22: always open, like the one-barangay form: the
                // barangay's name on top, its needs under it.
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      color: cs.primaryContainer,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.place, color: cs.onPrimaryContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  name,
                                  style: t.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: cs.onPrimaryContainer,
                                  ),
                                ),
                                Text(
                                  '${withCommas(row.value)} '
                                  '${row.value == 1 ? 'family' : 'families'} · '
                                  '$items ${items == 1 ? 'item' : 'items'}',
                                  style: t.bodySmall?.copyWith(
                                    color: cs.onPrimaryContainer,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = 0; i < list.length; i++)
                            _needRow(list, i, names),
                          Align(
                            alignment: Alignment.centerLeft,
                            child: OutlinedButton.icon(
                              key: ValueKey('multi-add-${row.key}'),
                              onPressed: () {
                                setState(() => list.add(_Need()));
                                _saveDraft();
                              },
                              icon: const Icon(Icons.add),
                              label: const Text('Add another item'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  /// One need of [list] (the report's needs, or one barangay's in
  /// "Several barangays"): item, whole quantity, unit.
  Widget _needRow(List<_Need> list, int i, Names names) {
    final n = list[i];
    final unit = _needUnit(n, names);
    return Card(
      key: ObjectKey(n),
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: n.itemId,
                    isExpanded: true,
                    decoration: InputDecoration(labelText: 'Need ${i + 1}'),
                    items: [
                      for (final it in names.rows('items'))
                        DropdownMenuItem(
                          value: '${it['id']}',
                          child: Text('${it['item_name'] ?? it['name']}'),
                        ),
                      const DropdownMenuItem(
                        value: _other,
                        child: Text('Other…'),
                      ),
                    ],
                    // Another item on a suggested line: its suggested
                    // amount was for the old item, so it is cleared.
                    onChanged: (v) => setState(() {
                      if (n.auto && v != n.itemId) {
                        n
                          ..auto = false
                          ..qty.clear();
                      }
                      n.itemId = v;
                    }),
                    validator: (v) {
                      if (v == null) return 'Choose an item';
                      if (v == _other) return null; // checked on the name
                      final dup = _duplicateOf(list, i);
                      return dup == null
                          ? null
                          : 'Already in Need $dup. Change the amount there.';
                    },
                  ),
                ),
                if (list.length > 1)
                  IconButton(
                    tooltip: 'Remove this need',
                    onPressed: () {
                      setState(() => list.removeAt(i));
                      _saveDraft();
                    },
                    icon: const Icon(Icons.close),
                  ),
              ],
            ),
            if (n.itemId == _other) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: n.otherName,
                      decoration: const InputDecoration(labelText: 'Item'),
                      validator: (v) {
                        if ((v ?? '').trim().isEmpty) return 'Required';
                        final dup = _duplicateOf(list, i);
                        return dup == null ? null : 'Already in Need $dup';
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    // Testing fix 4.1: same unit list as the donation form.
                    child: QuantityUnitField(
                      controller: n.otherUnit,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            TextFormField(
              controller: n.qty,
              keyboardType: TextInputType.number,
              inputFormatters: _quantityInput,
              decoration: InputDecoration(
                labelText: 'Quantity needed',
                suffixText: unit.isEmpty ? null : unit,
                helperText: 'Whole numbers only',
              ),
              validator: _wholeNumber(maxEstimatedQuantity),
              // Typed or cleared by the reporter: it is theirs now and no
              // longer follows the families. An empty field stays empty
              // (and the form will not submit until it has an amount).
              onChanged: (_) => setState(() => n.auto = false),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Map<String, dynamic>>(
      future: api.lookups(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final names = Names(snap.data!);
        if (editing && !_filledFromEdit) {
          _filledFromEdit = true;
          _fillFromReport(widget.edit!, names);
        }
        final sitios = names
            .rows('sitios')
            .where((s) => '${s['barangay_id']}' == brgyId)
            .toList();
        return Form(
          key: _form,
          onChanged: _saveDraft,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              PageHeader(
                editing
                    ? 'Edit Report #${widget.edit!['report_id']}'
                    : sms
                    ? 'Encode SMS Report'
                    : 'Submit Disaster Report',
                subtitle: editing
                    ? (widget.edit!['status'] == 'Rejected'
                          ? 'Rejected: ${widget.edit!['rejection_reason'] ?? ''}\n'
                                'Correct it and save to send it back for validation.'
                          : 'You can change it until the Administrator validates it.')
                    : sms
                    ? 'Paste the text the Disaster Unit sent, tap Fill, then '
                          'check every field before saving. It is saved as '
                          'Pending; validate it on the Validate tab.'
                    : 'Your report stays Pending until the Administrator '
                          'checks and validates it. No internet? Send it by '
                          'text from the SMS report tab.',
              ),
              if (sms) ...[
                const SectionTitle('SMS as received'),
                TextFormField(
                  controller: smsSender,
                  keyboardType: TextInputType.phone,
                  // Same as the GCash field: digits only, stops at 11.
                  inputFormatters: phoneFormatters,
                  decoration: const InputDecoration(
                    labelText: 'Sender number',
                    hintText: '09XXXXXXXXX',
                    helperText: 'PH mobile number, 11 digits',
                  ),
                  validator: (v) {
                    final n = (v ?? '').trim();
                    if (n.isEmpty) return 'Required';
                    return RegExp(r'^09\d{9}$').hasMatch(n)
                        ? null
                        : 'Mobile number, 11 digits, e.g. 09171234567';
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: smsText,
                  minLines: 4,
                  maxLines: 10,
                  onChanged: (v) => _smsChanged(v, names),
                  decoration: const InputDecoration(
                    labelText: 'SMS text (paste it exactly as received)',
                    helperText:
                        'Paste the text and the form below fills itself in.',
                    hintText: 'NEXAAID REPORT\nTYPE: ...\nBRGY: ...',
                  ),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: () => _fillFromSms(names),
                    icon: const Icon(Icons.auto_fix_high),
                    label: const Text('Fill the form from this SMS'),
                  ),
                ),
                if (_fillNotes.isNotEmpty)
                  Card(
                    margin: const EdgeInsets.only(top: 8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final note in _fillNotes)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Icon(Icons.warning_amber, size: 18),
                                  const SizedBox(width: 6),
                                  Expanded(child: Text(note)),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
              const SectionTitle('Disaster and location'),
              LookupDropdown(
                key: ValueKey('type-$_fills'),
                list: 'disaster_types',
                label: 'Disaster type',
                value: typeId,
                names: names,
                // Nov 22: nothing is filled in by itself. Suggested needs
                // already in the list follow the new type's standard.
                onChanged: (v) => setState(() {
                  typeId = v;
                  _refillAuto(names);
                }),
              ),
              if (_typeIsOther(names)) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: typeOther,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'What kind of disaster?',
                    hintText: 'e.g. Gas leak',
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    if (t.isEmpty) return 'Required';
                    return t.length < 2 || t.length > 100
                        ? 'Use 2 to 100 characters'
                        : null;
                  },
                ),
              ],
              // NF-003: one disaster, several barangays (e.g. an earthquake):
              // one form, one report per barangay.
              if (_canMulti) ...[
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  key: const ValueKey('report-mode'),
                  segments: const [
                    ButtonSegment(
                      value: false,
                      icon: Icon(Icons.place_outlined),
                      label: Text('One barangay'),
                    ),
                    ButtonSegment(
                      value: true,
                      icon: Icon(Icons.share_location_outlined),
                      label: Text('Several barangays'),
                    ),
                  ],
                  selected: {multi},
                  onSelectionChanged: (v) => _setMulti(v.first, names),
                ),
              ],
              const SizedBox(height: 12),
              if (multi) ...[
                MultiBarangayPicker(
                  key: ValueKey('multi-$_fills'),
                  names: names,
                  typeId: typeId,
                  rows: multiRows,
                  maxFamilies: maxAffectedFamilies,
                  preview: (id, _) => _barangayPreview(id, names),
                  // New families: the suggested amounts follow them. A
                  // barangay picked after "Use suggested needs" gets them.
                  onChanged: () {
                    setState(() {
                      _suggestForNewBarangays(names);
                      _refillAuto(names);
                    });
                    _saveDraft();
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: eventName,
                  decoration: InputDecoration(
                    labelText: 'Event name (optional)',
                    hintText: typeId == null
                        ? 'e.g. Earthquake – Nov 9, 2026'
                        : defaultEventName(
                            _typeIsOther(names) &&
                                    typeOther.text.trim().isNotEmpty
                                ? typeOther.text.trim()
                                : names.of('disaster_types', typeId),
                            DateTime.now(),
                          ),
                    helperText:
                        'Donors see the barangays together under this name.',
                  ),
                  validator: (v) {
                    final t = (v ?? '').trim();
                    return t.isNotEmpty && (t.length < 2 || t.length > 150)
                        ? 'Use 2 to 150 characters'
                        : null;
                  },
                ),
              ] else
                HazardBarangayField(
                  key: ValueKey('brgy-$_fills'),
                  names: names,
                  typeId: typeId,
                  value: brgyId,
                  onChanged: (v) => setState(() {
                    brgyId = v;
                    sitioRows = [''];
                  }),
                ),

              // Concerns2: the sitio field only appears after a barangay is
              // chosen, lists only that barangay's sitios, and defaults to
              // the whole barangay. problema_napud 2.2: "Add another sitio".
              if (!multi && brgyId != null) ...[
                const SizedBox(height: 12),
                SitioPicker(
                  key: ValueKey('sitios-$brgyId-$_fills'),
                  options: {
                    for (final st in sitios) '${st['id']}': '${st['name']}',
                  },
                  rows: sitioRows,
                  onChanged: (rows) => setState(() => sitioRows = rows),
                ),
              ],
              if (!multi) ...[
                const SectionTitle('Donation info'),
                NewReportDonationInfo(barangayId: brgyId),
              ],
              const SectionTitle('What happened'),
              TextFormField(
                controller: desc,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'What happened? (short description)',
                  helperText:
                      'e.g. Flooding up to waist level in 3 sitios since 6 AM.',
                ),
                validator: (v) => (v ?? '').trim().isEmpty ? 'Required' : null,
              ),
              if (!multi) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: families,
                  keyboardType: TextInputType.number,
                  inputFormatters: _wholeNumberInput,
                  decoration: InputDecoration(
                    labelText: 'Affected families',
                    helperText:
                        'Whole number, up to ${_withCommas(maxAffectedFamilies)}',
                  ),
                  validator: _wholeNumber(maxAffectedFamilies),
                  // UAT Nov 10: every need the app filled (preset or added)
                  // follows the families; typed amounts stay.
                  onChanged: (_) => setState(() => _refillAuto(names)),
                ),
              ],
              const SectionTitle('What the families need'),
              // Nov 22: the suggested needs are optional. Nothing is filled
              // in until the reporter taps "Use suggested needs".
              _suggestedCard(names),
              if (multi)
                _multiNeedsSection(names)
              else ...[
                for (var i = 0; i < needs.length; i++)
                  _needRow(needs, i, names),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () {
                      setState(() => needs.add(_Need()));
                      _saveDraft();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Add another item'),
                  ),
                ),
              ],
              if (_templateFor(names) != null) _suggestedHowTo(names),
              const SizedBox(height: 16),
              // J7 / NF-012: typos are fixed only before saving.
              if (sms && !editing) ...[
                Text(
                  'Check every field against the SMS now. Once encoded, an '
                  'SMS report cannot be edited; it can only be rejected '
                  'with a reason so the Disaster Unit can resend it.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              FilledButton.icon(
                onPressed: busy ? null : () => _submit(names),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(50),
                ),
                icon: Icon(
                  editing
                      ? Icons.check
                      : sms
                      ? Icons.sms_outlined
                      : Icons.send,
                ),
                label: Text(
                  editing
                      ? 'Save changes'
                      : sms
                      ? 'Encode SMS report'
                      : multi
                      ? 'Submit ${_multiCount < 2 ? '' : '$_multiCount '}reports'
                      : 'Submit report',
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// ReportViewMemory keys of Reports > Validated and Reports > Status, so the
/// Disaster Unit's dashboard cards can open them on the right filters.
const validatedListKey = 'validated';
const monitoringListKey = 'monitoring';

// ---------------------------------------------------------------------------
// Appendix H 2.4 View validated reports (every role), with 3.3
// priority-based filtering for the roles that have it.
// ---------------------------------------------------------------------------
class ValidatedReportsScreen extends StatefulWidget {
  /// Show the priority filter (Admin, donors, CSWS Main Office and
  /// Disaster Unit in Appendix H 3.3).
  final bool filter;
  final bool header;
  const ValidatedReportsScreen({
    super.key,
    this.filter = false,
    this.header = true,
  });

  @override
  State<ValidatedReportsScreen> createState() => _ValidatedReportsScreenState();
}

class _ValidatedReportsScreenState extends State<ValidatedReportsScreen> {
  // Kept while the app is open (UAT Nov 2026, option A).
  static const _list = validatedListKey;
  late ReportView view = ReportViewMemory.read(_list, const ReportView());

  void _show(ReportView v) {
    ReportViewMemory.write(_list, v);
    setState(() => view = v);
  }

  @override
  Widget build(BuildContext context) {
    // Roles without 3.3 priority filtering never send a priority.
    final priority = widget.filter ? view.priority : null;
    // NF-003: filtered, sorted and paged by the server (10 at a time).
    return PagedReportList(
      path: '/reports/validated',
      query: {
        'priority_level': ?priority,
        'fulfillment': ?view.fulfillment,
        'sort': reportSortParam(view.sort),
        ...view.placeQuery,
      },
      countsPath: '/reports/validated/counts',
      countsQuery: {'priority_level': ?priority, ...view.placeQuery},
      header: (counts) => [
        if (widget.header)
          PageHeader(
            'Validated Reports',
            subtitle: 'Reports approved by the Administrator • ${roleLine()}',
          ),
        // One Filter button and a compact sort (UAT Nov 2026).
        // Fulfillment status and sort for every role (Ivan's note:
        // fulfilled reports are found with the Fulfilled filter, there is
        // no separate Done section); priorities only for 3.3 roles.
        ReportFilterBar(
          value: view,
          onChanged: _show,
          priorities: widget.filter,
          counts: counts,
        ),
      ],
      empty: ReportListEmpty(
        'No validated reports to show.',
        filtered: activeFilters(view) > 0,
        onClear: () => _show(view.withFilters()),
      ),
      itemBuilder: (context, r, names) => ReportCard(r, names),
    );
  }
}

/// Reports menu for CSWS Main Office and Disaster Unit: validated reports
/// (2.4) and report status monitoring (2.5), both with priority filters.
class ReportsHub extends StatefulWidget {
  const ReportsHub({super.key});

  @override
  State<ReportsHub> createState() => _ReportsHubState();
}

class _ReportsHubState extends State<ReportsHub>
    with HomeTargetListener<ReportsHub> {
  bool monitor = false;

  // A notification about one report (UAT Nov 2026, M2.5): Status opens on
  // the list the report is in now, with that report first and outlined.
  String? _focusStatus;
  int? _focusId;
  int _focus = 0;

  // A notification about a report opens Reports > Validated or Status.
  @override
  String get homeTab => 'Reports';

  /// Bumped to open Validated again on the filters a dashboard card set.
  int _validated = 0;

  @override
  void applyHomeTarget(HomeTarget target) {
    if (target.view == 'validated') monitor = false;
    // Disaster Unit dashboard: validated reports still in need, the least
    // fulfilled first (other filters cleared so none hides a report).
    if (target.view == 'underserved') {
      monitor = false;
      final v = ReportViewMemory.read(validatedListKey, const ReportView());
      ReportViewMemory.write(
        validatedListKey,
        v.withFilters().withSort(ReportSort.leastFulfilled),
      );
      _validated++;
      return;
    }
    // Disaster Unit dashboard: only its own reports of one status
    // ('mine:Pending', 'mine:Rejected').
    final view = target.view ?? '';
    if (view.startsWith('mine:')) {
      final v = ReportViewMemory.read(monitoringListKey, const ReportView());
      ReportViewMemory.write(
        monitoringListKey,
        v.withFilters().withOnlyMine(true),
      );
      target = HomeTarget(target.tab, view: view.substring(5), id: target.id);
    }
    if (target.view == 'status' || reportStatuses.contains(target.view)) {
      monitor = true;
      _focusStatus = reportStatuses.contains(target.view) ? target.view : null;
      _focusId = target.id;
      _focus++;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          child: SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.verified_outlined),
                label: Text('Validated'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.monitor_heart_outlined),
                label: Text('Status'),
              ),
            ],
            selected: {monitor},
            onSelectionChanged: (v) {
              setState(() {
                monitor = v.first;
                // From now on the user's own filters, not the notification's.
                _focusStatus = null;
                _focusId = null;
              });
              // NF-002: /csws/reports/status.
              AppRoutes.instance.viewChanged(
                homeTab,
                monitor ? 'status' : 'validated',
              );
            },
          ),
        ),
        Expanded(
          // UAT (Nov 14): Validated and Status stay loaded when switching.
          child: KeptViews(
            current: monitor ? 'status' : 'validated',
            builder: (context, v) => v == 'status'
                ? MonitoringScreen(
                    key: ValueKey(_focus),
                    focusStatus: _focusStatus,
                    focusId: _focusId,
                  )
                : ValidatedReportsScreen(
                    key: ValueKey('validated-$_validated'),
                    filter: true,
                  ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Appendix H 2.5 Monitor report status (Admin, CSWS Main Office,
// CSWS Disaster Unit): every report with its fulfillment progress.
// ---------------------------------------------------------------------------
class MonitoringScreen extends StatefulWidget {
  /// Opened from a notification about one report: show this status (the
  /// list the report is in now) and put [focusId] first, outlined.
  final String? focusStatus;
  final int? focusId;
  const MonitoringScreen({super.key, this.focusStatus, this.focusId});

  @override
  State<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends State<MonitoringScreen> {
  // Kept while the app is open (UAT Nov 2026, option A).
  static const _list = monitoringListKey;
  late ReportView view = _initialView();
  int _loads = 0;

  // Oct 11 (Daniel): the CSWS Disaster Unit edits or withdraws its own
  // reports here until the Administrator validates them.
  bool get _reporter => api.role == Roles.cswsUnit;

  /// The Disaster Unit's own reports (ids), for Edit / Withdraw and the
  /// "Only my reports" count. Only this user's reports, so a short list.
  Set<int> _mine = {};

  @override
  void initState() {
    super.initState();
    _loadMine();
  }

  Future<void> _loadMine() async {
    if (!_reporter) return;
    final r = await api.get('/reports/mine');
    if (!mounted || !r.ok || r.json is! List) return;
    setState(
      () => _mine = {
        for (final x in (r.json as List).cast<Map>())
          (x['report_id'] as num).toInt(),
      },
    );
  }

  ReportView _initialView() {
    final saved = ReportViewMemory.read(_list, const ReportView());
    if (widget.focusStatus == null && widget.focusId == null) return saved;
    // A notification: only that status, no other filter that could hide
    // the report.
    final v = saved.withFilters(status: widget.focusStatus);
    ReportViewMemory.write(_list, v);
    return v;
  }

  void _show(ReportView v) {
    ReportViewMemory.write(_list, v);
    setState(() => view = v);
  }

  Future<void> _edit(Map<String, dynamic> r) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Edit report')),
          body: NewReportScreen(edit: r),
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _loads++);
      _loadMine();
    }
  }

  Future<void> _withdraw(Map<String, dynamic> r) async {
    final v = await formDialog(
      context,
      title: 'Withdraw report #${r['report_id']}?',
      message:
          'It will not be validated or shown to donors. It stays in your '
          'list as Cancelled.',
      fields: const [
        DialogField(
          'reason',
          'Reason (optional)',
          required: false,
          multiline: true,
          hint: 'e.g. Sent twice, or wrong barangay',
        ),
      ],
      confirm: 'Withdraw',
    );
    if (v == null || !mounted) return;
    final res = await act(
      context,
      () => api.post(
        '/reports/${r['report_id']}/withdraw',
        body: {if (v['reason']!.isNotEmpty) 'reason': v['reason']},
      ),
      success: 'Report #${r['report_id']} withdrawn',
    );
    if (res.ok && mounted) {
      setState(() => _loads++);
      _loadMine();
    }
  }

  @override
  Widget build(BuildContext context) {
    final mine = _mine;
    bool editable(Map r) =>
        mine.contains(r['report_id']) &&
        (r['status'] == 'Pending' || r['status'] == 'Rejected');
    final filters = {
      'status': ?view.status,
      'priority_level': ?view.priority,
      if (view.onlyMine) 'mine': 'true',
      ...view.placeQuery,
    };
    // NF-003: status, priority, fulfillment, "only mine" and the sort are
    // applied by the server, 20 reports at a time. With "Only my reports",
    // the ones that can still be edited come first (server side too).
    return PagedReportList(
      path: '/reports/monitoring',
      query: {
        ...filters,
        'fulfillment': ?view.fulfillment,
        'sort': reportSortParam(view.sort),
      },
      countsPath: '/reports/monitoring/counts',
      countsQuery: filters,
      reloadKey: _loads,
      // The report a notification pointed at comes first, outlined.
      focusId: widget.focusId,
      header: (counts) => [
        PageHeader(
          'Report Status',
          subtitle:
              'Fulfillment progress of every report, active and done • '
              '${roleLine()}',
        ),
        // UAT Nov 2026 (M2.5): one Filter button with Validation Status
        // (Rejected reports no longer sink to the bottom), Priorities and
        // Fulfillment Status, and a compact sort.
        ReportFilterBar(
          value: view,
          onChanged: _show,
          statuses: reportStatuses,
          counts: counts,
          trailing: [
            if (_reporter)
              FilterChip(
                avatar: const Icon(Icons.person_outline, size: 18),
                label: Text('Only my reports (${mine.length})'),
                selected: view.onlyMine,
                onSelected: (v) => _show(view.withOnlyMine(v)),
              ),
          ],
        ),
      ],
      empty: ReportListEmpty(
        'No reports to show.',
        filtered: activeFilters(view) > 0 || view.onlyMine,
        onClear: () => _show(ReportView(sort: view.sort)),
      ),
      itemBuilder: (context, r, names) => ReportCard(
        r,
        names,
        highlighted: r['report_id'] == widget.focusId,
        actions: editable(r)
            ? [
                TextButton.icon(
                  onPressed: () => _withdraw(r),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.danger,
                  ),
                  icon: const Icon(Icons.block, size: 18),
                  label: const Text('Withdraw'),
                ),
                // J7 / NF-012: an SMS report is locked; it is resent.
                if (r['source'] != 'SMS')
                  FilledButton.tonalIcon(
                    onPressed: () => _edit(r),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: Text(
                      r['status'] == 'Rejected' ? 'Fix and resend' : 'Edit',
                    ),
                  ),
              ]
            : const [],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UC-A3 Process reports (Administrator)
// ---------------------------------------------------------------------------
class AdminReportsScreen extends StatefulWidget {
  const AdminReportsScreen({super.key});

  @override
  State<AdminReportsScreen> createState() => _AdminReportsScreenState();
}

class _AdminReportsScreenState extends State<AdminReportsScreen>
    with HomeTargetListener<AdminReportsScreen> {
  // Kept while the app is open (UAT Nov 2026, option A). Report Validation
  // always shows one status; Pending is the validation queue.
  static const _list = 'validation';
  static const _defaults = ReportView(status: 'Pending');
  static const _statuses = ['Pending', 'Validated', 'Rejected'];
  late ReportView view = ReportViewMemory.read(_list, _defaults);
  int _loads = 0;
  int? _highlight; // report the notification is about, shown first
  // Reports being validated right now: the button shows a spinner and a
  // second tap is ignored (validating notifies every donor, which can take
  // a few seconds on the hosted database).
  final Set<int> _validating = {};

  @override
  String get homeTab => 'Validate';

  Future<void> _validate(Map<String, dynamic> r) async {
    final id = r['report_id'] as int;
    if (_validating.contains(id)) return;
    setState(() => _validating.add(id));
    final res = await act(
      context,
      () => api.post('/reports/$id/validate'),
      success: 'Report #$id validated and published to donors',
    );
    if (!mounted) return;
    setState(() {
      _validating.remove(id);
      // Validated now, or already validated by an earlier tap or another
      // Administrator: either way it leaves the Pending list.
      if (res.ok || res.status == 400 || res.status == 409) _loads++;
    });
  }

  @override
  void applyHomeTarget(HomeTarget target) {
    if (_statuses.contains(target.view)) {
      // Only that status, no other filter that could hide the report.
      view = view.withFilters(status: target.view);
      ReportViewMemory.write(_list, view);
    }
    _highlight = target.id;
    _loads++;
  }

  void _show(ReportView v) {
    ReportViewMemory.write(_list, v);
    setState(() => view = v);
  }

  Future<void> _reject(Map<String, dynamic> r) async {
    final v = await formDialog(
      context,
      title: 'Reject report #${r['report_id']}',
      message: 'The reason is sent back so the report can be corrected.',
      fields: const [DialogField('reason', 'Reason', multiline: true)],
      confirm: 'Reject',
    );
    if (v == null || !mounted) return;
    await act(
      context,
      () => api.post(
        '/reports/${r['report_id']}/reject',
        body: {'rejection_reason': v['reason']},
      ),
      success: 'Report #${r['report_id']} rejected',
    );
  }

  /// Testing 2.3: the Administrator deletes a Rejected report. The server
  /// keeps the row for the audit trail and hides it from every list.
  Future<void> _delete(Map<String, dynamic> r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete report #${r['report_id']}?'),
        content: const Text(
          'It disappears from every list. The rejection and who made it '
          'stay in the audit log.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep report'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await act(
      context,
      () => api.delete('/reports/${r['report_id']}'),
      success: 'Report #${r['report_id']} deleted',
    );
  }

  @override
  Widget build(BuildContext context) {
    final status = view.status ?? 'Pending';
    final validated = status == 'Validated';
    // NF-003: a page at a time. Validated reports come with their
    // fulfillment progress, for the fulfillment filter and sort (Ivan's
    // note); Pending and Rejected stay newest first.
    return PagedReportList(
      path: validated ? '/reports/validated' : '/reports/',
      query: validated
          ? {
              'priority_level': ?view.priority,
              'fulfillment': ?view.fulfillment,
              'sort': reportSortParam(view.sort),
              ...view.placeQuery,
            }
          : {'status': status, 'sort': 'newest', ...view.placeQuery},
      countsPath: validated ? '/reports/validated/counts' : null,
      countsQuery: {'priority_level': ?view.priority, ...view.placeQuery},
      reloadKey: _loads,
      // The report a notification pointed at comes first, outlined.
      focusId: _highlight,
      header: (counts) => [
        PageHeader('Report Validation', subtitle: roleLine()),
        // UAT Nov 2026 (M2.3, M3.3): one Filter button instead of the
        // Pending / Validated / Rejected switch and two chip rows.
        // Priorities, fulfillment and sort are for validated reports, as
        // before.
        ReportFilterBar(
          value: view,
          defaults: _defaults,
          onChanged: _show,
          statuses: _statuses,
          anyStatus: false,
          counts: counts,
          detailsOnlyFor: 'Validated',
          showSort: validated,
        ),
      ],
      empty: ReportListEmpty(
        'No ${status.toLowerCase()} reports.',
        filtered:
            view.priority != null ||
            view.fulfillment != null ||
            view.barangayId != null ||
            view.disasterTypeId != null,
        onClear: () => _show(view.withFilters(status: status)),
      ),
      // J7 / NF-012: an SMS report shows the SMS as received beside it.
      itemBuilder: (context, r, names) => _withSms(
        r,
        ReportCard(
          r,
          names,
          highlighted: r['report_id'] == _highlight,
          actions: status == 'Pending'
              ? [
                  OutlinedButton(
                    onPressed: () => _reject(r),
                    child: const Text('Reject'),
                  ),
                  FilledButton.icon(
                    onPressed: _validating.contains(r['report_id'])
                        ? null
                        : () => _validate(r),
                    icon: _validating.contains(r['report_id'])
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check),
                    label: Text(
                      _validating.contains(r['report_id'])
                          ? 'Validating…'
                          : 'Validate',
                    ),
                  ),
                ]
              : status == 'Rejected'
              ? [
                  OutlinedButton.icon(
                    onPressed: () => _delete(r),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                  ),
                ]
              : const [],
        ),
      ),
    );
  }

  Widget _withSms(Map r, Widget card) => r['source'] == 'SMS'
      ? SmsBeside(card: card, reportId: (r['report_id'] as num).toInt())
      : card;
}

// UC-A1 account creation moved to account_form.dart (AccountsScreen).

// ---------------------------------------------------------------------------
// Dashboards (UC-A4, UC-CD2, UC-CM3, UC-B2)
// ---------------------------------------------------------------------------
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Loader(
      load: [
        () => api.get('/dashboard/summary'),
        // Validated reports per fulfillment status (Not Started,
        // In Progress, Fulfilled), for "Still need help".
        () => api.get('/reports/validated/counts'),
        // The unit's own reports, for its coordination with the Admin.
        () => api.get('/reports/mine'),
        // "Most in need": validated reports, open first, then priority
        // (Critical first), then least fulfilled (report_paging "urgent").
        () => api.get(
          '/reports/validated',
          query: {'offset': '0', 'limit': '5', 'sort': 'urgent'},
        ),
        api.lookupsResult,
      ],
      builder: (context, d) {
        final s = d[0] as Map, f = d[1] as Map;
        final mine = (d[2] as List).cast<Map>();
        final names = Names(Map<String, dynamic>.from(d[4] as Map));
        // Fulfilled reports sort last; drop any that filled the 5 rows.
        final mostInNeed = (d[3] as List)
            .cast<Map>()
            .where(
              (r) =>
                  (num.tryParse('${r['fulfillment_percentage']}') ?? 0) < 100,
            )
            .toList();
        final waiting = mine.where((r) => r['status'] == 'Pending').length;
        final toFix = mine.where((r) => r['status'] == 'Rejected').length;
        int n(Object? v) => (v as num?)?.toInt() ?? 0;
        final inNeed = n(f['Not Started']) + n(f['In Progress']);

        void open(String view) =>
            HomeNav.go(context, HomeTarget('Reports', view: view));

        // Nov 24: the four cards of UC-CD2 needs monitoring, each opening
        // the Reports list behind it. Physical goods, deliveries and
        // logistics are the Main Office's and DRRMO's (manuscript scope
        // boundary), so they are not here.
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            PageHeader('CSWS Disaster Unit Dashboard', subtitle: roleLine()),
            StatCardGrid([
              StatCard(
                // Rejected and withdrawn reports are not counted (backend).
                label: 'Disaster reports',
                value: '${s['total_reports']}',
                icon: Icons.report_outlined,
                note: 'Active and done',
                onTap: () => open('status'),
              ),
              StatCard(
                label: 'Still need help',
                value: '$inNeed',
                icon: Icons.volunteer_activism_outlined,
                color: inNeed > 0 ? AppColors.danger : AppColors.success,
                note: 'Validated, not yet fulfilled',
                onTap: () => open('underserved'),
              ),
              StatCard(
                label: 'Waiting for validation',
                value: '$waiting',
                icon: Icons.hourglass_top,
                note: 'Your reports · can still edit',
                onTap: () => open('mine:Pending'),
              ),
              StatCard(
                label: 'Returned to correct',
                value: '$toFix',
                icon: Icons.assignment_return_outlined,
                color: toFix > 0 ? AppColors.danger : null,
                note: 'Your reports sent back',
                onTap: () => open('mine:Rejected'),
              ),
            ]),
            // UC-CD2: which barangays still need help, not just how many.
            SectionHeader(
              'Most in need',
              subtitle: 'Highest priority, least fulfilled first',
              action: inNeed > 0
                  ? TextButton(
                      onPressed: () => open('underserved'),
                      child: Text('See all $inNeed'),
                    )
                  : null,
            ),
            if (mostInNeed.isEmpty)
              AppCard(
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_outline,
                        color: AppColors.success),
                    Gaps.h12,
                    const Expanded(
                      child: Text('All validated reports are fulfilled.'),
                    ),
                  ],
                ),
              )
            else
              for (final r in mostInNeed)
                _NeedRow(
                  r,
                  names,
                  // Report Status > Validated, with this report first and
                  // outlined (as a notification about it opens it).
                  onTap: () => HomeNav.go(
                    context,
                    HomeTarget(
                      'Reports',
                      view: 'Validated',
                      id: (r['report_id'] as num?)?.toInt(),
                    ),
                  ),
                ),
          ],
        );
      },
    );
  }
}

/// One "Most in need" row: barangay and disaster, priority, fulfillment.
class _NeedRow extends StatelessWidget {
  final Map r;
  final Names names;
  final VoidCallback onTap;
  const _NeedRow(this.r, this.names, {required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AppCard(
      margin: const EdgeInsets.only(bottom: Space.sm),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${names.of('barangays', r['barangay_id'])} · '
                  '${disasterLabel(r, names)}',
                  style: t.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Gaps.h8,
              PriorityChip(r['priority_level'] as String?, showIcon: false),
            ],
          ),
          Gaps.v12,
          FulfillmentBar(
            delivered: r['total_items_delivered'] as num? ?? 0,
            needed: r['total_items_needed'] as num? ?? 0,
            percent: num.tryParse('${r['fulfillment_percentage']}'),
          ),
        ],
      ),
    );
  }
}
