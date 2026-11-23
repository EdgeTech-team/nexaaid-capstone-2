// NF-003: a fake of GET /donations/mine/entries and /counts (My giving) for
// widget tests, using the app's own donor rules (filterEntries with donor:
// true), which the backend test test_paging_all_roles.py checks the real
// server against.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mobile/features/donations/donation_entries_view.dart';
import 'package:mobile/features/donations/my_giving.dart' show isOnTheWay, isWaiting;

const _sorts = {
  'newest': EntrySort.newest,
  'oldest': EntrySort.oldest,
  'most_items': EntrySort.mostItems,
  'fewest_items': EntrySort.fewestItems,
  'due_soonest': EntrySort.dueSoonest,
};

http.Response? fakeMyGivingResponse(
  Uri url,
  List<Map> entries, {
  List<Map> supported = const [],
}) {
  final q = url.queryParameters;
  if (url.path == '/donations/mine/entries/counts') {
    final reports = <int, String>{};
    for (final e in entries) {
      reports.putIfAbsent(e['report_id'] as int, () => entryReportLabel(e));
    }
    return http.Response(
      jsonEncode({
        'all': entries.length,
        'by_status': {
          for (final s in [...entryStatuses, 'On Hold'])
            s: entries.where((e) => entryHasStatus(e, s, donor: true)).length,
        },
        'reports': [
          for (final r in reports.entries)
            {'report_id': r.key, 'report_label': r.value},
        ],
        'summary': {
          'entries': entries.length,
          'waiting': entries.where(isWaiting).length,
          'on_the_way': entries.where(isOnTheWay).length,
        },
        'supported_reports': supported,
      }),
      200,
    );
  }
  if (url.path != '/donations/mine/entries') return null;
  final view = q['view'];
  final rows = filterEntries(
    entries
        .where(
          (e) =>
              view == null ||
              (view == 'waiting' ? isWaiting(e) : isOnTheWay(e)),
        )
        .toList(),
    search: q['q'] ?? '',
    status: q['status'],
    reportId: int.tryParse(q['report_id'] ?? ''),
    handover: q['handover_method'],
    sort: _sorts[q['sort']] ?? EntrySort.newest,
    donor: true,
  );
  final offset = int.tryParse(q['offset'] ?? '') ?? 0;
  final limit = int.tryParse(q['limit'] ?? '') ?? rows.length;
  return http.Response(
    jsonEncode(rows.skip(offset).take(limit).toList()),
    200,
    headers: {'x-total-count': '${rows.length}'},
  );
}
