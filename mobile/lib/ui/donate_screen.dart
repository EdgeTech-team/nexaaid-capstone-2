import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'donation_info.dart' show ReportDonationInfo;
import 'expiry_widgets.dart' show ExpiryNote;
import 'form_draft.dart';
import 'input_formatters.dart';
import 'location_picker.dart';
import 'pickup_days.dart';
import 'qr_save.dart';
import 'quantity_units.dart';
import 'widgets.dart';

// Fallback drop-off details, shown only when GET /donations/drop-off-info
// cannot be reached. The real values live in the backend .env
// (DROPOFF_NAME, DROPOFF_ADDRESS, DROPOFF_HOURS, DROPOFF_LAT, DROPOFF_LNG).
const storageAddress =
    'City of Mandaue City Social Services (CSWS), P.J. Burgos Street, Mandaue City';
const storageHours = 'Monday to Friday, 8:00 AM to 5:00 PM';

// Packaging options (manuscript 3.1: "packaging size, based on the
// available packaging options shown in the system"; data dictionary
// example "50kg sack").
const packagingOptions = [
  'Sack (50 kg)',
  'Sack (25 kg)',
  'Box',
  'Pack',
  'Plastic bag',
  'Bottle',
  'Gallon container',
  'Loose / no packaging',
  'Other',
];

const _otherItem = 'other';

/// Side padding that keeps content at a readable width on wide screens
/// (Chrome, tablets) and normal page padding on phones.
double _sidePadding(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  return math.max(Space.md, (w - Breakpoints.contentMax) / 2);
}

/// One item line on the donation form.
class _Line {
  String? itemId;
  String packaging = packagingOptions.first;
  final qty = TextEditingController();
  final value = TextEditingController();
  final otherName = TextEditingController();
  final otherUnit = TextEditingController();
  final otherPackaging = TextEditingController();

  Map<String, dynamic> toJson() => {
    if (itemId == _otherItem) ...{
      'other_item_name': otherName.text.trim(),
      'other_item_unit': otherUnit.text.trim(),
    } else
      'item_id': int.parse(itemId!),
    'packaging': packaging == 'Other' ? otherPackaging.text.trim() : packaging,
    'quantity': int.parse(qty.text.trim()),
    'estimated_value': ThousandsFormatter.parse(value.text),
  };

  void dispose() {
    qty.dispose();
    value.dispose();
    otherName.dispose();
    otherUnit.dispose();
    otherPackaging.dispose();
  }
}

/// UC-D2 step 5-6: physical donation form (one or more items). The whole
/// donation is saved in one request and gets ONE QR reference.
class DonateScreen extends StatefulWidget {
  final Map<String, dynamic> report;
  final Names names;

  /// Oct 11: the donor changes a donation still waiting (or declined). The
  /// form opens filled in; saving keeps the same QR reference.
  final Map? edit;
  const DonateScreen({
    super.key,
    required this.report,
    required this.names,
    this.edit,
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
  //   landmark  -> box with map suggestions (also gives the pin for CSWS)
  //   address   -> typed by the donor, no suggestions
  //   days      -> pickupDays: the days the donor is home (M / T / W ...)
  //   notes     -> free text for the pickup team
  final pickupLandmark = TextEditingController();
  final pickupAddress = TextEditingController();
  final pickupNotes = TextEditingController();
  PickedAddress? picked; // set when the donor taps a landmark suggestion
  Set<int> pickupDays = {}; // Door to Door: days the donor is home
  PickupRules pickupRules = const PickupRules();
  final guestName = TextEditingController();
  final guestPhone = TextEditingController();
  bool busy = false;

  bool get _editing => widget.edit != null;

  // Testing fix (UI): what was typed survives a refresh or a closed app.
  // One draft per report; not used when changing an existing donation.
  late final FormDraft? _draft = _editing
      ? null
      : FormDraft('donate:${widget.report['id']}');

  Map<String, dynamic> _snapshot() => {
    'lines': [
      for (final l in lines)
        {
          'item_id': l.itemId,
          'packaging': l.packaging,
          'qty': l.qty.text,
          'value': l.value.text,
          'other_name': l.otherName.text,
          'other_unit': l.otherUnit.text,
          'other_packaging': l.otherPackaging.text,
        },
    ],
    'handover': handover,
    'landmark': pickupLandmark.text,
    'address': pickupAddress.text,
    'notes': pickupNotes.text,
    'days': pickupDays.toList(),
    'guest_name': guestName.text,
    'guest_phone': guestPhone.text,
  };

  void _saveDraft() => _draft?.save(_snapshot);

  void _restoreDraft(Map<String, dynamic> d) {
    final ids = {for (final it in widget.names.rows('items')) '${it['id']}'};
    final restored = <_Line>[];
    for (final m in d.maps('lines')) {
      final id = m.strOrNull('item_id');
      final pack = m.str('packaging');
      final l = _Line()
        ..itemId = id != null && (ids.contains(id) || id == _otherItem)
            ? id
            : null
        ..packaging = packagingOptions.contains(pack)
            ? pack
            : packagingOptions.first;
      l.qty.text = m.str('qty');
      l.value.text = m.str('value');
      l.otherName.text = m.str('other_name');
      l.otherUnit.text = m.str('other_unit');
      l.otherPackaging.text = m.str('other_packaging');
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
      pickupDays = {
        for (final x in (d['days'] is List ? d['days'] as List : const []))
          if (x is int) x,
      };
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
      pickupDays = {};
      guestName.clear();
      guestPhone.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final l in old) {
        l.dispose();
      }
    });
  }

