import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'donation_info.dart' show ReportDonationInfo;
import 'expiry_widgets.dart' show ExpiryNote;
import 'form_draft.dart';
import 'input_formatters.dart';
import 'location_picker.dart';
import 'pickup_days.dart';
import 'qr_save.dart';
import 'quantity_units.dart';
import 'report_summary_card.dart' show NeedChips;
import 'widgets.dart';

// Fallback drop-off details, shown only when GET /donations/drop-off-info
// cannot be reached. The real values live in the backend .env
// (DROPOFF_NAME, DROPOFF_ADDRESS, DROPOFF_HOURS, DROPOFF_LAT, DROPOFF_LNG).
const storageAddress =
    'City of Mandaue City Social Services (CSWS), P.J. Burgos Street, Mandaue City';
const storageHours = 'Monday to Friday, 8:00 AM to 5:00 PM';

// Per-item fulfillment (Oct 2026, docs/architecture/per-item-fulfillment.md).
// Every item has one base unit: kg, L, or a count (cans, kits, pcs...). The
// donor describes a line as
//   number of packs x items per pack x size of each
// (manuscript 3.1: "packaging size, based on the available packaging
// options shown in the system") and the server works out the total in the
// base unit, e.g. 3 boxes x 16 x 1.5 L bottle = 72 L. Packaging is only a
// description, so "sack" is no longer a unit (testing item 4.1).

const _otherItem = 'other';

/// A size typed by the donor instead of one of the item's sizes.
const _customSize = 'custom';

/// Quick choices for "items per pack". 1 = single items, not in packs.
const _perPackChoices = [1, 6, 10, 12, 15, 16, 24];

/// Same limits as the server (schemas/physical_donation_schema.py).
const _maxPacks = 100000;
const _maxPerPack = 10000;

/// How many base units (kg or L) one of each unit is. Same as FACTORS in
/// the backend's services/units.py.
const _unitFactors = {
  'kg': 1.0,
  'g': 0.001,
  'L': 1.0,
  'ml': 0.001,
  'gallon': 3.785411784,
};

/// "kilos" -> kg, "liters" -> L (the backend's _ALIASES), for a unit typed
/// under "Something else…".
String? _measuredUnit(String unit) {
  final u = unit.trim().toLowerCase();
  if (const [
    'kg',
    'kgs',
    'kilo',
    'kilos',
    'kilogram',
    'kilograms',
  ].contains(u)) {
    return 'kg';
  }
  if (const ['l', 'liter', 'liters', 'litre', 'litres'].contains(u)) return 'L';
  return null;
}

/// What the form needs to know about the chosen item: its base unit, the
/// units a custom size may be typed in, and its common sizes (/lookups).
class _ItemInfo {
  final String unit;
  final List<String> sizeUnits;
  final List<Map<String, dynamic>> sizes; // {id, label, amount in base units}
  const _ItemInfo(this.unit, this.sizeUnits, this.sizes);

  factory _ItemInfo.fromLookup(Map<String, dynamic> it) {
    final unit = '${it['unit'] ?? ''}';
    return _ItemInfo(
      unit,
      [for (final u in (it['size_units'] as List? ?? const [])) '$u'],
      [
        for (final s in (it['sizes'] as List? ?? const []))
          Map<String, dynamic>.from(s as Map),
      ],
    );
  }

  /// "Something else…": the unit the donor typed decides how it's measured.
  factory _ItemInfo.typed(String unit) => switch (_measuredUnit(unit)) {
    'kg' => _ItemInfo(unit, const ['kg', 'g'], const []),
    'L' => _ItemInfo(unit, const ['L', 'ml', 'gallon'], const []),
    _ => _ItemInfo(unit, [unit], const []),
  };

  /// Counted items (cans, kits, pcs) need no size: each one is 1.
  bool get counted => !_unitFactors.containsKey(sizeUnits.firstOrNull);
}

/// One item line on the donation form.
class _Line {
  String? itemId;

  /// One of the item's sizes (its id), [_customSize], or null.
  String? sizeId;
  String? sizeUnit; // unit of a custom size
  int? perPack = 1; // null = typed in [perPackOther]
  final packs = TextEditingController();
  final perPackOther = TextEditingController();
  final sizeAmount = TextEditingController();
  final value = TextEditingController();
  final otherName = TextEditingController();
  final otherUnit = TextEditingController();

  int? get packCount => int.tryParse(packs.text.trim());
  int? get perPackValue => perPack ?? int.tryParse(perPackOther.text.trim());

  /// A typed size is used when the item has no sizes, or "Other size".
  bool usesCustomSize(_ItemInfo info) =>
      !info.counted && (info.sizes.isEmpty || sizeId == _customSize);

  String unitOf(_ItemInfo info) =>
      info.sizeUnits.contains(sizeUnit) ? sizeUnit! : info.sizeUnits.first;

  Map<String, dynamic>? _size(_ItemInfo info) {
    for (final s in info.sizes) {
      if ('${s['id']}' == sizeId) return s;
    }
    return null;
  }

  /// Size of one item in base units, or null while it isn't chosen.
  double? sizeInBase(_ItemInfo info) {
    if (info.counted) return 1;
    if (usesCustomSize(info)) {
      final amount = double.tryParse(sizeAmount.text.trim());
      if (amount == null || amount <= 0) return null;
      return amount * _unitFactors[unitOf(info)]!;
    }
    return (_size(info)?['amount'] as num?)?.toDouble();
  }

  /// packs x per pack x size, before rounding.
  double? exactTotal(_ItemInfo info) {
    final n = packCount, per = perPackValue, size = sizeInBase(info);
    if (n == null || n <= 0 || per == null || per <= 0 || size == null) {
      return null;
    }
    // Rounded to 6 places first so 0.33 x 50 gives 16.5, as on the server.
    return (n * per * size * 1e6).round() / 1e6;
  }

  /// The total the server will save: a whole number of base units, half up
  /// (3 x 500 ml = 1.5 L -> 2 L).
  int? total(_ItemInfo info) => exactTotal(info)?.round();

  /// "3 packs x 16 x 1.5 L bottle", "10 packs x 6 cans", "4 x 25 kg sack".
  String breakdown(_ItemInfo info) {
    final n = packCount ?? 0, per = perPackValue ?? 1;
    if (info.counted) {
      return per > 1 ? '$n packs × $per ${info.unit}' : '$n ${info.unit}';
    }
    final size = usesCustomSize(info)
        ? '${sizeAmount.text.trim()} ${unitOf(info)}'
        : '${_size(info)?['label'] ?? ''}';
    return per > 1 ? '$n packs × $per × $size' : '$n × $size';
  }

  Map<String, dynamic> toJson(_ItemInfo info) => {
    if (itemId == _otherItem) ...{
      'other_item_name': otherName.text.trim(),
      'other_item_unit': otherUnit.text.trim(),
    } else
      'item_id': int.parse(itemId!),
    'pack_count': packCount,
    'per_pack': perPackValue,
    if (usesCustomSize(info)) ...{
      'size_amount': double.parse(sizeAmount.text.trim()),
      'size_unit': unitOf(info),
    } else if (!info.counted)
      'size_id': int.parse(sizeId!),
    'estimated_value': ThousandsFormatter.parse(value.text),
  };

