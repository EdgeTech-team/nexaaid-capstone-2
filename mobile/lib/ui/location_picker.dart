import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import 'widgets.dart';

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// OpenStreetMap tiles: free, no API key. The OSM tile policy asks every
/// app to identify itself, which userAgentPackageName does.
const _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _appId = 'nexaaid.mandauecity.app';

/// Opens directions to a point in Google Maps (app if installed, otherwise
/// the browser). Needs no API key.
Future<void> openDirections(
  BuildContext context,
  double lat,
  double lng,
) async {
  final uri = Uri.parse(
    'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng',
  );
  var opened = false;
  try {
    opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Could not open a maps app')));
  }
}

/// Philippine time is UTC+8 all year (no daylight saving). Pickup times are
/// always shown and chosen in Philippine time, whatever the phone is set to.
const _phOffset = Duration(hours: 8);
const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Mon, Oct 5, 2026 · 10:00 AM" in Philippine time.
String formatPickupTime(DateTime instant) {
  final t = instant.toUtc().add(_phOffset);
  final hour = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final minute = t.minute.toString().padLeft(2, '0');
  final ampm = t.hour < 12 ? 'AM' : 'PM';
  return '${_weekdays[t.weekday - 1]}, ${_months[t.month - 1]} ${t.day}, '
      '${t.year} · $hour:$minute $ampm';
}

/// Same, from the ISO text the server sends (null-safe).
String? formatPickupIso(Object? iso) {
  if (iso == null) return null;
  final parsed = DateTime.tryParse('$iso');
  return parsed == null ? null : formatPickupTime(parsed);
}

// ---------------------------------------------------------------------------
// Door to Door: address with suggestions (UC-D2 alt 7c)
// ---------------------------------------------------------------------------

/// A Door to Door pickup address. lat/lng are set when the donor picked a
/// suggestion (lets CSWS navigate), null when they typed it themselves.
class PickedAddress {
  final String address;
  final double? lat;
  final double? lng;
  const PickedAddress(this.address, {this.lat, this.lng});

  Map<String, dynamic> toJson() => {
    'pickup_address': address,
    'pickup_lat': lat,
    'pickup_lng': lng,
  };
}

/// One address box. As the donor types, matching addresses appear below it
/// (OpenStreetMap, through the backend). Tapping one fills the box. The
/// donor can also just type the full address.
class AddressAutocompleteField extends StatefulWidget {
  final TextEditingController controller;
  final ValueChanged<PickedAddress> onChanged;
  final FormFieldValidator<String>? validator;
  const AddressAutocompleteField({
    super.key,
    required this.controller,
    required this.onChanged,
    this.validator,
  });

  @override
  State<AddressAutocompleteField> createState() =>
      _AddressAutocompleteFieldState();
}

