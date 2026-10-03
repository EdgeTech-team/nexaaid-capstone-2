import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'location_picker.dart';
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
    'estimated_value': double.tryParse(value.text.trim()),
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
  const DonateScreen({super.key, required this.report, required this.names});

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
  final pickupAddress = TextEditingController(); // Door to Door address
  final pickupNotes = TextEditingController(); // notes for the pickup team
  PickedAddress? picked; // set when the donor taps a suggestion
  DateTime? preferredPickup; // Door to Door preferred date & time
  PickupRules pickupRules = const PickupRules();
  final guestName = TextEditingController();
  final guestPhone = TextEditingController();
  bool busy = false;

  @override
  void initState() {
    super.initState();
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
          useSavedAddress = savedAddress != null;
        });
      });
    }
  }

  @override
  void dispose() {
    for (final l in lines) {
      l.dispose();
    }
    _scroll.dispose();
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

  Future<void> _choosePickupTime(FormFieldState<DateTime> field) async {
    final chosen = await pickPreferredPickup(
      context,
      pickupRules,
      current: preferredPickup,
    );
    if (chosen == null || !mounted) return;
    setState(() => preferredPickup = chosen);
    field.didChange(chosen);
  }

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

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) {
      _snack('Please complete the fields marked in red.', error: true);
      return;
    }
    final door = handover == 'Door to Door';
    final useSaved = door && useSavedAddress && savedAddress != null;
    final typed = pickupAddress.text.trim();
    // Coordinates only when the box still holds the suggestion that was tapped.
    final address = picked != null && picked!.address == typed
        ? picked!
        : PickedAddress(typed);
    setState(() => busy = true);
    final body = <String, dynamic>{
      'report_id': widget.report['id'],
      'handover_method': handover,
      if (door) ...{
        ...(useSaved
            ? <String, dynamic>{'pickup_address': savedAddress}
            : address.toJson()),
        'preferred_pickup_at': preferredPickup!.toUtc().toIso8601String(),
        if (pickupNotes.text.trim().isNotEmpty)
          'pickup_landmark': pickupNotes.text.trim(),
      },
      'items': [for (final l in lines) l.toJson()],
      if (!api.loggedIn)
        'guest_donor': {
          'full_name': guestName.text.trim(),
          'contact_number': guestPhone.text.trim(),
        },
    };
    final r = await api.post('/donations/batch', body: body);
    if (!mounted) return;
    setState(() => busy = false);
    if (!r.ok || r.json is! Map) {
      _snack(
        r.status == 0 ? 'Cannot reach the server' : r.errorText,
        error: true,
      );
      return;
    }
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
                    onPressed: () => setState(() => lines.removeAt(i)),
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
                    child: TextFormField(
                      controller: l.otherUnit,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        hintText: 'pcs, bottles',
                      ),
                      validator: _req,
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
              decoration: const InputDecoration(
                labelText: 'Estimated value (optional)',
                prefixText: '₱ ',
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// UC-D2 alt 7c: confirm or enter the pickup address, and choose when.
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
            'CSWS will come to this address. They pick up ${pickupRules.label}.',
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
          if (savedAddress == null || !useSavedAddress) ...[
            AddressAutocompleteField(
              controller: pickupAddress,
              onChanged: (p) => picked = p.lat == null ? null : p,
              validator: (v) =>
                  handover == 'Door to Door' &&
                      (savedAddress == null || !useSavedAddress) &&
                      (v ?? '').trim().length < 5
                  ? 'Enter the pickup address'
                  : null,
            ),
            Gaps.v16,
          ],
          FormField<DateTime>(
            validator: (_) =>
                handover == 'Door to Door' && preferredPickup == null
                ? 'Choose a preferred pickup date and time'
                : null,
            builder: (field) => InkWell(
              borderRadius: BorderRadius.circular(Radii.md),
              onTap: () => _choosePickupTime(field),
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'Preferred pickup date & time',
                  prefixIcon: const Icon(Icons.event_outlined),
                  suffixIcon: const Icon(Icons.edit_calendar_outlined),
                  errorText: field.errorText,
                ),
                child: Text(
                  preferredPickup == null
                      ? 'Tap to choose'
                      : formatPickupTime(preferredPickup!),
                  style: preferredPickup == null
                      ? t.bodyLarge?.copyWith(color: cs.onSurfaceVariant)
                      : t.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          Gaps.v16,
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
                'Submit & get QR code',
                icon: Icons.qr_code_2,
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
      appBar: AppBar(title: const Text('Donate goods')),
      bottomNavigationBar: _submitBar(),
      body: Form(
        key: _form,
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

                const _StepHeader(
                  number: 2,
                  title: 'How will you hand it over?',
                ),
                _ChoiceTile(
                  icon: Icons.store_mall_directory_outlined,
                  title: 'Drop Off',
                  subtitle: 'Bring the goods to the CSWS office yourself.',
                  selected: !door,
                  onTap: () => setState(() => handover = 'Drop Off'),
                ),
                Gaps.v8,
                _ChoiceTile(
                  icon: Icons.local_shipping_outlined,
                  title: 'Door to Door',
                  subtitle: 'CSWS picks up the goods from your address.',
                  selected: door,
                  onTap: () => setState(() => handover = 'Door to Door'),
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

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
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

    return Scaffold(
      appBar: AppBar(title: const Text('Donation recorded')),
      bottomNavigationBar: Material(
        elevation: 8,
        color: cs.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.fromLTRB(side, Space.sm, side, Space.sm),
            child: AppButton(
              'Done',
              expand: true,
              onPressed: () => Navigator.pop(context),
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
            const Icon(Icons.check_circle, color: AppColors.success, size: 56),
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
                        color: Colors
                            .white, // QR codes need a light background to scan
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
                    ListTile(
                      leading: Icon(Icons.home_outlined, color: cs.primary),
                      title: const Text('Address'),
                      subtitle: Text('${batch['pickup_address']}'),
                    ),
                    if (pickupTime != null) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: Icon(Icons.event_outlined, color: cs.primary),
                        title: const Text('Preferred pickup'),
                        subtitle: Text(pickupTime),
                      ),
                    ],
                    if (batch['pickup_landmark'] != null) ...[
                      const Divider(height: 1),
                      ListTile(
                        leading: Icon(Icons.flag_outlined, color: cs.primary),
                        title: const Text('Notes for pickup'),
                        subtitle: Text('${batch['pickup_landmark']}'),
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
    );
  }
}