  void dispose() {
    packs.dispose();
    perPackOther.dispose();
    sizeAmount.dispose();
    value.dispose();
    otherName.dispose();
    otherUnit.dispose();
  }
}

/// Side padding that keeps content at a readable width on wide screens
/// (Chrome, tablets) and normal page padding on phones.
double _sidePadding(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  return math.max(Space.md, (w - Breakpoints.contentMax) / 2);
}

/// UC-D2 step 5-6: physical donation form (one or more items). The whole
/// donation is saved in one request and gets ONE QR reference.
class DonateScreen extends StatefulWidget {
  final Map<String, dynamic> report;
  final Names names;

  /// Oct 11: the donor changes a donation still waiting (or declined). The
  /// form opens filled in; saving keeps the same QR reference.
  final Map? edit;

  /// Oct 23: more items for a donation already pledged. Only the items
  /// section shows; they join the same donation, QR code and handover as a
  /// new batch (POST /donations/entries/{ref}/items).
  final Map? addTo;
  const DonateScreen({
    super.key,
    required this.report,
    required this.names,
    this.edit,
    this.addTo,
  });

  @override
  State<DonateScreen> createState() => _DonateScreenState();
}

class _DonateScreenState extends State<DonateScreen> {
  final _form = GlobalKey<FormState>();
  final _scroll = ScrollController();
  final lines = <_Line>[_Line()];
  String handover = 'Drop Off';
  bool useSavedAddress = true;
  String? savedAddress; // organization address, if the account has one
  // Door to Door pickup details:
  //   address   -> typed by the donor, no suggestions
  //   landmark  -> box with map suggestions (also gives the pin for CSWS)
  //   dates     -> pickupDates: the dates the donor is home (calendar)
  //   notes     -> free text for the pickup team
  final pickupLandmark = TextEditingController();
  final pickupAddress = TextEditingController();
  final pickupNotes = TextEditingController();
  PickedAddress? picked; // set when the donor taps a landmark suggestion
  Set<DateTime> pickupDates = {}; // Door to Door: dates the donor is home
  // Map check of the picked landmark (GET /donations/location/coverage):
  // null = not checked yet. False locks the rest of the pickup details and
  // offers Drop Off instead.
  bool? _covered;
  String? _coveragePlace;
  bool _checkingCoverage = false;
  int _coverageSeq = 0; // ignores answers for a landmark that was replaced
  PickupRules pickupRules = const PickupRules();
  final guestName = TextEditingController();
  final guestPhone = TextEditingController();
  bool busy = false;

  bool get _editing => widget.edit != null;
  bool get _adding => widget.addTo != null;

  /// Fill the form from the donation being changed.
  void _fillFromEntry(Map e) {
    lines
      ..forEach((l) => l.dispose())
      ..clear();
    for (final i in (e['items'] as List? ?? const []).cast<Map>()) {
      final l = _lineFromEntryItem(i);
      final value =
          (i['estimated_value'] as num?) ??
          num.tryParse('${i['estimated_value'] ?? ''}');
      if (value != null) {
        l.value.text = ThousandsFormatter.format('${value.round()}');
      }
      lines.add(l);
    }
    if (lines.isEmpty) lines.add(_Line());
    handover = '${e['handover_method'] ?? 'Drop Off'}';
    pickupLandmark.text = '${e['pickup_landmark'] ?? ''}';
    pickupAddress.text = '${e['pickup_address'] ?? ''}';
    pickupNotes.text = '${e['pickup_notes'] ?? ''}';
    // Older entries only have weekdays: the donor picks dates again.
    pickupDates = pickupDatesOf(e['pickup_dates']);
    final lat = (e['pickup_lat'] as num?)?.toDouble();
    final lng = (e['pickup_lng'] as num?)?.toDouble();
    picked = lat != null && lng != null
        ? PickedAddress(pickupLandmark.text, lat: lat, lng: lng)
        : null;
    useSavedAddress = false; // show the address that was given
  }

  /// One saved item back into the form. Newer donations kept their
  /// breakdown (pack_count, per_pack, size_label); older ones only a total
  /// in the base unit, which opens as that many single items of 1 kg / 1 L.
  _Line _lineFromEntryItem(Map i) {
    final l = _Line()..itemId = '${i['item_id']}';
    final info = _infoOf(l);
    final packs = i['pack_count'] ?? i['quantity'];
    l.packs.text = packs == null ? '' : '$packs';
    if (info == null) {
      // A retired item (e.g. "Rice (sacks, old)"): choose the current one.
      l.itemId = null;
      return l;
    }
    final per = (i['per_pack'] as num?)?.toInt() ?? 1;
    if (_perPackChoices.contains(per)) {
      l.perPack = per;
    } else {
      l
        ..perPack = null
        ..perPackOther.text = '$per';
    }
    if (info.counted) return l;
    final label = '${i['size_label'] ?? ''}';
    final saved = i['pack_count'] == null
        ? info.sizes.where((s) => s['amount'] == 1).firstOrNull
        : info.sizes.where((s) => s['label'] == label).firstOrNull;
    if (saved != null) {
      l.sizeId = '${saved['id']}';
      return l;
    }
    // A typed size, saved as e.g. "2 L"; or 1 base unit for older entries.
    final m = i['pack_count'] == null
        ? null
        : RegExp(r'^(\d+(?:\.\d+)?)\s*(\S+)$').firstMatch(label);
    final typed = m != null && info.sizeUnits.contains(m.group(2));
    l
      ..sizeId = info.sizes.isEmpty ? null : _customSize
      ..sizeAmount.text = typed ? m.group(1)! : '1'
      ..sizeUnit = typed ? m.group(2) : info.sizeUnits.first;
    return l;
  }

  _ItemInfo? _infoOf(_Line l) {
    if (l.itemId == _otherItem) {
      final unit = l.otherUnit.text.trim();
      return unit.isEmpty ? null : _ItemInfo.typed(unit);
    }
    for (final it in widget.names.rows('items')) {
      if ('${it['id']}' == l.itemId) return _ItemInfo.fromLookup(it);
    }
    return null;
  }

  /// The report's per-item needs (from /lookups or /public/reports), or
  /// empty for an older report with only "General needs".
  late final List<Map> _reportNeeds = () {
    final rows = [
      for (final n in (widget.report['needs'] as List? ?? const []))
        if (n is Map) n,
    ];
    return rows.any((n) => n['item_id'] == null) ? <Map>[] : rows;
  }();

  /// What is still missing of a need: needed minus what donors pledged.
  static int _stillNeeded(Map n) => math.max(
    0,
    ((n['needed'] as num?) ?? 0).toInt() -
        ((n['pledged'] as num?) ?? 0).toInt(),
  );

  // Testing fix (UI, Wooind): what was typed survives a refresh or a closed
  // app. One draft per report; not used when changing an existing donation.
  late final FormDraft? _draft = _editing || _adding
      ? null
      : FormDraft('donate:${widget.report['id']}');

  Map<String, dynamic> _snapshot() => {
    'lines': [
      for (final l in lines)
        {
          'item_id': l.itemId,
          'size_id': l.sizeId,
          'size_unit': l.sizeUnit,
          'size_amount': l.sizeAmount.text,
          'per_pack': l.perPack,
          'per_pack_other': l.perPackOther.text,
          'packs': l.packs.text,
          'value': l.value.text,
          'other_name': l.otherName.text,
          'other_unit': l.otherUnit.text,
        },
    ],
    'handover': handover,
    'landmark': pickupLandmark.text,
    'address': pickupAddress.text,
    'notes': pickupNotes.text,
    'dates': [for (final d in sortedDates(pickupDates)) pickupDateIso(d)],
    'guest_name': guestName.text,
    'guest_phone': guestPhone.text,
  };

