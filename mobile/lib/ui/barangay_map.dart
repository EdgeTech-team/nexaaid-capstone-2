import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import 'widgets.dart';

// ---------------------------------------------------------------------------
// Ivan (dashboard canvas): "Where your goods went" map for organizations.
//
// Barangays have no coordinates in the database, so each barangay is looked
// up by name with the same place search the pickup address field uses
// (GET /donations/location/autocomplete, OpenStreetMap data near Mandaue).
// Only a result whose name contains the barangay's name is used. Barangays
// that can't be found, or no network, fall back to [fallback] (the pin list).
// ---------------------------------------------------------------------------

const _osmTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const _appId = 'nexaaid.mandauecity.app';

/// One pin: a barangay, its color, and the text under it.
class BarangayPin {
  final String barangay;
  final Color color;
  final String caption;
  const BarangayPin(this.barangay, this.color, this.caption);
}

/// Found places, kept for the whole session so the map loads once.
final Map<String, LatLng?> _found = {};

Future<LatLng?> _locate(String barangay) async {
  final key = barangay.toLowerCase();
  if (_found.containsKey(key)) return _found[key];
  final q = Uri.encodeQueryComponent('Barangay $barangay, Mandaue City');
  final r = await api.get('/donations/location/autocomplete?q=$q');
  LatLng? hit;
  if (r.ok && r.json is List) {
    for (final e in (r.json as List).cast<Map>()) {
      final text = '${e['main'] ?? ''} ${e['address'] ?? ''}'.toLowerCase();
      final lat = (e['lat'] as num?)?.toDouble();
      final lng = (e['lng'] as num?)?.toDouble();
      if (text.contains(key) && lat != null && lng != null) {
        hit = LatLng(lat, lng);
        break;
      }
    }
  }
  // Remember only real answers; a network error is tried again next time.
  if (r.ok) _found[key] = hit;
  return hit;
}

class BarangayMap extends StatefulWidget {
  final List<BarangayPin> pins;
  final Widget fallback;
  const BarangayMap({super.key, required this.pins, required this.fallback});

  @override
  State<BarangayMap> createState() => _BarangayMapState();
}

class _BarangayMapState extends State<BarangayMap> {
  late final Future<List<(BarangayPin, LatLng)>> _points = _load();

  Future<List<(BarangayPin, LatLng)>> _load() async {
    final out = <(BarangayPin, LatLng)>[];
    for (final p in widget.pins) {
      final at = await _locate(p.barangay);
      if (at != null) out.add((p, at));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<(BarangayPin, LatLng)>>(
      future: _points,
      builder: (context, snap) {
        if (!snap.hasData) {
          return snap.hasError
              ? widget.fallback
              : const SkeletonCard(height: 220);
        }
        final points = snap.data!;
        if (points.isEmpty) return widget.fallback;
        return _map(context, points);
      },
    );
  }

  Widget _map(BuildContext context, List<(BarangayPin, LatLng)> points) {
    final t = Theme.of(context).textTheme;
    final lats = points.map((p) => p.$2.latitude);
    final lngs = points.map((p) => p.$2.longitude);
    final center = LatLng(
      (lats.reduce((a, b) => a < b ? a : b) +
              lats.reduce((a, b) => a > b ? a : b)) /
          2,
      (lngs.reduce((a, b) => a < b ? a : b) +
              lngs.reduce((a, b) => a > b ? a : b)) /
          2,
    );
    final names = points.map((p) => p.$1.barangay).join(', ');
    final missing = widget.pins.length - points.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: 'Map of Mandaue with pins on $names',
          child: ClipRRect(
            borderRadius: BorderRadius.circular(Radii.lg),
            child: SizedBox(
              height: 220,
              child: FlutterMap(
                options: MapOptions(
                  initialCenter: center,
                  initialZoom: points.length == 1 ? 15 : 13,
                  initialCameraFit: points.length > 1
                      ? CameraFit.coordinates(
                          coordinates: [for (final p in points) p.$2],
                          padding: const EdgeInsets.all(48),
                          maxZoom: 15,
                        )
                      : null,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag,
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
                      for (final (pin, at) in points)
                        Marker(
                          point: at,
                          width: 120,
                          height: 64,
                          alignment: Alignment.topCenter,
                          child: Tooltip(
                            message: '${pin.barangay}: ${pin.caption}',
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.location_on,
                                  size: 36,
                                  color: pin.color,
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(
                                      Radii.sm,
                                    ),
                                  ),
                                  child: Text(
                                    pin.barangay,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: t.labelSmall?.copyWith(
                                      color: AppColors.ink,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                  RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(
                        'OpenStreetMap contributors',
                        onTap: () => launchUrl(
                          Uri.parse('https://www.openstreetmap.org/copyright'),
                          mode: LaunchMode.externalApplication,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        if (missing > 0) ...[
          Gaps.v8,
          Text(
            '$missing ${missing == 1 ? 'barangay' : 'barangays'} couldn\'t be '
            'placed on the map.',
            style: t.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        Gaps.v12,
        widget.fallback,
      ],
    );
  }
}