class _AddressAutocompleteFieldState extends State<AddressAutocompleteField> {
  List<Map<String, dynamic>> _suggestions = [];
  Timer? _debounce;
  bool _loading = false;
  bool _picked = false;
  String? _hint;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _onTyped(String value) {
    // Typing after choosing a suggestion means the pin no longer matches.
    _picked = false;
    widget.onChanged(PickedAddress(value.trim()));
    _debounce?.cancel();
    final q = value.trim();
    if (q.length < 3) {
      setState(() {
        _suggestions = [];
        _hint = null;
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 450), () => _search(q));
  }

  Future<void> _search(String q) async {
    final r = await api.get(
      '/donations/location/autocomplete?q=${Uri.encodeQueryComponent(q)}',
    );
    if (!mounted || widget.controller.text.trim() != q) return;
    setState(() {
      _loading = false;
      if (r.ok && r.json is List) {
        _suggestions = (r.json as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .take(6)
            .toList();
        _hint = _suggestions.isEmpty
            ? 'No suggestions. You can type the full address yourself.'
            : null;
      } else {
        _suggestions = [];
        _hint =
            'Suggestions are unavailable right now. '
            'Type the full address yourself.';
      }
    });
  }

  void _choose(Map<String, dynamic> s) {
    final address = '${s['address'] ?? s['main']}';
    widget.controller.text = address;
    widget.controller.selection = TextSelection.collapsed(
      offset: address.length,
    );
    FocusScope.of(context).unfocus();
    setState(() {
      _suggestions = [];
      _hint = null;
      _picked = true;
    });
    widget.onChanged(
      PickedAddress(
        address,
        lat: (s['lat'] as num?)?.toDouble(),
        lng: (s['lng'] as num?)?.toDouble(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.controller,
          onChanged: _onTyped,
          validator: widget.validator,
          minLines: 1,
          maxLines: 3,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Pickup address',
            hintText: 'Start typing: house no., street, barangay',
            prefixIcon: const Icon(Icons.home_outlined),
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : _picked
                ? const Icon(Icons.check_circle, color: Color(0xFF2E7D32))
                : null,
          ),
        ),
        if (_suggestions.isNotEmpty)
          Card(
            margin: const EdgeInsets.only(top: 4),
            elevation: 3,
            child: Column(
              children: [
                for (var i = 0; i < _suggestions.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined),
                    title: Text('${_suggestions[i]['main']}'),
                    subtitle: '${_suggestions[i]['secondary']}'.isEmpty
                        ? null
                        : Text('${_suggestions[i]['secondary']}'),
                    onTap: () => _choose(_suggestions[i]),
                  ),
                ],
              ],
            ),
          ),
        if (_hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 4),
            child: Text(
              _hint!,
              style: const TextStyle(fontSize: 12, color: Brand.muted),
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Door to Door: preferred pickup date and time (UC-D2 alt 7c)
// ---------------------------------------------------------------------------

/// When CSWS does pickups. Loaded from GET /donations/pickup-rules (set in
/// the backend .env); the defaults are used if the server can't be reached.
class PickupRules {
  final Set<int> days; // 1 = Monday ... 7 = Sunday
  final int startHour;
  final int endHour;
  final int minLeadHours;
  final int maxDaysAhead;
  final String label;

  const PickupRules({
    this.days = const {1, 2, 3, 4, 5},
    this.startHour = 8,
    this.endHour = 17,
    this.minLeadHours = 1,
    this.maxDaysAhead = 30,
    this.label = 'Monday to Friday, 8:00 AM to 5:00 PM',
  });

  factory PickupRules.fromJson(Map<String, dynamic> j) => PickupRules(
    days: {
      for (final d in (j['days'] as List? ?? const [])) (d as num).toInt(),
    },
    startHour: (j['start_hour'] as num?)?.toInt() ?? 8,
    endHour: (j['end_hour'] as num?)?.toInt() ?? 17,
    minLeadHours: (j['min_lead_hours'] as num?)?.toInt() ?? 1,
    maxDaysAhead: (j['max_days_ahead'] as num?)?.toInt() ?? 30,
    label: '${j['label'] ?? 'Monday to Friday, 8:00 AM to 5:00 PM'}',
  );

  static Future<PickupRules> load() async {
    final r = await api.get('/donations/pickup-rules');
    if (r.ok && r.json is Map) {
      final rules = PickupRules.fromJson(
        Map<String, dynamic>.from(r.json as Map),
      );
      if (rules.days.isNotEmpty) return rules;
    }
    return const PickupRules();
  }

  /// "Now" as a Philippine wall-clock time.
  static DateTime phNow() => DateTime.now().toUtc().add(_phOffset);

  /// The instant for a Philippine date + time.
  static DateTime instantOf(DateTime phDay, TimeOfDay time) => DateTime.utc(
    phDay.year,
    phDay.month,
    phDay.day,
    time.hour,
    time.minute,
  ).subtract(_phOffset);

  /// Why this choice is not allowed, or null if it is fine.
  String? problemWith(DateTime instant) {
    final now = DateTime.now().toUtc();
    if (instant.isBefore(now.add(Duration(hours: minLeadHours)))) {
      return 'Choose a time at least $minLeadHours hour(s) from now.';
    }
    if (instant.isAfter(now.add(Duration(days: maxDaysAhead)))) {
      return 'Choose a date within $maxDaysAhead days.';
    }
    final ph = instant.toUtc().add(_phOffset);
    if (!days.contains(ph.weekday)) return 'CSWS does pickups only on: $label.';
    final minutes = ph.hour * 60 + ph.minute;
    if (minutes < startHour * 60 || minutes > endHour * 60) {
      return 'Choose a time within: $label.';
    }
    return null;
  }

  /// First day the date picker may open on (must be an allowed day).
  DateTime firstSelectableDay() {
    final now = phNow();
    var day = DateTime(now.year, now.month, now.day);
    final latestToday = DateTime(
      now.year,
      now.month,
      now.day,
      endHour,
    ).subtract(Duration(hours: minLeadHours));
    if (now.isAfter(latestToday)) day = day.add(const Duration(days: 1));
    for (var i = 0; i < 14 && !days.contains(day.weekday); i++) {
      day = day.add(const Duration(days: 1));
    }
    return day;
  }
}

/// Opens a date picker, then a time picker. Returns the chosen instant, or
/// null if the donor cancelled. Shows a message if the choice isn't allowed.
Future<DateTime?> pickPreferredPickup(
  BuildContext context,
  PickupRules rules, {
  DateTime? current,
}) async {
  final first = rules.firstSelectableDay();
  final today = PickupRules.phNow();
  final last = DateTime(
    today.year,
    today.month,
    today.day,
  ).add(Duration(days: rules.maxDaysAhead));
  var initial = first;
  if (current != null) {
    final c = current.toUtc().add(_phOffset);
    final cDay = DateTime(c.year, c.month, c.day);
    if (!cDay.isBefore(first) &&
        !cDay.isAfter(last) &&
        rules.days.contains(cDay.weekday)) {
      initial = cDay;
    }
  }
  final day = await showDatePicker(
    context: context,
    helpText: 'Preferred pickup date',
    initialDate: initial,
    firstDate: first,
    lastDate: last,
    selectableDayPredicate: (d) => rules.days.contains(d.weekday),
  );
  if (day == null || !context.mounted) return null;

  final now = PickupRules.phNow();
  var suggested = TimeOfDay(hour: rules.startHour + 1, minute: 0);
  if (day.year == now.year && day.month == now.month && day.day == now.day) {
    final h = (now.hour + rules.minLeadHours + 1).clamp(
      rules.startHour,
      rules.endHour,
    );
    suggested = TimeOfDay(hour: h, minute: 0);
  }
  final time = await showTimePicker(
    context: context,
    helpText: 'Preferred pickup time (${rules.label})',
    initialTime: suggested,
  );
  if (time == null || !context.mounted) return null;

  final instant = PickupRules.instantOf(day, time);
  final problem = rules.problemWith(instant);
  if (problem != null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFC62828),
        content: Text(problem),
      ),
    );
    return null;
  }
  return instant;
}

// ---------------------------------------------------------------------------
// Drop Off: where to bring the goods (UC-D2 alt 7b)
// ---------------------------------------------------------------------------

/// Map, address, hours and directions for the drop-off office. Details come
/// from GET /donations/drop-off-info; the fallbacks are used only when the
/// server cannot be reached.
class DropOffCard extends StatefulWidget {
  final String fallbackAddress;
  final String fallbackHours;
  const DropOffCard({
    super.key,
    required this.fallbackAddress,
    required this.fallbackHours,
  });