  /// Fill the form from the donation being changed.
  void _fillFromEntry(Map e) {
    lines
      ..forEach((l) => l.dispose())
      ..clear();
    for (final i in (e['items'] as List? ?? const []).cast<Map>()) {
      final l = _Line()
        ..itemId = '${i['item_id']}'
        ..qty.text = '${i['quantity']}';
      final pack = '${i['packaging'] ?? ''}';
      if (packagingOptions.contains(pack)) {
        l.packaging = pack;
      } else {
        l.packaging = 'Other';
        l.otherPackaging.text = pack;
      }
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
    pickupDays = pickupDaysOf(e['pickup_days']);
    final lat = (e['pickup_lat'] as num?)?.toDouble();
    final lng = (e['pickup_lng'] as num?)?.toDouble();
    picked = lat != null && lng != null
        ? PickedAddress(pickupLandmark.text, lat: lat, lng: lng)
        : null;
    useSavedAddress = false; // show the address that was given
  }

  @override
  void initState() {
    super.initState();
    if (_editing) _fillFromEntry(widget.edit!);
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
        : 'Enter a mobile number like 0917 123 4567';
  }

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        content: Text(msg),
      ),
    );
  }

  Future<void> _choosePickupDays(FormFieldState<Set<int>> field) async {
    final chosen = await pickPickupDays(
      context,
      pickupRules,
      current: pickupDays,
    );
    if (chosen == null || !mounted) return;
    setState(() => pickupDays = chosen);
    field.didChange(chosen);
  }

  void _addItem() {
    setState(() => lines.add(_Line()));
    _saveDraft();
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

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) {
      _snack('Please complete the fields marked in red.', error: true);
      return;
    }
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
        'pickup_days': (pickupDays.toList()..sort()),
        if (pickupNotes.text.trim().isNotEmpty)
          'pickup_notes': pickupNotes.text.trim(),
      },
      'items': [for (final l in lines) l.toJson()],
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
                if (needs.isNotEmpty) ...[
                  Gaps.v4,
                  Text(
                    'Needs: $needs',
                    style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
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
    String unit = '';
    for (final it in items) {
      if ('${it['id']}' == l.itemId) unit = '${it['unit'] ?? ''}';
    }
    if (l.itemId == _otherItem) unit = l.otherUnit.text.trim();
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
              onChanged: (v) => setState(() => l.itemId = v),
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
                        hintText: 'e.g. Bottled water',
                      ),
                      validator: _req,
                    ),
                  ),
                  Gaps.h12,
                  Expanded(
                    flex: 2,
                    // Testing fix 4.1: a unit from the list (no "sack":
                    // packaging is chosen below).
                    child: QuantityUnitField(
                      controller: l.otherUnit,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                ],
              ),
            ],
            Gaps.v12,
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: l.qty,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: 'Quantity',
                      suffixText: unit.isEmpty ? null : unit,
                    ),
                    validator: (v) => (int.tryParse(v?.trim() ?? '') ?? 0) > 0
                        ? null
                        : 'Enter a number above 0',
                  ),
                ),
                Gaps.h12,
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: l.packaging,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Packaging'),
                    items: [
                      for (final o in packagingOptions)
                        DropdownMenuItem(value: o, child: Text(o)),
                    ],
                    onChanged: (v) => setState(() => l.packaging = v!),
                  ),
                ),
              ],
            ),
            if (l.packaging == 'Other') ...[
              Gaps.v12,
              TextFormField(
                controller: l.otherPackaging,
                decoration: const InputDecoration(
                  labelText: 'Describe the packaging',
                ),
                validator: _req,
              ),
            ],
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
        ),
      ),
    );
  }

  /// UC-D2 alt 7c: Door to Door pickup details.
  /// Order: Landmark (with suggestions), Address (typed), the days the donor
  /// is home (pop-out with day buttons), notes for the pickup team.
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
            'CSWS will come to this address on one of the days you are home.',
            style: t.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
          ),
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
          // 1. Landmark: suggestions appear as the donor types. Picking one
          //    also saves the map pin so CSWS can navigate.
          // Required, and picked from the suggestions (Oct 11): that gives
          // the pin on the CSWS pickup map, and suggestions only come from
          // the pickup area (Cebu province).
          AddressAutocompleteField(
            controller: pickupLandmark,
            label: 'Landmark',
            hint: 'Start typing a nearby landmark, e.g. church, school, store',
            icon: Icons.place_outlined,
            onChanged: (p) => picked = p.lat == null ? null : p,
            validator: (v) {
              if (handover != 'Door to Door') return null;
              final text = (v ?? '').trim();
              if (text.isEmpty) return 'Enter a landmark near your address';
              if (picked == null || picked!.address != text) {
                return 'Choose your landmark from the suggestions, so CSWS '
                    'can find you on the map';
              }
              return null;
            },
          ),
          Gaps.v16,
          // 2. Address: plain typed text, no suggestions.
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
          // 3. Pickup days: a pop-out with M / T / W / Th / F buttons.
          FormField<Set<int>>(
            validator: (_) => handover == 'Door to Door' && pickupDays.isEmpty
                ? 'Choose at least one day you are home'
                : null,
            builder: (field) => InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => _choosePickupDays(field),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Available pickup days',
                  prefixIcon: const Icon(Icons.event_available_outlined),
                  suffixIcon: const Icon(Icons.edit_calendar_outlined),
                  errorText: field.errorText,
                  helperText:
                      'Pickup hours are ${pickupHoursLabel(pickupRules)}',
                ),
                child: pickupDays.isEmpty
                    ? Text(
                        'Tap to choose the days you are home',
                        style: t.bodyLarge?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      )
                    : Wrap(
                        spacing: Space.xxs,
                        runSpacing: Space.xxs,
                        children: [
                          for (final d in (pickupDays.toList()..sort()))
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: Space.xs + 2,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: cs.primary,
                                borderRadius: BorderRadius.circular(Radii.pill),
                              ),
                              child: Text(
                                pickupDayShort[d - 1],
                                style: t.labelLarge?.copyWith(
                                  color: cs.onPrimary,
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ),
          Gaps.v16,
          // 4. Notes for the pickup team.
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
            decoration: const InputDecoration(
              labelText: 'Contact number',
              hintText: '0917 123 4567',
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
                _editing ? 'Save changes' : 'Submit & get QR code',
                icon: _editing ? Icons.check : Icons.qr_code_2,
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
      appBar: AppBar(title: Text(_editing ? 'Edit donation' : 'Donate goods')),
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

                const _StepHeader(
                  number: 1,
                  title: 'What are you donating?',
                  subtitle: 'Add every item you are giving. They all share one QR code.',
                ),
                for (var i = 0; i < lines.length; i++) _lineCard(i),
                AppButton(
                  'Add another item',
                  icon: Icons.add,
                  variant: AppButtonVariant.secondary,
                  expand: true,
                  onPressed: _addItem,
                ),

                // 4.1: the items come first; the monetary donation info is
                // shown below them (adviser item 7 / UC-D2, display only).
                ReportDonationInfo(reportId: widget.report['id'] as int),

                const _StepHeader(
                  number: 2,
                  title: 'How will you hand it over?',
                ),
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
                      ? KeyedSubtree(
                          key: const ValueKey('door'),
                          child: _doorToDoorCard(),
                        )
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
                    subtitle:
                        'So CSWS can call or text you about this donation.',
                  ),
                  _guestCard(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
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
                          title: const Text('Available pickup days'),
                          subtitle: Text(
                            '${pickupDaysLabel(pickupDays)} · pickup hours '
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
