// NF-003 (T1): the shared paged list (PagedController + PagedListView) and
// the pilot, the staff donation records (PagedDonationEntries).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/paged_donation_entries.dart';
import 'package:mobile/ui/paginated_list.dart';
import 'package:mobile/ui/widgets.dart' show Loader;

/// A fake server list of [n] rows: one page per call, X-Total-Count set.
class FakeList {
  FakeList(this.n);
  int n;
  final calls = <(int, int)>[];

  Future<ApiResult> call(int offset, int limit) async {
    calls.add((offset, limit));
    final rows = [
      for (var i = offset; i < n && i < offset + limit; i++) {'id': i},
    ];
    return ApiResult(200, rows, jsonEncode(rows), {'x-total-count': '$n'});
  }
}

List<int> ids(PagedController c) => [for (final r in c.items) r['id'] as int];

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  group('PagedController', () {
    test('loads page by page and stops at the total', () async {
      final server = FakeList(45);
      final c = PagedController(fetch: server.call);
      await c.refresh();
      expect(ids(c), List.generate(20, (i) => i));
      expect(c.total, 45);
      expect(c.hasMore, isTrue);
      await c.loadMore();
      await c.loadMore();
      expect(ids(c), List.generate(45, (i) => i));
      expect(c.hasMore, isFalse);
      await c.loadMore(); // nothing left: no request
      expect(server.calls, [(0, 20), (20, 20), (40, 20)]);
    });

    test('asks for a page only once while it is loading', () async {
      final gate = Completer<void>();
      var calls = 0;
      final c = PagedController(
        fetch: (offset, limit) async {
          calls++;
          await gate.future;
          return ApiResult(
            200,
            [
              for (var i = 0; i < limit; i++) {'id': offset + i},
            ],
            '',
            {'x-total-count': '100'},
          );
        },
      );
      final first = c.refresh();
      c.loadMore();
      c.loadMore();
      gate.complete();
      await first;
      expect(calls, 1);
    });

    test('a page for an old filter never lands in the new list', () async {
      final slow = Completer<ApiResult>();
      final c = PagedController(fetch: (_, _) => slow.future);
      final old = c.refresh();
      // The filter changes before the old page arrives
      final typhoon = FakeList(3);
      final fresh = c.refresh(fetch: typhoon.call);
      await fresh;
      slow.complete(
        ApiResult(
          200,
          [
            {'id': 99},
          ],
          '',
          {'x-total-count': '1'},
        ),
      );
      await old;
      expect(ids(c), [0, 1, 2]);
      expect(c.total, 3);
    });

    test('a failed page keeps the loaded rows; Retry continues', () async {
      final server = FakeList(30);
      var fail = false;
      final c = PagedController(
        fetch: (o, l) => fail
            ? Future.value(ApiResult(0, null, 'Network error'))
            : server.call(o, l),
      );
      await c.refresh();
      fail = true;
      await c.loadMore();
      expect(c.items, hasLength(20));
      expect(c.error?.status, 0);
      await c.loadMore(); // waits for Retry, no request
      expect(server.calls, hasLength(1));
      fail = false;
      await c.retry();
      expect(ids(c), List.generate(30, (i) => i));
      expect(c.error, isNull);
      expect(server.calls.last, (20, 20));
    });

    test(
      'without X-Total-Count (older backend) a short page ends it',
      () async {
        final c = PagedController(
          fetch: (offset, limit) async => ApiResult(200, [
            for (var i = offset; i < 25 && i < offset + limit; i++) {'id': i},
          ], ''),
        );
        await c.refresh();
        await c.loadMore();
        expect(c.items, hasLength(25));
        expect(c.total, isNull);
        expect(c.hasMore, isFalse);
      },
    );
  });

  test('ApiResult.total reads X-Total-Count from a real response', () async {
    await http.runWithClient(
      () async {
        final r = await Api.instance.get('/things', query: {'limit': '2'});
        expect(r.total, 57);
        expect(r.json, hasLength(2));
      },
      () => MockClient(
        (req) async => http.Response(
          '[1,2]',
          200,
          headers: {'X-Total-Count': '57', 'content-type': 'application/json'},
        ),
      ),
    );
  });

  group('UAT Nov 14: no flash, no lost place', () {
    test('a quiet reload keeps the rows until the fresh ones arrive', () async {
      final server = FakeList(45);
      final c = PagedController(fetch: server.call);
      await c.refresh();
      await c.loadMore(); // 40 rows on screen
      server.calls.clear();
      final reload = c.reloadQuietly();
      expect(c.items, hasLength(40)); // never emptied meanwhile
      await reload;
      // One request for every row shown, from the top.
      expect(server.calls, [(0, 40)]);
      expect(ids(c), List.generate(40, (i) => i));
      expect(c.hasMore, isTrue);
      await c.loadMore();
      expect(c.items, hasLength(45));
    });

    test(
      'removeWhere takes a row out and the next page starts earlier',
      () async {
        final server = FakeList(45);
        final c = PagedController(fetch: server.call);
        await c.refresh();
        c.removeWhere((r) => r['id'] == 3);
        expect(c.items, hasLength(19));
        expect(c.total, 44);
        expect(c.offset, 19);
      },
    );
  });

  group('PagedListView', () {
    Future<void> pump(WidgetTester tester, PagedController c) async {
      tester.view.physicalSize = const Size(500, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: PagedListView(
              controller: c,
              header: const [Text('Header')],
              empty: const Text('Nothing here yet.'),
              itemBuilder: (_, r) =>
                  SizedBox(height: 80, child: Text('Row ${r['id']}')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('scrolling to the bottom loads more until the end', (
      tester,
    ) async {
      final server = FakeList(45);
      final c = PagedController(fetch: server.call);
      await pump(tester, c);
      expect(find.text('Header'), findsOneWidget);
      expect(find.text('Row 0'), findsOneWidget);
      await tester.dragUntilVisible(
        find.text('That is all 45.'),
        find.byType(CustomScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(c.items, hasLength(45));
      expect(find.text('That is all 45.'), findsOneWidget);
      // Each page was asked for once, in order
      expect(server.calls, [(0, 20), (20, 20), (40, 20)]);
    });

    testWidgets('empty list shows the empty state', (tester) async {
      await pump(tester, PagedController(fetch: FakeList(0).call));
      expect(find.text('Nothing here yet.'), findsOneWidget);
    });

    testWidgets('showing or hiding a tab rebuilds none of its rows or data', (
      tester,
    ) async {
      // UAT (Nov 15): switching tabs lagged because the screens of the tab
      // shown and the tab hidden were both rebuilt in that frame.
      final c = PagedController(fetch: FakeList(30).call);
      final shown = ValueNotifier(true);
      var rows = 0;
      var loads = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (_, on, child) => TickerMode(enabled: on, child: child!),
              child: Column(
                children: [
                  SizedBox(
                    height: 40,
                    child: Loader(
                      load: [() async => ApiResult(200, {}, '{}')],
                      builder: (_, _) {
                        loads++;
                        return const Text('Loaded');
                      },
                    ),
                  ),
                  Expanded(
                    child: PagedListView(
                      controller: c,
                      empty: const Text('Nothing here yet.'),
                      itemBuilder: (_, r) {
                        rows++;
                        return SizedBox(
                          height: 80,
                          child: Text('Row ${r['id']}'),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final (rowsBefore, loadsBefore) = (rows, loads);
      shown.value = false;
      await tester.pumpAndSettle();
      shown.value = true;
      await tester.pumpAndSettle();
      expect(rows, rowsBefore);
      expect(loads, loadsBefore);
    });

    testWidgets('a hidden list waits, then reloads quietly when shown', (
      tester,
    ) async {
      final server = FakeList(30);
      final c = PagedController(fetch: server.call);
      final shown = ValueNotifier(true);
      final changed = ValueNotifier(0);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: shown,
              builder: (_, on, _) => TickerMode(
                enabled: on,
                child: PagedListView(
                  controller: c,
                  refresh: changed,
                  empty: const Text('Nothing here yet.'),
                  itemBuilder: (_, r) =>
                      SizedBox(height: 80, child: Text('Row ${r['id']}')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      server.calls.clear();
      shown.value = false; // another tab is showing
      await tester.pump();
      changed.value++; // a live update
      await tester.pumpAndSettle();
      expect(server.calls, isEmpty);
      shown.value = true;
      await tester.pumpAndSettle();
      expect(server.calls, hasLength(1)); // one quiet reload
      expect(find.text('Row 0'), findsOneWidget);
    });

    testWidgets('a failed page shows Retry and keeps the rows', (tester) async {
      final server = FakeList(500);
      var fail = false;
      final c = PagedController(
        fetch: (o, l) => fail
            ? Future.value(ApiResult(0, null, 'Network error'))
            : server.call(o, l),
      );
      await pump(tester, c);
      final loaded = c.items.length; // the next page starts well ahead
      fail = true;
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('paged-error')),
        find.byType(CustomScrollView),
        const Offset(0, -400),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('paged-error')), findsOneWidget);
      expect(c.items, hasLength(loaded));
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('paged-error')), findsNothing);
      expect(c.items.length, greaterThan(loaded));
    });

    testWidgets('G-004 / E-2: a 403 shows the unauthorized message', (
      tester,
    ) async {
      final c = PagedController(
        fetch: (_, _) async => ApiResult(403, {
          'detail': 'You do not have permission to access this resource',
        }, ''),
      );
      await pump(tester, c);
      expect(find.text("You don't have access to this"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });

    testWidgets('a failed first page shows the full error with Retry', (
      tester,
    ) async {
      final c = PagedController(
        fetch: (_, _) async => ApiResult(0, null, 'Network error'),
      );
      await pump(tester, c);
      expect(find.text("Can't reach the server"), findsOneWidget);
    });
  });

  group('PagedDonationEntries (pilot: M4 donation records)', () {
    Map entry(int i, String status) => {
      'batch_reference': 'DON-$i',
      'report_id': 18,
      'report_label': '#18 Flood - Tipolo',
      'entry_no': i + 1,
      'status': status,
      'handover_method': 'Drop Off',
      'created_at': '2026-10-04T08:00:00',
      'donor': 'Juan Cruz',
      'total_items': 1,
      'pending_items': 1,
      'on_hold_items': 0,
      'items': [
        {
          'donation_id': i + 1,
          'item_name': 'Rice',
          'unit': 'kg',
          'quantity': 2,
          'packaging': 'Box',
          'status': status,
        },
      ],
    };

    late List<Uri> requests;
    late Map<String, Completer<void>> holds;

    MockClient server() => MockClient((req) async {
      requests.add(req.url);
      final q = req.url.queryParameters;
      final hold = holds[q['status'] ?? ''];
      if (hold != null) await hold.future;
      if (req.url.path == '/donations/records/counts') {
        return http.Response(
          jsonEncode({
            'all': 30,
            'by_status': {'Pending': 25, 'Received': 5, 'On Hold': 0},
            'reports': [
              {'report_id': 18, 'report_label': '#18 Flood - Tipolo'},
            ],
          }),
          200,
        );
      }
      final status = q['status'] ?? 'Pending';
      final total = status == 'Received' ? 5 : 30;
      final offset = int.parse(q['offset'] ?? '0');
      final limit = int.parse(q['limit'] ?? '1000');
      final rows = [
        for (var i = offset; i < total && i < offset + limit; i++)
          entry(i, status),
      ];
      return http.Response(
        jsonEncode(rows),
        200,
        headers: {'x-total-count': '$total'},
      );
    });

    setUp(() {
      requests = [];
      holds = {};
      Api.instance.token = 'test-token';
      Api.instance.role = 'Administrator';
    });
    tearDown(() {
      Api.instance.token = null;
      Api.instance.role = null;
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: PagedDonationEntries()),
        ),
      );
      await tester.pumpAndSettle();
    }

    List<Uri> records() =>
        requests.where((u) => u.path == '/donations/records').toList();

    testWidgets('asks the server for 20 at a time with the filters', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await pump(tester);
        final first = records().first.queryParameters;
        expect(first['limit'], '20');
        expect(first['offset'], '0');
        expect(first['include_closed'], 'true');
        expect(first['sort'], 'newest');
        // Counts come from the server, with the same filters
        expect(find.text('All (30)'), findsOneWidget);
        expect(find.text('Pending (25)'), findsOneWidget);

        await tester.tap(find.text('Received (5)'));
        await tester.pumpAndSettle();
        final filtered = records().last.queryParameters;
        expect(filtered['status'], 'Received');
        expect(filtered['offset'], '0'); // a new filter starts at page 1
        final counts = requests
            .where((u) => u.path == '/donations/records/counts')
            .last
            .queryParameters;
        expect(counts['status'], 'Received');
        // Titles use the server's entry_no ("Donation N")
        expect(find.text('Donation 1 · 1 item'), findsOneWidget);
      }, server);
    });

    testWidgets('search waits until typing stops', (tester) async {
      await http.runWithClient(() async {
        await pump(tester);
        final before = records().length;
        final field = find.byType(TextField).first;
        await tester.enterText(field, 'r');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(field, 'ri');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(field, 'rice');
        await tester.pump(const Duration(milliseconds: 100));
        expect(records().length, before); // still typing
        await tester.pump(searchDebounce);
        await tester.pumpAndSettle();
        expect(records().length, before + 1);
        expect(records().last.queryParameters['q'], 'rice');
      }, server);
    });

    testWidgets('a late page for the old filter is not shown', (tester) async {
      await http.runWithClient(() async {
        await pump(tester);
        // "Received" answers slowly; switch to "Pending" before it lands.
        holds['Received'] = Completer<void>();
        await tester.tap(find.text('Received (5)'));
        await tester.pump();
        await tester.tap(find.text('Pending (25)'));
        await tester.pumpAndSettle();
        holds['Received']!.complete();
        await tester.pumpAndSettle();
        expect(find.text('Donation 1 · 1 item'), findsOneWidget);
        final statuses = {
          for (final c in tester.widgetList<ChoiceChip>(
            find.byType(ChoiceChip),
          ))
            if (c.selected) (c.label as Text).data,
        };
        expect(statuses, {'Pending (25)'});
        // Scroll to the end: exactly the 30 Pending entries, no stale
        // "Received" page appended and no stale total.
        for (var i = 0; i < 8; i++) {
          await tester.drag(
            find.byType(CustomScrollView),
            const Offset(0, -3000),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('That is all 30.'), findsOneWidget);
      }, server);
    });
  });
}