  void _saveDraft() => _draft?.save(_snapshot);

  void _restoreDraft(Map<String, dynamic> d) {
    final restored = <_Line>[];
    for (final m in d.maps('lines')) {
      final l = _Line()..itemId = m.strOrNull('item_id');
      l.otherName.text = m.str('other_name');
      l.otherUnit.text = m.str('other_unit');
      final info = _infoOf(l);
      // Items or sizes that are no longer in the list are left empty, so
      // every dropdown and chip gets a valid value.
      if (info == null && l.itemId != _otherItem) l.itemId = null;
      final size = m.strOrNull('size_id');
      if (size == _customSize ||
          (info?.sizes.any((z) => '${z['id']}' == size) ?? false)) {
        l.sizeId = size;
      }
      l
        ..sizeUnit = m.strOrNull('size_unit')
        ..perPack = m['per_pack'] is int ? m['per_pack'] as int : null;
      l.sizeAmount.text = m.str('size_amount');
      l.perPackOther.text = m.str('per_pack_other');
      l.packs.text = m.str('packs');
      l.value.text = m.str('value');
      restored.add(l);
    }
    final old = List<_Line>.of(lines);
    setState(() {
      if (restored.isNotEmpty) {
        lines
          ..clear()
          ..addAll(restored);
      }
      handover = d.str('handover') == 'Door to Door'
          ? 'Door to Door'
          : 'Drop Off';
      pickupLandmark.text = d.str('landmark');
      pickupAddress.text = d.str('address');
      pickupNotes.text = d.str('notes');
      // Dates that have passed are dropped when the calendar opens.
      pickupDates = pickupDatesOf(d['dates']);
      guestName.text = d.str('guest_name');
      guestPhone.text = d.str('guest_phone');
    });
    // The old fields are gone after this frame; then free their controllers.
    if (restored.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final l in old) {
          l.dispose();
        }
      });
    }
    AppToast.info(
      context,
      'We kept what you typed last time.',
      action: ToastAction('Start over', _startOver),
    );
  }

  /// "Start over": an empty form and no draft.
  void _startOver() {
    _draft?.clear();
    final old = List<_Line>.of(lines);
    setState(() {
      lines
        ..clear()
        ..add(_Line());
      handover = 'Drop Off';
      pickupLandmark.clear();
      pickupAddress.clear();
      pickupNotes.clear();
      pickupDates = {};
      guestName.clear();
      guestPhone.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final l in old) {
        l.dispose();
      }
    });
  }

  @override
  void initState() {
    super.initState();
    if (_adding) {
      // The new items keep the donation's handover and pickup.
      handover = '${widget.addTo!['handover_method'] ?? 'Drop Off'}';
    }
    if (_editing) {
      _fillFromEntry(widget.edit!);
      // A Door to Door entry being changed: check its landmark's area too.
      final p = picked;
      if (p != null && handover == 'Door to Door') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _checkCoverage(p);
        });
      }
    }
    _draft?.load().then((d) {
      if (d != null && mounted) _restoreDraft(d);
    });
    PickupRules.load().then((rules) {
      if (mounted) setState(() => pickupRules = rules);
    });
    if (api.loggedIn) {
      api.get('/donations/mine').then((r) {
        if (!mounted) return;
        String? a;
        if (r.ok) a = r.json['profile']?['address'] as String?;
        setState(() {
          savedAddress = (a ?? '').trim().isEmpty ? null : a;
          useSavedAddress = savedAddress != null && !_editing;
        });
      });
    }
  }

  @override
  void dispose() {
    _draft?.flush(_snapshot);
    for (final l in lines) {
      l.dispose();
    }
    _scroll.dispose();
    pickupLandmark.dispose();
    pickupAddress.dispose();
    pickupNotes.dispose();
    guestName.dispose();
    guestPhone.dispose();
    super.dispose();
  }

  String? _req(String? v) => (v ?? '').trim().isEmpty ? 'Required' : null;

  /// Same rule as the server: a Philippine mobile number, so CSWS can call
  /// or text about the pickup. Spaces and dashes are fine.
  static final _phMobile = RegExp(r'^(?:\+?63|0)9\d{9}$');
  String? _phone(String? v) {
    final digits = (v ?? '').replaceAll(RegExp(r'[\s\-().]'), '');
    if (digits.isEmpty) return 'Required';
    return _phMobile.hasMatch(digits)
        ? null
        : 'Enter an 11-digit mobile number, e.g. 09171234567';
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        content: Text(msg),
      ),
    );
  }

  Future<void> _choosePickupDates(FormFieldState<Set<DateTime>> field) async {
    final chosen = await pickPickupDates(
      context,
      pickupRules,
      current: pickupDates,
    );
    if (chosen == null || !mounted) return;
    setState(() => pickupDates = chosen);
    field.didChange(chosen);
  }

  /// The landmark is inside a Door to Door service area: the map check when
  /// it answered, otherwise the landmark text (same rule as the server).
  bool get _inServiceArea =>
      _covered ?? pickupRules.inServiceArea(pickupLandmark.text);

  /// The map found the landmark outside the service areas.
  bool get _outsideArea =>
      handover == 'Door to Door' && picked != null && _covered == false;

  /// Asks the map where the landmark's pin is, right after it is picked.
  Future<void> _checkCoverage(PickedAddress p) async {
    final seq = ++_coverageSeq;
    setState(() {
      _checkingCoverage = true;
      _covered = null;
    });
    final q = {
      'text': p.address,
      if (p.lat != null) 'lat': '${p.lat}',
      if (p.lng != null) 'lng': '${p.lng}',
    };
    final r = await api.get(
      '/donations/location/coverage?${Uri(queryParameters: q).query}',
    );
    if (!mounted || seq != _coverageSeq) return;
    setState(() {
      _checkingCoverage = false;
      if (r.ok && r.json is Map) {
        _covered = r.json['covered'] == true;
        _coveragePlace = r.json['place'] as String?;
      } else {
        // No answer from the server: the landmark text decides; the
        // server checks again on submit.
        _covered = pickupRules.inServiceArea(p.address);
        _coveragePlace = placeIn(p.address);
      }
    });
  }

  void _onLandmarkChanged(PickedAddress p) {
    final pinned = p.lat != null;
    picked = pinned ? p : null;
    if (pinned) {
      _checkCoverage(p);
    } else if (_covered != null || _checkingCoverage) {
      _coverageSeq++; // a check still running no longer applies
      setState(() {
        _covered = null;
        _checkingCoverage = false;
      });
    }
  }

  void _switchToDropOff() {
    setState(() => handover = 'Drop Off');
    _saveDraft();
    AppToast.info(
      context,
      'Switched to Drop Off. Thank you for understanding!',
    );
  }

  void _chooseAnotherLandmark() {
    _coverageSeq++;
    setState(() {
      pickupLandmark.clear();
      picked = null;
      _covered = null;
      _checkingCoverage = false;
    });
  }

  /// Faded and not tappable while the landmark is outside the areas.
  Widget _lockedWhenOutside(Widget child) => IgnorePointer(
    ignoring: _outsideArea,
    child: AnimatedOpacity(
      duration: Motion.fast,
      opacity: _outsideArea ? 0.4 : 1,
      child: child,
    ),
  );

  void _addItem() {
    setState(() => lines.add(_Line()));
    // Bring the new item into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        math.min(_scroll.offset + 360, _scroll.position.maxScrollExtent),
        duration: Motion.normal,
        curve: Motion.curve,
      );
    });
  }

  /// Oct 23: send only the new items; they join the same donation and QR.
  Future<void> _submitAdditions() async {
    final ref = '${widget.addTo!['batch_reference']}';
    setState(() => busy = true);
    final r = await api.post(
      '/donations/entries/${Uri.encodeComponent(ref)}/items',
      body: {
        'items': [for (final l in lines) l.toJson(_infoOf(l)!)],
      },
    );
    if (!mounted) return;
    setState(() => busy = false);
    if (!r.ok) {
      _snack(
        r.status == 0 ? 'Cannot reach the server' : r.errorText,
        error: true,
      );
      return;
    }
    _snack('Items added to $ref. Your QR code stays the same.');
    Navigator.of(context).pop(true);
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) {
      _snack('Please complete the fields marked in red.', error: true);
      return;
    }
    if (_adding) return _submitAdditions();
    final door = handover == 'Door to Door';
    final useSaved = door && useSavedAddress && savedAddress != null;
    final typedAddress = pickupAddress.text.trim();
    final landmarkText = pickupLandmark.text.trim();
    // Pin coordinates only when the box still holds the suggestion that was
    // tapped. If the donor edited the text afterwards, send the text only.
    final landmark = picked != null && picked!.address == landmarkText
        ? picked!
        : PickedAddress(landmarkText);
    setState(() => busy = true);
    final body = <String, dynamic>{
      if (!_editing) 'report_id': widget.report['id'],
      'handover_method': handover,
      if (door) ...{
        'pickup_address': useSaved ? savedAddress : typedAddress,
        if (landmarkText.isNotEmpty) ...{
          'pickup_landmark': landmarkText,
          'pickup_lat': landmark.lat,
          'pickup_lng': landmark.lng,
        },
        'pickup_dates': [
          for (final d in sortedDates(pickupDates)) pickupDateIso(d),
        ],
        // Servers not yet updated read only weekdays (1 = Monday) and ignore
        // pickup_dates; updated ones work the weekdays out from the dates.
        // Sending both keeps Door to Door working on either.
        'pickup_days': {for (final d in pickupDates) d.weekday}.toList()
          ..sort(),
        if (pickupNotes.text.trim().isNotEmpty)
          'pickup_notes': pickupNotes.text.trim(),
      },
      'items': [for (final l in lines) l.toJson(_infoOf(l)!)],
      if (!api.loggedIn && !_editing)
        'guest_donor': {
          'full_name': guestName.text.trim(),
          'contact_number': guestPhone.text.trim(),
        },
    };
    final r = _editing
        ? await api.put(
            '/donations/entries/${Uri.encodeComponent('${widget.edit!['batch_reference']}')}',
            body: body,
          )
        : await api.post('/donations/batch', body: body);
    if (!mounted) return;
    setState(() => busy = false);
    if (!r.ok || r.json is! Map) {
      _snack(
        r.status == 0 ? 'Cannot reach the server' : r.errorText,
        error: true,
      );
      return;
    }
    if (_editing) {
      _snack('Donation updated. Same QR code.');
      Navigator.of(context).pop(true);
      return;
    }
    _draft?.clear(); // submitted: the draft is no longer needed
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => DonationReceipt(
          batch: Map<String, dynamic>.from(r.json as Map),
          reportTitle:
              '${widget.report['disaster']} in ${widget.report['barangay']}',
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Sections
  // -------------------------------------------------------------------------

  Widget _reportSummary() {
    final r = widget.report;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final needs = '${r['assistance_needed'] ?? ''}'.trim();
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Icon(Icons.flood_outlined, color: cs.onPrimaryContainer),
          ),
          Gaps.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You are donating to',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                Gaps.v4,
                Text(
                  '${r['disaster']} in Barangay ${r['barangay']}',
                  style: t.titleMedium,
                ),
                // Per-item fulfillment: what nobody has pledged yet, so
                // donors give what is missing ("Water is covered").
                if (_reportNeeds.isNotEmpty) ...[
                  Gaps.v8,
                  Text(
                    'Still needed',
                    style: t.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  Gaps.v4,
                  // Highlighted like the needs on the report cards.
                  NeedChips([
                    for (final n in _reportNeeds)
                      _stillNeeded(n) > 0
                          ? '${n['item_name']}: ${_stillNeeded(n)} of '
                                '${n['needed']} ${n['unit'] ?? ''}'
                          : '${n['item_name']}: fully pledged',
                  ]),
                ] else if (needs.isNotEmpty) ...[
                  Gaps.v8,
                  NeedChips(NeedChips.split(needs)),
                ],
                if (r['priority_level'] != null) ...[
                  Gaps.v8,
                  PriorityChip('${r['priority_level']}'),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineCard(int i) {
    final l = lines[i];
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final items = widget.names.rows('items');
    final info = _infoOf(l);
    return Padding(
      key: ObjectKey(l),
      padding: const EdgeInsets.only(bottom: Space.sm),
      child: AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.inventory_2_outlined, size: 20, color: cs.primary),
                Gaps.h8,
                Expanded(child: Text('Item ${i + 1}', style: t.titleMedium)),
                if (lines.length > 1)
                  TextButton.icon(
                    onPressed: () {
                      setState(() => lines.removeAt(i));
                      _saveDraft();
                    },
                    icon: Icon(Icons.delete_outline, color: cs.error),
                    label: Text('Remove', style: TextStyle(color: cs.error)),
                  ),
              ],
            ),
            Gaps.v12,
            DropdownButtonFormField<String>(
              initialValue: l.itemId,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'What are you giving?',
                prefixIcon: Icon(Icons.category_outlined),
              ),
              items: [
                for (final it in items)
                  DropdownMenuItem(
                    value: '${it['id']}',
                    child: Text('${it['item_name'] ?? it['name']}'),
                  ),
                const DropdownMenuItem(
                  value: _otherItem,
                  child: Text('Something else…'),
                ),
              ],
              // Another item has other sizes: choose the size again.
              onChanged: (v) => setState(() {
                l
                  ..itemId = v
                  ..sizeId = null
                  ..sizeUnit = null;
              }),
              validator: (v) => v == null ? 'Choose an item' : null,
            ),
            if (l.itemId == _otherItem) ...[
              Gaps.v12,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: l.otherName,
                      decoration: const InputDecoration(
                        labelText: 'Item name',
                        hintText: 'e.g. Diapers',
                      ),
                      validator: _req,
                    ),
                  ),
                  Gaps.h12,
                  Expanded(
                    flex: 2,
                    // Testing fix 4.1 (Wooind): a unit from the list, so
                    // "sack" can't be a unit.
                    child: QuantityUnitField(
                      controller: l.otherUnit,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],
            if (l.itemId != null) _needNote(l),
            if (info != null) ...[
              if (!info.counted) ...[Gaps.v16, _sizeField(l, info)],
              Gaps.v16,
              _perPackField(l),
              Gaps.v12,
              TextFormField(
                controller: l.packs,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(6),
                ],
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l.perPackValue == 1
                      ? 'How many?'
                      : 'How many packs?',
                  suffixText: l.perPackValue == 1
                      ? (info.counted ? info.unit : null)
                      : 'packs',
                ),
                validator: (v) {
                  final n = int.tryParse(v?.trim() ?? '') ?? 0;
                  if (n <= 0) return 'Enter a number above 0';
                  if (n > _maxPacks) return 'Maximum is $_maxPacks';
                  final total = l.total(info);
                  if (total != null && total < 1) {
                    return 'That is less than 1 ${info.unit}. Add more, or '
                        'choose a bigger size.';
                  }
                  return null;
                },
              ),
              Gaps.v12,
              _totalNote(l, info),
            ],
            // Testing feedback (Oct 20): guests don't give an estimated value.
            if (api.loggedIn) ...[
              Gaps.v12,
              TextFormField(
                controller: l.value,
                keyboardType: TextInputType.number,
                // problema_napud 4.1: numbers only, with commas.
                inputFormatters: const [ThousandsFormatter()],
                decoration: const InputDecoration(
                  labelText: 'Estimated value (optional)',
                  prefixText: '₱ ',
                  hintText: '0',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Under the item: how much of it the report still needs, or that the
  /// report did not ask for it (it is still accepted, as additional goods,
  /// but does not count toward the report's progress).
  Widget _needNote(_Line l) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    String? text;
    if (l.itemId == _otherItem) {
      text = 'CSWS checks items that are not on the list when they arrive.';
    } else if (_reportNeeds.isNotEmpty) {
      final need = _reportNeeds
          .where((n) => '${n['item_id']}' == l.itemId)
          .firstOrNull;
      if (need == null) {
        text =
            'This report did not ask for this item. It is still welcome, '
            'but it does not count toward the report\'s progress.';
      } else {
        final still = _stillNeeded(need);
        text = still > 0
            ? 'This report still needs $still ${need['unit'] ?? ''}.'
            : 'This item is already fully pledged. Other needs of this '
                  'report may be more urgent.';
      }
    }
    if (text == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: Space.xs),
      child: Text(
        text,
        style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
  }

  /// Size of each item: the item's common sizes as chips, plus "Other size"
  /// (amount + unit). Items without sizes only have the typed size.
  Widget _sizeField(_Line l, _ItemInfo info) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return FormField<String>(
      key: ValueKey('size-${l.itemId}'),
      validator: (_) => info.sizes.isNotEmpty && l.sizeId == null
          ? 'Choose a size, or "Other size"'
          : null,
      builder: (field) {
        void pick(String id) {
          setState(() => l.sizeId = id);
          _saveDraft();
          field.didChange(id);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Size of each', style: t.labelLarge),
            if (info.sizes.isNotEmpty) ...[
              Gaps.v8,
              Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  for (final s in info.sizes)
                    ChoiceChip(
                      label: Text('${s['label']}'),
                      selected: l.sizeId == '${s['id']}',
                      onSelected: (_) => pick('${s['id']}'),
                    ),
                  ChoiceChip(
                    label: const Text('Other size'),
                    selected: l.sizeId == _customSize,
                    onSelected: (_) => pick(_customSize),
                  ),
                ],
              ),
              if (field.errorText != null) ...[
                Gaps.v4,
                Text(
                  field.errorText!,
                  style: t.bodySmall?.copyWith(color: cs.error),
                ),
              ],
            ],
            if (l.usesCustomSize(info)) ...[
              Gaps.v12,
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: l.sizeAmount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                        LengthLimitingTextInputFormatter(9),
                      ],
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Size',
                        hintText: 'e.g. 2',
                      ),
                      validator: (v) {
                        final a = double.tryParse(v?.trim() ?? '');
                        if (a == null || a <= 0) return 'Enter the size';
                        if (a > 100000) return 'Too big';
                        return null;
                      },
                    ),
                  ),
                  Gaps.h12,
                  Expanded(
                    flex: 2,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('unit-${l.itemId}-${info.unit}'),
                      initialValue: l.unitOf(info),
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: [
                        for (final u in info.sizeUnits)
                          DropdownMenuItem(value: u, child: Text(u)),
                      ],
                      onChanged: (v) => setState(() => l.sizeUnit = v),
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// Items per pack: Single, 6, 10, 12, 15, 16, 24, or a typed number.
  Widget _perPackField(_Line l) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Items per pack', style: t.labelLarge),
        Gaps.v4,
        Text(
          'Single = not in packs or boxes',
          style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        Gaps.v8,
        Wrap(
          spacing: Space.xs,
          runSpacing: Space.xs,
          children: [
            for (final n in _perPackChoices)
              ChoiceChip(
                label: Text(n == 1 ? 'Single' : '$n'),
                selected: l.perPack == n,
                onSelected: (_) {
                  setState(() => l.perPack = n);
                  _saveDraft();
                },
              ),
            ChoiceChip(
              label: const Text('Other'),
              selected: l.perPack == null,
              onSelected: (_) {
                setState(() => l.perPack = null);
                _saveDraft();
              },
            ),
          ],
        ),
        if (l.perPack == null) ...[
          Gaps.v12,
          TextFormField(
            controller: l.perPackOther,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(5),
            ],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(labelText: 'Items in each pack'),
            validator: (v) {
              final n = int.tryParse(v?.trim() ?? '') ?? 0;
              if (n <= 0) return 'Enter a number above 0';
              if (n > _maxPerPack) return 'Maximum is $_maxPerPack';
              return null;
            },
          ),
        ],
      ],
    );
  }

  /// "You're donating 72 L" with the breakdown, as the server will save it.
  Widget _totalNote(_Line l, _ItemInfo info) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final exact = l.exactTotal(info);
    final total = l.total(info);
    String fmt(double x) => x == x.roundToDouble() ? '${x.round()}' : '$x';
    return Container(
      padding: const EdgeInsets.all(Space.sm),
      decoration: BoxDecoration(
        color: cs.primaryContainer.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        children: [
          Icon(Icons.calculate_outlined, color: cs.primary),
          Gaps.h12,
          Expanded(
            child: total == null || exact == null
                ? Text(
                    'Fill in the size and how many to see the total.',
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "You're donating $total ${info.unit}",
                        style: t.titleMedium,
                      ),
                      // "10 cans" alone would only repeat the line above.
                      if (!info.counted || (l.perPackValue ?? 1) > 1)
                        Text(
                          exact == total
                              ? l.breakdown(info)
                              : '${l.breakdown(info)} = ${fmt(exact)} '
                                    '${info.unit}, counted as $total',
                          style: t.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// UC-D2 alt 7c: Door to Door pickup details.
  /// Order: Address (typed), Landmark (with suggestions), the dates the donor
  /// is home (calendar pop-out), notes for the pickup team.
  Widget _doorToDoorCard() {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Pickup details', style: t.titleMedium),
          Gaps.v4,
          Text(
            'CSWS will come to this address on one of the dates you are home.',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
          // Geofence (Oct 2026): where Door to Door is offered.
          if (pickupRules.cities.isNotEmpty)
            Text(
              'Door to Door is only in ${pickupRules.cities.join(', ')}.',
              style: t.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          Gaps.v12,
          ServiceAreaCard(pickupRules.serviceAreas),
          Gaps.v12,
          if (savedAddress != null) ...[
            RadioGroup<bool>(
              groupValue: useSavedAddress,
              onChanged: (v) => setState(() => useSavedAddress = v!),
              child: Column(
                children: [
                  RadioListTile<bool>(
                    value: true,
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Use my registered address'),
                    subtitle: Text(savedAddress!),
                  ),
                  const RadioListTile<bool>(
                    value: false,
                    contentPadding: EdgeInsets.zero,
                    title: Text('Use a different address'),
                  ),
                ],
              ),
            ),
            Gaps.v8,
          ],
          // 1. Address: plain typed text, no suggestions.
          if (savedAddress == null || !useSavedAddress) ...[
            TextFormField(
              controller: pickupAddress,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Address',
                hintText: 'House no., street, barangay, city',
                prefixIcon: Icon(Icons.home_outlined),
              ),
              validator: (v) {
                if (handover != 'Door to Door' ||
                    (savedAddress != null && useSavedAddress)) {
                  return null;
                }
                final text = (v ?? '').trim();
                if (text.isEmpty) return 'Enter the pickup address';
                if (text.length < 5) {
                  return 'Add the street and barangay, e.g. 135 Manalili St., Poblacion';
                }
                return null;
              },
            ),
            Gaps.v16,
          ],
          // 2. Landmark: suggestions appear as the donor types. Picking one
          //    also saves the map pin so CSWS can navigate.
          // Required, and picked from the suggestions (Oct 11): that gives
          // the pin on the CSWS pickup map, and suggestions only come from
          // the pickup area (Cebu province). Address + landmark must name a
          // Door to Door service area (Mandaue, northern Cebu City,
          // Consolacion, Lapu-Lapu); the server checks it again.
          AddressAutocompleteField(
            controller: pickupLandmark,
            label: 'Landmark',
            hint: 'Start typing a nearby landmark, e.g. church, school, store',
            icon: Icons.place_outlined,
            onChanged: _onLandmarkChanged,
            validator: (v) {
              if (handover != 'Door to Door') return null;
              final text = (v ?? '').trim();
              if (text.isEmpty) return 'Enter a landmark near your address';
              if (picked == null || picked!.address != text) {
                return 'Choose your landmark from the suggestions, so CSWS '
                    'can find you on the map';
              }
              if (!_inServiceArea) {
                return 'Outside the door-to-door coverage. Please choose '
                    'Drop Off.';
              }
              return null;
            },
          ),
          // The map check: a sorry and Drop Off when outside the areas.
          if (picked != null && (_checkingCoverage || _covered == true)) ...[
            Gaps.v8,
            CoverageStatusLine(checking: _checkingCoverage),
          ],
          if (_outsideArea) ...[
            Gaps.v12,
            OutOfAreaNotice(
              place: _coveragePlace,
              areas: pickupRules.serviceAreas,
              onDropOff: _switchToDropOff,
              onChangeLandmark: _chooseAnotherLandmark,
            ),
          ],
          Gaps.v16,
          // 3. Pickup dates: a calendar pop-out; tap one or more dates.
          // Locked (with notes) while the landmark is outside the areas.
          _lockedWhenOutside(
            FormField<Set<DateTime>>(
              validator: (_) {
                if (handover != 'Door to Door' || _outsideArea) return null;
                final ok = pickupDates.where(pickupRules.isPickupDate);
                if (ok.isEmpty) return 'Choose at least one date you are home';
                if (ok.length != pickupDates.length) {
                  return 'Some dates have passed. Tap to choose again.';
                }
                return null;
              },
              builder: (field) => InkWell(
                borderRadius: BorderRadius.circular(Radii.md),
                onTap: () => _choosePickupDates(field),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Available pickup dates',
                    prefixIcon: const Icon(Icons.event_available_outlined),
                    suffixIcon: const Icon(Icons.edit_calendar_outlined),
                    errorText: field.errorText,
                    helperText:
                        'Pickup hours are ${pickupHoursLabel(pickupRules)}',
                  ),
                  child: pickupDates.isEmpty
                      ? Text(
                          'Tap to choose the dates you are home',
                          style: t.bodyLarge?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        )
                      : PickupDateChips(sortedDates(pickupDates)),
                ),
              ),
            ),
          ),
          Gaps.v16,
          // 4. Notes for the pickup team.
          _lockedWhenOutside(
            TextFormField(
              controller: pickupNotes,
              maxLength: 300,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Notes for the pickup team (optional)',
                hintText: 'e.g. Blue gate beside the sari-sari store. Call when outside.',
                prefixIcon: Icon(Icons.sticky_note_2_outlined),
              ),
            ),
          ),
          Gaps.v4,
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 16, color: cs.onSurfaceVariant),
              Gaps.h8,
              Expanded(
                child: Text(
                  'Only CSWS staff see your address and number, and only to '
                  'arrange this pickup.',
                  style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _guestCard() {
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: guestName,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Full name',
              prefixIcon: Icon(Icons.person_outline),
            ),
            validator: _req,
          ),
          Gaps.v12,
          TextFormField(
            controller: guestPhone,
            keyboardType: TextInputType.phone,
            // Testing feedback (Oct 20): digits only, stops at 11.
            inputFormatters: phoneFormatters,
            decoration: const InputDecoration(
              labelText: 'Contact number',
              hintText: '09171234567',
              prefixIcon: Icon(Icons.phone_outlined),
            ),
            validator: _phone,
          ),
        ],
      ),
    );
  }

  Widget _submitBar() {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final side = _sidePadding(context);
    final count = lines.length;
    return Material(
      elevation: 8,
      color: cs.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(side, Space.sm, side, Space.sm),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$count item${count == 1 ? '' : 's'}',
                      style: t.titleMedium,
                    ),
                    Text(
                      handover,
                      style: t.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              Gaps.h12,
              AppButton(
                _adding
                    ? 'Add to donation'
                    : _editing
                    ? 'Save changes'
                    : 'Submit & get QR code',
                icon: _adding
                    ? Icons.add
                    : _editing
                    ? Icons.check
                    : Icons.qr_code_2,
                variant: AppButtonVariant.donate,
                loading: busy,
                onPressed: busy ? null : _submit,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final side = _sidePadding(context);
    final door = handover == 'Door to Door';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _adding
              ? 'Add items'
              : _editing
              ? 'Edit donation'
              : 'Donate goods',
        ),
      ),
      bottomNavigationBar: _submitBar(),
      body: Form(
        key: _form,
        onChanged: _saveDraft,
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          // SingleChildScrollView (not ListView) so every field stays built:
          // a ListView skips off-screen fields, and Form.validate() would
          // then miss them.
          child: SingleChildScrollView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(side, Space.md, side, Space.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _reportSummary(),

                if (_adding) _addingNote(),
                _StepHeader(
                  number: 1,
                  title: _adding
                      ? 'What are you adding?'
                      : 'What are you donating?',
                  subtitle: _adding
                      ? 'These items join your donation as a new batch.'
                      : 'Add every item you are giving. They all share one QR code.',
                ),
                for (var i = 0; i < lines.length; i++) _lineCard(i),
                AppButton(
                  'Add another item',
                  icon: Icons.add,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  onPressed: _addItem,
                ),

                // Adding to a donation: only the items. Handover, pickup
                // and donor details stay as they are.
                if (!_adding) ..._handoverSections(door),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "These items join DON-… · same QR code · same pickup".
  Widget _addingNote() {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final e = widget.addTo!;
    final door = e['handover_method'] == 'Door to Door';
    final when = e['pickup_days_label'];
    final caution = StatusColors.of('On Hold', Theme.of(context).brightness);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: Space.xs),
          padding: const EdgeInsets.all(Space.md),
          decoration: BoxDecoration(
            color: cs.primaryContainer.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.qr_code_2, color: cs.primary),
              Gaps.h12,
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Adding to ${e['batch_reference']}',
                      style: t.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Gaps.v4,
                    Text(
                      door
                          ? 'Same QR code. CSWS picks these up together with the '
                                'rest of your donation'
                                '${when == null ? '' : ' ($when)'}.'
                          : 'Same QR code. Bring these together with the rest '
                                'of your donation to the CSWS office.',
                      style: t.bodyMedium,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        // Oct 25: said before the donor starts, in amber (a caution, not
        // an error).
        Container(
          margin: const EdgeInsets.only(bottom: Space.sm),
          padding: const EdgeInsets.all(Space.sm),
          decoration: BoxDecoration(
            color: caution.bg,
            borderRadius: BorderRadius.circular(Radii.md),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 20, color: caution.fg),
              Gaps.h8,
              Expanded(
                child: Text.rich(
                  TextSpan(
                    style: t.bodyMedium,
                    children: const [
                      TextSpan(
                        text: 'Keep at least one item in your donation. ',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text:
                            'You can remove items later, but not all of '
                            'them. To stop the whole donation, cancel it '
                            'instead.',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _handoverSections(bool door) => [
    // 4.1: the items come first; the monetary donation info is
    // shown below them (adviser item 7 / UC-D2, display only).
    ReportDonationInfo(reportId: widget.report['id'] as int),

    const _StepHeader(number: 2, title: 'How will you hand it over?'),
    _ChoiceTile(
      icon: Icons.store_mall_directory_outlined,
      title: 'Drop Off',
      subtitle: 'Bring the goods to the CSWS office yourself.',
      selected: !door,
      onTap: () {
        setState(() => handover = 'Drop Off');
        _saveDraft();
      },
    ),
    Gaps.v8,
    _ChoiceTile(
      icon: Icons.local_shipping_outlined,
      title: 'Door to Door',
      subtitle: 'CSWS picks up the goods from your address.',
      selected: door,
      onTap: () {
        setState(() => handover = 'Door to Door');
        _saveDraft();
      },
    ),
    Gaps.v12,
    AnimatedSwitcher(
      duration: Motion.normal,
      child: door
          ? KeyedSubtree(key: const ValueKey('door'), child: _doorToDoorCard())
          : const DropOffCard(
              key: ValueKey('drop'),
              fallbackAddress: storageAddress,
              fallbackHours: storageHours,
            ),
    ),

    if (!api.loggedIn) ...[
      const _StepHeader(
        number: 3,
        title: 'Your details',
        subtitle: 'So CSWS can call or text you about this donation.',
      ),
      _guestCard(),
    ],
  ];
}

/// "① What are you donating?" numbered section title.
class _StepHeader extends StatelessWidget {
  final int number;
  final String title;
  final String? subtitle;
  const _StepHeader({required this.number, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: Space.lg, bottom: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: cs.primary,
            child: Text(
              '$number',
              style: t.labelLarge?.copyWith(color: cs.onPrimary),
            ),
          ),
          Gaps.h12,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(title, style: t.titleLarge),
                ),
                if (subtitle != null) ...[
                  Gaps.v4,
                  Text(
                    subtitle!,
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Large tappable option with a radio mark, used for the handover method.
class _ChoiceTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onTap;
  const _ChoiceTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected
            ? cs.primaryContainer.withValues(alpha: 0.45)
            : cs.surfaceContainerLowest,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
          side: BorderSide(
            color: selected ? cs.primary : cs.outlineVariant,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: Row(
              children: [
                Icon(
                  icon,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                  size: 28,
                ),
                Gaps.h16,
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: t.titleMedium),
                      Gaps.v4,
                      Text(
                        subtitle,
                        style: t.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Gaps.h8,
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? cs.primary : cs.outline,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// UC-D2 step 6 receipt: ONE QR code for the whole donation, with the list
/// of items it covers.
class DonationReceipt extends StatefulWidget {
  final Map<String, dynamic> batch;
  final String reportTitle;
  const DonationReceipt({
    super.key,
    required this.batch,
    required this.reportTitle,
  });

  @override
  State<DonationReceipt> createState() => _DonationReceiptState();
}

class _DonationReceiptState extends State<DonationReceipt> {
  final _scroll = ScrollController();

  // Testing fix 4.2: a guest has no account, so this screen is the only
  // place their QR code lives. They are warned, and cannot leave (Done,
  // back button, back gesture) until the QR image is saved. If the page is
  // refreshed or the app closed first, the landing page opens this receipt
  // again (see reopenUnsavedGuestReceipt).
  late final bool _guest = !api.loggedIn;
  bool _saved = false;
  bool _saveFailed = false; // then "I took a screenshot" is offered

  bool get _mayLeave => !_guest || _saved;

  @override
  void initState() {
    super.initState();
    if (_guest) {
      _rememberGuestReceipt(widget.batch, widget.reportTitle);
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onSaveResult(bool? result) {
    if (result == true) {
      setState(() => _saved = true);
      _forgetGuestReceipt();
    } else if (result == null) {
      setState(() => _saveFailed = true);
    }
  }

  Future<void> _leave() async {
    if (_mayLeave) {
      Navigator.of(context).pop();
      return;
    }
    final dropOff = widget.batch['handover_method'] == 'Drop Off';
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.qr_code_2, size: 32),
        title: const Text('Save your QR code first'),
        content: Text(
          'You donated as a guest, so this QR code is not kept in any '
          'account. CSWS needs it to '
          '${dropOff ? 'receive your goods at the office' : 'pick up your goods'}'
          '. Save the image before you leave this page.',
        ),
        actions: [
          if (_saveFailed)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 'screenshot'),
              child: const Text('I took a screenshot'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Stay'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(ctx, 'save'),
            icon: const Icon(Icons.download_outlined),
            label: const Text('Save QR image'),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'screenshot') {
      _forgetGuestReceipt();
      setState(() => _saved = true);
      Navigator.of(context).pop();
      return;
    }
    final qr = widget.batch['qr_image_base64'] as String?;
    if (qr == null) return;
    final result = await saveQrImage(
      context,
      qrBase64: qr,
      reference: '${widget.batch['batch_reference']}',
      handover: '${widget.batch['handover_method']}',
      forReport: widget.reportTitle,
    );
    if (!mounted) return;
    _onSaveResult(result);
    if (result == true) Navigator.of(context).pop();
  }

  /// Shown at the top of a guest's receipt until the QR is saved.
  Widget _guestWarning() {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: Space.md),
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: _saved ? cs.secondaryContainer : cs.errorContainer,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            _saved ? Icons.check_circle_outline : Icons.warning_amber_rounded,
            color: _saved ? cs.onSecondaryContainer : cs.onErrorContainer,
          ),
          Gaps.h12,
          Expanded(
            child: Text(
              _saved
                  ? 'QR image saved. You can leave this page.'
                  : 'Save your QR code now. You donated as a guest, so it is '
                        'not kept in any account, and you will need it to hand '
                        'over your goods.',
              style: t.bodyMedium?.copyWith(
                color: _saved ? cs.onSecondaryContainer : cs.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final batch = widget.batch;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final side = _sidePadding(context);
    final items = (batch['items'] as List? ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final dropOff = batch['handover_method'] == 'Drop Off';
    final qr = batch['qr_image_base64'] as String?;
    final pickupTime = formatPickupIso(batch['preferred_pickup_at']);
    final pickupDays = pickupDaysOf(batch['pickup_days']);
    final pickupDates = pickupDatesOf(batch['pickup_dates']);

    return PopScope(
      canPop: _mayLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Donation recorded')),
        bottomNavigationBar: Material(
          elevation: 8,
          color: cs.surface,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.fromLTRB(side, Space.sm, side, Space.sm),
              child: AppButton(
                _mayLeave ? 'Done' : 'Save QR to finish',
                expand: true,
                onPressed: _leave,
              ),
            ),
          ),
        ),
        body: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(side, Space.lg, side, Space.xl),
            children: [
              if (_guest) _guestWarning(),
              const Icon(
                Icons.check_circle,
                color: AppColors.success,
                size: 56,
              ),
              Gaps.v8,
              Text(
                'Thank you!',
                textAlign: TextAlign.center,
                style: t.headlineSmall,
              ),
              Gaps.v4,
              Text(
                'For ${widget.reportTitle}. '
                '${dropOff ? 'Show this QR code at the CSWS office.' : 'Show this QR code to the CSWS team when they pick up your goods.'}',
                textAlign: TextAlign.center,
                style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              Gaps.v16,
              AppCard(
                child: Column(
                  children: [
                    if (qr != null)
                      Container(
                        padding: const EdgeInsets.all(Space.sm),
                        decoration: BoxDecoration(
                          color: Colors.white, // QR codes need a light background to scan
                          borderRadius: BorderRadius.circular(Radii.md),
                        ),
                        child: Image.memory(
                          base64Decode(qr),
                          width: 220,
                          height: 220,
                        ),
                      ),
                    Gaps.v8,
                    SelectableText(
                      '${batch['batch_reference']}',
                      textAlign: TextAlign.center,
                      style: t.titleMedium?.copyWith(fontFamily: 'monospace'),
                    ),
                    Gaps.v8,
                    SaveQrButton(
                      qrBase64: qr,
                      reference: '${batch['batch_reference']}',
                      handover: '${batch['handover_method']}',
                      forReport: widget.reportTitle,
                      onResult: _onSaveResult,
                    ),
                    Gaps.v8,
                    Wrap(
                      spacing: Space.xs,
                      runSpacing: Space.xs,
                      alignment: WrapAlignment.center,
                      children: [
                        Chip(
                          avatar: Icon(
                            dropOff
                                ? Icons.store_mall_directory_outlined
                                : Icons.local_shipping_outlined,
                            size: 18,
                          ),
                          label: Text('${batch['handover_method']}'),
                        ),
                        StatusChip('${batch['status']}'),
                      ],
                    ),
                  ],
                ),
              ),
              // How long the donor has to hand it over (donation expiry).
              if (batch['expires_label'] != null) ...[
                Gaps.v12,
                ExpiryNote(batch),
              ],
              const SectionHeader('Items in this donation'),
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    for (var i = 0; i < items.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        leading: Icon(
                          Icons.inventory_2_outlined,
                          color: cs.primary,
                        ),
                        title: Text('${items[i]['item_name']}'),
                        subtitle: Text('${items[i]['packaging']}'),
                        trailing: Text(
                          '${items[i]['quantity']} ${items[i]['unit'] ?? ''}'
                              .trim(),
                          style: t.titleMedium,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (!dropOff && batch['pickup_address'] != null) ...[
                const SectionHeader('Pickup'),
                AppCard(
                  padding: EdgeInsets.zero,
                  child: Column(
                    children: [
                      if (batch['pickup_landmark'] != null) ...[
                        ListTile(
                          leading: Icon(
                            Icons.place_outlined,
                            color: cs.primary,
                          ),
                          title: const Text('Landmark'),
                          subtitle: Text('${batch['pickup_landmark']}'),
                        ),
                        const Divider(height: 1),
                      ],
                      ListTile(
                        leading: Icon(Icons.home_outlined, color: cs.primary),
                        title: const Text('Address'),
                        subtitle: Text('${batch['pickup_address']}'),
                      ),
                      if (pickupDays.isNotEmpty) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(
                            Icons.event_available_outlined,
                            color: cs.primary,
                          ),
                          title: Text(
                            pickupDates.isEmpty
                                ? 'Available pickup days'
                                : 'Available pickup dates',
                          ),
                          subtitle: Text(
                            '${pickupDates.isEmpty ? pickupDaysLabel(pickupDays) : sortedDates(pickupDates).map(pickupDateShort).join(' · ')}'
                            ' · pickup hours '
                            '${batch['pickup_hours'] ?? pickupHoursLabel(const PickupRules())}',
                          ),
                        ),
                      ] else if (pickupTime != null) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(
                            Icons.event_outlined,
                            color: cs.primary,
                          ),
                          title: const Text('Preferred pickup'),
                          subtitle: Text(pickupTime),
                        ),
                      ],
                      if (batch['pickup_notes'] != null) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: Icon(
                            Icons.sticky_note_2_outlined,
                            color: cs.primary,
                          ),
                          title: const Text('Notes for pickup'),
                          subtitle: Text('${batch['pickup_notes']}'),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              if (dropOff) ...[
                Gaps.v16,
                const DropOffCard(
                  fallbackAddress: storageAddress,
                  fallbackHours: storageHours,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Testing fix 4.2: a guest's unsaved QR survives a refresh or a closed app.
// The receipt is kept on this device until the guest saves the QR image;
// the landing page opens it again.
// ---------------------------------------------------------------------------
const _kGuestReceipt = 'guest_unsaved_receipt';

Future<void> _rememberGuestReceipt(Map batch, String reportTitle) async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kGuestReceipt,
      jsonEncode({'batch': batch, 'report_title': reportTitle}),
    );
  } catch (_) {}
}

Future<void> _forgetGuestReceipt() async {
  try {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kGuestReceipt);
  } catch (_) {}
}

/// Call from the landing page: if a guest left (refresh, closed app) before
/// saving their QR code, show that receipt again.
Future<void> reopenUnsavedGuestReceipt(BuildContext context) async {
  if (api.loggedIn) return;
  Map? saved;
  try {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kGuestReceipt);
    if (s != null && s.isNotEmpty) saved = jsonDecode(s) as Map?;
  } catch (_) {
    saved = null;
  }
  if (saved == null || saved['batch'] is! Map || !context.mounted) return;
  final batch = Map<String, dynamic>.from(saved['batch'] as Map);
  final title = '${saved['report_title'] ?? 'your donation'}';
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DonationReceipt(batch: batch, reportTitle: title),
    ),
  );
}
