// NF-003: a fake of the paged report endpoints for widget tests. It filters,
// sorts and pages like backend/app/services/report_paging.py (the backend
// test test_report_paging.py checks the real server against the same
// rules: the app's own sortAndFilterReports).
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mobile/ui/report_filters.dart';

ReportSort _sort(String? s) => switch (s) {
  'least_fulfilled' => ReportSort.leastFulfilled,
  'most_fulfilled' => ReportSort.mostFulfilled,
  'most_families' => ReportSort.mostFamilies,
  'newest' => ReportSort.newest,
  _ => ReportSort.urgent,
};

/// The answer for a report list or counts request, or null for any other
/// path. [mine] = report ids the signed-in user submitted.
http.Response? fakeReportResponse(
  Uri url,
  List<Map<String, dynamic>> rows, {
  Set<int> mine = const {},
}) {
  final q = url.queryParameters;
  final path = url.path;
  const lists = {'/reports/monitoring', '/reports/validated', '/reports/'};
  const counts = {'/reports/monitoring/counts', '/reports/validated/counts'};
  // GET /reports/{id}: one report (a notification's report, shown first).
  final one = RegExp(r'^/reports/(\d+)$').firstMatch(path);
  if (one != null) {
    final id = int.parse(one.group(1)!);
    final hit = rows.where((r) => r['report_id'] == id);
    return hit.isEmpty
        ? http.Response(jsonEncode({'detail': 'Report not found'}), 404)
        : http.Response(jsonEncode(hit.first), 200);
  }
  if (!lists.contains(path) && !counts.contains(path)) return null;

  var list = rows.where((r) {
    if (path.startsWith('/reports/validated') && r['status'] != 'Validated') {
      return false;
    }
    if (q['status'] != null && r['status'] != q['status']) return false;
    if (q['priority_level'] != null &&
        r['priority_level'] != q['priority_level']) {
      return false;
    }
    if (q['mine'] == 'true' && !mine.contains(r['report_id'])) return false;
    return true;
  }).toList();

  if (counts.contains(path)) {
    return http.Response(
      jsonEncode({
        for (final s in fulfillmentStates)
          s: list.where((r) => fulfillmentState(r) == s).length,
      }),
      200,
    );
  }

  // Old apps (no offset): the list as before, newest first, no total.
  if (q['offset'] == null) return http.Response(jsonEncode(list), 200);

  list = sortAndFilterReports(
    list,
    fulfillment: q['fulfillment'],
    sort: _sort(q['sort']),
  );
  if (q['mine'] == 'true') {
    bool editable(Map r) =>
        r['status'] == 'Pending' || r['status'] == 'Rejected';
    list = [...list.where(editable), ...list.where((r) => !editable(r))];
  }
  final offset = int.parse(q['offset']!);
  final limit = int.tryParse(q['limit'] ?? '') ?? 20;
  final page = list.skip(offset).take(limit).toList();
  return http.Response(
    jsonEncode(page),
    200,
    headers: {'x-total-count': '${list.length}'},
  );
}

/// NF-003: GET /public/reports/feed and /counts (donor Reports tab, guest
/// Donate page), filtered, sorted and paged like services/report_feed.py.
http.Response? fakeFeedResponse(
  Uri url,
  List<Map<String, dynamic>> rows, {
  bool loggedIn = true,
}) {
  if (!url.path.startsWith('/public/reports/feed')) return null;
  final q = url.queryParameters;
  double pct(Map r) => fulfillmentPercent(r) ?? 0;
  final done = q['done'];
  final inFeed = rows
      .where((r) => done == null || (pct(r) >= 100) == (done == 'true'))
      .toList();
  bool urgent(Map r) =>
      r['priority_level'] == 'Critical' || r['priority_level'] == 'High';
  if (url.path.endsWith('/counts')) {
    return http.Response(
      jsonEncode({'all': inFeed.length, 'urgent': inFeed.where(urgent).length}),
      200,
    );
  }
  final text = (q['q'] ?? '').toLowerCase();
  final list = inFeed.where((r) {
    final words = [
      r['barangay'],
      if (loggedIn) r['sitio'],
      r['disaster'],
      r['assistance_needed'],
      r['description'],
    ].join(' ').toLowerCase();
    final quick = switch (q['quick'] ?? 'all') {
      'urgent' => urgent(r),
      'needs' => pct(r) < 100,
      'fulfilled' => pct(r) >= 100,
      _ => true,
    };
    return (text.isEmpty || words.contains(text)) &&
        (q['barangay'] == null || r['barangay'] == q['barangay']) &&
        (q['disaster'] == null || r['disaster'] == q['disaster']) &&
        (q['priority'] == null || r['priority_level'] == q['priority']) &&
        quick;
  }).toList();
  final sorted = sortAndFilterReports(list, sort: _sort(q['sort']));
  final offset = int.tryParse(q['offset'] ?? '') ?? 0;
  final limit = int.tryParse(q['limit'] ?? '') ?? sorted.length;
  return http.Response(
    jsonEncode(sorted.skip(offset).take(limit).toList()),
    200,
    headers: {'x-total-count': '${sorted.length}'},
  );
}