  @override
  State<DropOffCard> createState() => _DropOffCardState();
}

class _DropOffCardState extends State<DropOffCard> {
  late final Future<ApiResult> _info = api.get('/donations/drop-off-info');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ApiResult>(
      future: _info,
      builder: (context, snap) {
        final r = snap.data;
        final j = r != null && r.ok && r.json is Map
            ? Map<String, dynamic>.from(r.json as Map)
            : <String, dynamic>{};
        final name =
            '${j['name'] ?? 'City of Mandaue City Social Services (CSWS)'}';
        final address = '${j['address'] ?? widget.fallbackAddress}';
        final hours = '${j['hours'] ?? widget.fallbackHours}';
        final note =
            '${j['instructions'] ?? 'Bring the goods and show your QR code. '
                    'CSWS will count what arrives and record the actual quantity.'}';
        final lat = (j['lat'] as num?)?.toDouble();
        final lng = (j['lng'] as num?)?.toDouble();
        final pos = lat != null && lng != null ? LatLng(lat, lng) : null;

        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Brand.pinkSoft.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Drop-off location',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (snap.connectionState != ConnectionState.done)
                const LinearProgressIndicator(),
              if (pos != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    height: 180,
                    child: FlutterMap(
                      options: MapOptions(
                        initialCenter: pos,
                        initialZoom: 16,
                        interactionOptions: const InteractionOptions(
                          flags: InteractiveFlag.none,
                        ),
                      ),
                      children: [
                        TileLayer(
                          urlTemplate: _osmTileUrl,
                          userAgentPackageName: _appId,
                          maxZoom: 19,
                        ),
                        MarkerLayer(
                          markers: [
                            Marker(
                              point: pos,
                              width: 40,
                              height: 40,
                              alignment: Alignment.topCenter,
                              child: const Icon(
                                Icons.location_pin,
                                size: 40,
                                color: Color(0xFFC62828),
                              ),
                            ),
                          ],
                        ),
                        RichAttributionWidget(
                          attributions: [
                            TextSourceAttribution(
                              'OpenStreetMap contributors',
                              onTap: () => launchUrl(
                                Uri.parse(
                                  'https://www.openstreetmap.org/copyright',
                                ),
                                mode: LaunchMode.externalApplication,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.place_outlined, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text('$name\n$address')),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.schedule, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(hours)),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                note,
                style: const TextStyle(fontSize: 12, color: Brand.muted),
              ),
              if (pos != null) ...[
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () =>
                      openDirections(context, pos.latitude, pos.longitude),
                  icon: const Icon(Icons.directions),
                  label: const Text('Get directions'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
