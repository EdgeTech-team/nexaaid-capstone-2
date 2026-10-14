// Concerns2.txt 5.2: receive and record goods by donation entry, filter and
// sort by report and barangay (UC-CM1, Table 34).
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/ui/receive_filters.dart';

final now = DateTime(2026, 10, 9, 12);

Map entry(
  String ref,
  String created, {
  String handover = 'Drop Off',
  String item = 'Rice',
  String? donor,
}) => {
  'batch_reference': ref,
  'created_at': created,
  'handover_method': handover,
  'donor': donor,
  'items': [
    {'donation_id': ref.hashCode, 'item_name': item},
  ],
};

final pending = <Map>[
  {
    'report_id': 21,
    'report_label': '#21 Typhoon - Banilad',
    'entries': [
      entry('DON-A', '2026-10-05T09:00:00'),
      entry(
        'DON-B',
        '2026-10-09T08:00:00',
        handover: 'Door to Door',
        donor: 'Maria Santos',
      ),
    ],
  },
  {
    'report_id': 26,
    'report_label': '#26 Typhoon - Casili',
    'entries': [entry('DON-C', '2026-10-08T10:00:00', item: 'Noodles')],
  },
  {
    'report_id': 19,
    'report_label': '#19 Fire - Paknaan',
    'entries': [entry('DON-D', '2026-10-01T10:00:00')],
  },
];

const priorities = {21: 'Medium', 26: 'Critical', 19: 'High'};

void main() {
  test('Barangay comes from the report label', () {
    expect(barangayOf({'report_label': '#21 Typhoon - Banilad'}), 'Banilad');
    expect(
      barangayOf({
        'report': {'label': 'Typhoon in Casili'},
      }),
      'Casili',
    );
    expect(barangayOf({'report_id': 5}), 'Unknown barangay');
  });

  test('Filter by barangay keeps only that barangay', () {
    final r = filterPendingReports(
      pending,
      const ReceiveFilters(barangay: 'Casili'),
      now: now,
    );
    expect(r.map((x) => x['report_id']), [26]);
  });

  test('Filter by report', () {
    final r = filterPendingReports(
      pending,
      const ReceiveFilters(reportId: 21),
      now: now,
    );
    expect(r.single['report_id'], 21);
    expect((r.single['entries'] as List).length, 2);
  });

  test('Report choices narrow to the chosen barangay', () {
    expect(reportOptions(pending, 'Banilad').keys, [21]);
    expect(reportOptions(pending, null).keys, [26, 21, 19]);
    expect(barangayOptions(pending), ['Banilad', 'Casili', 'Paknaan']);
  });

  test('Most urgent: Critical first, then High, then Medium', () {
    final r = filterPendingReports(
      pending,
      const ReceiveFilters(),
      priorities: priorities,
      now: now,
    );
    expect(r.map((x) => x['report_id']), [26, 19, 21]);
    expect(r.first['priority_level'], 'Critical');
  });

  test('Waiting longest: oldest entry first, entries oldest first', () {
    final r = filterPendingReports(
      pending,
      const ReceiveFilters(sort: ReceiveSort.waitingLongest),
      now: now,
    );
    expect(r.map((x) => x['report_id']), [19, 21, 26]);
    expect((r[1]['entries'] as List).first['batch_reference'], 'DON-A');
  });

  test('Newest and Barangay A-Z', () {
    final n = filterPendingReports(
      pending,
      const ReceiveFilters(sort: ReceiveSort.newest),
      now: now,
    );
    expect(n.first['report_id'], 21); // DON-B is the newest entry
    expect((n.first['entries'] as List).first['batch_reference'], 'DON-B');
    final a = filterPendingReports(
      pending,
      const ReceiveFilters(sort: ReceiveSort.barangayAz),
      now: now,
    );
    expect(a.map(barangayOf), ['Banilad', 'Casili', 'Paknaan']);
  });

  test('Search finds QR, donor or item; handover and date filters', () {
    expect(
      filterPendingReports(
        pending,
        const ReceiveFilters(),
        search: 'noodles',
        now: now,
      ).single['report_id'],
      26,
    );
    expect(
      filterPendingReports(
        pending,
        const ReceiveFilters(),
        search: 'maria',
        now: now,
      ).single['report_id'],
      21,
    );
    final d2d = filterPendingReports(
      pending,
      const ReceiveFilters(handover: 'Door to Door'),
      now: now,
    );
    expect((d2d.single['entries'] as List).single['batch_reference'], 'DON-B');
    final today = filterPendingReports(
      pending,
      const ReceiveFilters(when: ReceiveWhen.today),
      now: now,
    );
    expect(
      (today.single['entries'] as List).single['batch_reference'],
      'DON-B',
    );
  });

  test('Waiting text', () {
    expect(waitingText('2026-10-09T01:00:00', now: now), 'Waiting since today');
    expect(waitingText('2026-10-08T23:00:00', now: now), 'Waiting 1 day');
    expect(waitingText('2026-10-05T09:00:00', now: now), 'Waiting 4 days');
    expect(waitingText(null, now: now), '');
  });

  test('Received tab: skips Pending, filters status and barangay', () {
    final records = <Map>[
      {
        ...entry('DON-A', '2026-10-05T09:00:00'),
        'status': 'Pending',
        'report_id': 21,
        'report_label': '#21 Typhoon - Banilad',
      },
      {
        ...entry('DON-E', '2026-10-06T09:00:00'),
        'status': 'Received',
        'report_id': 21,
        'report_label': '#21 Typhoon - Banilad',
      },
      {
        ...entry('DON-F', '2026-10-07T09:00:00'),
        'status': 'Partly Received',
        'report_id': 26,
        'report_label': '#26 Typhoon - Casili',
      },
    ];
    expect(
      filterReceivedEntries(records, const ReceiveFilters(), now: now).length,
      2,
    );
    expect(
      filterReceivedEntries(
        records,
        const ReceiveFilters(status: 'Partly Received'),
        now: now,
      ).single['batch_reference'],
      'DON-F',
    );
    expect(
      filterReceivedEntries(
        records,
        const ReceiveFilters(barangay: 'Banilad'),
        now: now,
      ).single['batch_reference'],
      'DON-E',
    );
  });

  test('Inventory rows filtered by barangay and report', () {
    final rows = <Map>[
      {
        'report_id': 21,
        'report_label': '#21 Typhoon - Banilad',
        'item_name': 'Rice',
      },
      {
        'report_id': 26,
        'report_label': '#26 Typhoon - Casili',
        'item_name': 'Noodles',
      },
    ];
    expect(
      filterInventoryRows(
        rows,
        const ReceiveFilters(barangay: 'Casili'),
      ).single['item_name'],
      'Noodles',
    );
    expect(filterInventoryRows(rows, const ReceiveFilters()).length, 2);
  });

  test('Show all clears filters but keeps the order; saved and read back', () {
    const f = ReceiveFilters(
      barangay: 'Casili',
      reportId: 26,
      sort: ReceiveSort.newest,
      handover: 'Drop Off',
    );
    expect(f.narrowed, isTrue);
    expect(f.moreCount, 1);
    final c = f.cleared();
    expect(c.narrowed, isFalse);
    expect(c.sort, ReceiveSort.newest);
    final back = ReceiveFilters.fromJson(f.toJson());
    expect(back.barangay, 'Casili');
    expect(back.reportId, 26);
    expect(back.sort, ReceiveSort.newest);
    expect(f.copyWith(barangay: null).barangay, isNull);
    expect(f.copyWith(sort: ReceiveSort.urgent).barangay, 'Casili');
  });
}
