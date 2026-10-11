import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

// ---------------------------------------------------------------------------
// One-way pickup order for the Disaster Unit's pickup map (Oct 10 notes:
// "guided one way pick up ... according to what is nearby to one another").
//
// This is a suggested stop order, not road routing (manuscript Limitation 6:
// no route optimisation). It uses straight-line distance:
//   1. start at the CSWS office when its location is known, otherwise at
//      the stop farthest from the middle of the group (one end of it),
//   2. always go to the nearest stop not visited yet,
//   3. then untangle crossings (2-opt), keeping the start fixed and the
//      path open (the team does not return to the first stop).
// Fast enough for a pickup run (tens of stops) on any phone.
// ---------------------------------------------------------------------------

const _distance = Distance();

/// Straight-line distance in kilometres.
double kmBetween(LatLng a, LatLng b) =>
    _distance.as(LengthUnit.Meter, a, b) / 1000;

/// Indexes of [stops] in the suggested visiting order.
List<int> planOneWayRoute(List<LatLng> stops, {LatLng? start}) {
  final n = stops.length;
  if (n <= 1) return List.generate(n, (i) => i);

  // 1. Where to begin.
  LatLng from;
  final left = List.generate(n, (i) => i);
  final order = <int>[];
  if (start != null) {
    from = start;
  } else {
    final mid = LatLng(
      stops.map((p) => p.latitude).reduce((a, b) => a + b) / n,
      stops.map((p) => p.longitude).reduce((a, b) => a + b) / n,
    );
    var far = 0;
    for (var i = 1; i < n; i++) {
      if (kmBetween(stops[i], mid) > kmBetween(stops[far], mid)) far = i;
    }
    order.add(far);
    left.remove(far);
    from = stops[far];
  }

  // 2. Nearest next stop.
  while (left.isNotEmpty) {
    var best = left.first;
    for (final i in left) {
      if (kmBetween(from, stops[i]) < kmBetween(from, stops[best])) best = i;
    }
    order.add(best);
    left.remove(best);
    from = stops[best];
  }

  // 3. 2-opt on the open path. With a known start, the start is a fixed
  //    point before order[0]; otherwise order[0] stays first.
  LatLng at(int k) => k < 0 ? start! : stops[order[k]];
  final first = start != null ? 0 : 1;
  var improved = true;
  var rounds = 0;
  while (improved && rounds < 50) {
    improved = false;
    rounds++;
    for (var i = first; i < order.length - 1; i++) {
      for (var j = i + 1; j < order.length; j++) {
        final a = at(i - 1), b = at(i), c = at(j);
        final before =
            kmBetween(a, b) +
            (j + 1 < order.length ? kmBetween(c, at(j + 1)) : 0);
        final after =
            kmBetween(a, c) +
            (j + 1 < order.length ? kmBetween(b, at(j + 1)) : 0);
        if (after + 1e-9 < before) {
          final flipped = order.sublist(i, j + 1).reversed.toList();
          order.replaceRange(i, j + 1, flipped);
          improved = true;
        }
      }
    }
  }
  return order;
}

/// Total straight-line length of a path, in kilometres.
double pathKm(List<LatLng> points) {
  var km = 0.0;
  for (var i = 1; i < points.length; i++) {
    km += kmBetween(points[i - 1], points[i]);
  }
  return km;
}

/// "850 m" or "3.2 km".
String niceKm(double km) => km < 1
    ? '${(km * 1000 / 10).round() * 10} m'
    : '${km.toStringAsFixed(km < 10 ? 1 : 0)} km';

/// Map centre to use when there are no pins yet: Mandaue City.
const mandaueCenter = LatLng(10.3236, 123.9426);

/// Middle of a group of points (for an initial camera).
LatLng centerOf(List<LatLng> points) => points.isEmpty
    ? mandaueCenter
    : LatLng(
        points.map((p) => p.latitude).reduce(math.min) / 2 +
            points.map((p) => p.latitude).reduce(math.max) / 2,
        points.map((p) => p.longitude).reduce(math.min) / 2 +
            points.map((p) => p.longitude).reduce(math.max) / 2,
      );
