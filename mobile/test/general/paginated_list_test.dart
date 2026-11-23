// NF-003 (T1): the shared paged list (PagedController + PagedListView:
// numbered pages of 20) and the pilot, the staff donation records
// (PagedDonationEntries).
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/features/donations/paged_donation_entries.dart';
import 'package:mobile/shared/widgets/paginated_list.dart';
import 'package:mobile/shared/widgets/widgets.dart' show Loader;

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

  test('the app shows 10 records per page (team decision)', () {
    expect(defaultPageSize, 10);
    expect(PagedController(fetch: FakeList(0).call).pageSize, 10);
  });

  // The paging logic does not depend on the size; these use 20.
  group('PagedController (pages of 20)', () {
    test(
      'page 1, then any page by number; each page replaces the last',
      () async {
        final server = FakeList(45);
        final c = PagedController(pageSize: 20, fetch: server.call);
        await c.refresh();
        expect(ids(c), List.generate(20, (i) => i));
        expect(c.total, 45);
        expect(c.page, 1);
        expect(c.pageCount, 3);
        expect(c.hasPrevious, isFalse);
        expect(c.hasNext, isTrue);

        await c.next();
        expect(c.page, 2);
        expect(ids(c), List.generate(20, (i) => 20 + i)); // replaced, not added

        await c.goTo(3);
        expect(ids(c), List.generate(5, (i) => 40 + i)); // the last 5
        expect(c.hasNext, isFalse);

        await c.next(); // past the end: no request
        await c.goTo(9); // out of range: no request
        await c.previous();
        expect(c.page, 2);
        expect(server.calls, [(0, 20), (20, 20), (40, 20), (20, 20)]);
      },
    );

    test('a page for an old filter never lands in the new list', () async {
      final slow = Completer<ApiResult>();
      final c = PagedController(pageSize: 20, fetch: (_, _) => slow.future);
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

    test('opening pages quickly shows only the last one asked for', () async {
      final gates = <int, Completer<void>>{};
      final server = FakeList(100);
      final c = PagedController(
        pageSize: 20,
        fetch: (o, l) async {
          await (gates[o] ??= Completer<void>()).future;
          return server.call(o, l);
        },
      );
      gates[0] = Completer<void>()..complete();
      await c.refresh();
      final two = c.goTo(2);
      final three = c.goTo(3);
      gates[40] = (gates[40] ?? Completer<void>())..complete();
      await three;
      gates[20] = (gates[20] ?? Completer<void>())..complete();
      await two;
      expect(c.page, 3);
      expect(ids(c).first, 40);
    });

    test('a failed page keeps the rows on screen; Retry opens it', () async {
      final server = FakeList(30);
      var fail = false;
      final c = PagedController(
        pageSize: 20,
        fetch: (o, l) => fail
            ? Future.value(ApiResult(0, null, 'Network error'))
            : server.call(o, l),
      );
      await c.refresh();
      fail = true;
      await c.next();
      expect(c.page, 1); // still on page 1
      expect(c.items, hasLength(20));
      expect(c.error?.status, 0);
      fail = false;
      await c.retry(); // opens the page that failed
      expect(c.error, isNull);
      expect(c.page, 2);
      expect(ids(c), List.generate(10, (i) => 20 + i));
    });

    test(
      'without X-Total-Count (older backend) a short page is the last',
      () async {
        final c = PagedController(
          pageSize: 20,
          fetch: (offset, limit) async => ApiResult(200, [
            for (var i = offset; i < 25 && i < offset + limit; i++) {'id': i},
          ], ''),
        );
        await c.refresh();
        expect(c.hasNext, isTrue); // a full page: there may be more
        await c.next();
        expect(c.items, hasLength(5));
        expect(c.hasNext, isFalse);
        expect(c.total, 25); // worked out from the short last page
      },
    );
  });

  test('page numbers: first, last and the ones around the current page', () {
    expect(Pager.numbers(1, 5), [1, 2, 3, 4, 5]);
    expect(Pager.numbers(1, 12), [1, 2, 3, 4, null, 12]);
    expect(Pager.numbers(6, 12), [1, null, 5, 6, 7, null, 12]);
    expect(Pager.numbers(12, 12), [1, null, 9, 10, 11, 12]);
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
    test('a quiet reload loads the same page again in place', () async {
      final server = FakeList(45);
      final c = PagedController(pageSize: 20, fetch: server.call);
      await c.refresh();
      await c.goTo(2);
      server.calls.clear();
      final reload = c.reloadQuietly();
      expect(c.items, hasLength(20)); // never emptied meanwhile
      await reload;
      expect(server.calls, [(20, 20)]); // page 2 again
      expect(c.page, 2);
    });

    test('removing the last row of the last page goes back a page', () async {
      final server = FakeList(21);
      final c = PagedController(pageSize: 20, fetch: server.call);
      await c.refresh();
      await c.goTo(2);
      expect(ids(c), [20]);
      server.n = 20; // the server no longer has it either
      c.removeWhere((r) => r['id'] == 20);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(c.page, 1);
      expect(c.items, hasLength(20));
      expect(c.total, 20);
    });

    test('removeWhere refills the page from the server', () async {
      final server = FakeList(45);
      final c = PagedController(pageSize: 20, fetch: server.call);
      await c.refresh();
      server.n = 44;
      c.removeWhere((r) => r['id'] == 3);
      expect(c.items, hasLength(19)); // gone at once
      expect(c.total, 44);
      await Future<void>.delayed(Duration.zero);
      expect(c.items, hasLength(20)); // refilled with the next row
    });
  });

  group('PagedListView', () {
    Future<void> pump(
      WidgetTester tester,
      PagedController c, {
      Size size = const Size(500, 900),
    }) async {
      tester.view.physicalSize = size;
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

    Future<void> toPager(WidgetTester tester) async {
      await tester.dragUntilVisible(
        find.byKey(const ValueKey('pager-next')),
        find.byType(CustomScrollView),
        const Offset(0, -500),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('phone: 20 rows, "Page 1 of 3", Next opens page 2', (
      tester,
    ) async {
      final server = FakeList(45);
      final c = PagedController(pageSize: 20, fetch: server.call);
      await pump(tester, c);
      expect(find.text('Header'), findsOneWidget);
      expect(find.text('Row 0'), findsOneWidget);
      await toPager(tester);
      expect(find.byKey(const ValueKey('pager-compact')), findsOneWidget);
      expect(find.text('Page 1 of 3'), findsOneWidget);
      expect(find.text('Showing 1–20 of 45'), findsOneWidget);
      expect(find.text('Row 20'), findsNothing); // never more than 20

      await tester.tap(find.byKey(const ValueKey('pager-next')));
      await tester.pumpAndSettle();
      expect(c.page, 2);
      // The list went back up to the first row of the new page.
      expect(find.text('Row 20'), findsOneWidget);
      expect(find.text('Row 0'), findsNothing);
      await toPager(tester);
      expect(find.text('Showing 21–40 of 45'), findsOneWidget);
      expect(server.calls, [(0, 20), (20, 20)]);
    });

    testWidgets('laptop: numbered pages, the current one marked', (
      tester,
    ) async {
      final server = FakeList(250);
      final c = PagedController(pageSize: 20, fetch: server.call);
      await pump(tester, c, size: const Size(1280, 900));
      await toPager(tester);
      expect(find.byKey(const ValueKey('pager-numbers')), findsOneWidget);
      expect(find.byKey(const ValueKey('pager-page-13')), findsOneWidget);
      expect(find.text('…'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pager-page-13')));
      await tester.pumpAndSettle();
      expect(c.page, 13);
      expect(find.text('Row 240'), findsOneWidget);
      await toPager(tester);
      expect(find.text('Showing 241–250 of 250'), findsOneWidget);
      expect(server.calls.last, (240, 20));
    });

    testWidgets('one page only: no page buttons', (tester) async {
      await pump(
        tester,
        PagedController(pageSize: 20, fetch: FakeList(7).call),
      );
      expect(find.text('Showing 1–7 of 7'), findsOneWidget);
      expect(find.byKey(const ValueKey('pager-next')), findsNothing);
    });

    testWidgets('empty list shows the empty state', (tester) async {
      await pump(
        tester,
        PagedController(pageSize: 20, fetch: FakeList(0).call),
      );
      expect(find.text('Nothing here yet.'), findsOneWidget);
      expect(find.byKey(const ValueKey('paged-range')), findsNothing);
    });

    testWidgets('showing or hiding a tab rebuilds none of its rows or data', (
      tester,
    ) async {
      // UAT (Nov 15): switching tabs lagged because the screens of the tab
      // shown and the tab hidden were both rebuilt in that frame.
      final c = PagedController(pageSize: 20, fetch: FakeList(30).call);
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
      final c = PagedController(pageSize: 20, fetch: server.call);
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
      expect(server.calls, [(0, 20)]); // one quiet reload of the same page
      expect(find.text('Row 0'), findsOneWidget);
    });

    testWidgets('a page that fails to open shows Retry and keeps the rows', (
      tester,
    ) async {
      final server = FakeList(100);
      var fail = false;
      final c = PagedController(
        pageSize: 20,
        fetch: (o, l) => fail
            ? Future.value(ApiResult(0, null, 'Network error'))
            : server.call(o, l),
      );
      await pump(tester, c);
      await toPager(tester);
      fail = true;
      await tester.tap(find.byKey(const ValueKey('pager-next')));
      await tester.pumpAndSettle();
      await toPager(tester);
      expect(find.byKey(const ValueKey('paged-error')), findsOneWidget);
      expect(c.page, 1);
      expect(c.items, hasLength(20));
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('paged-error')), findsNothing);
      expect(c.page, 2);
    });

    testWidgets('G-004 / E-2: a 403 shows the unauthorized message', (
      tester,
    ) async {
      final c = PagedController(
        pageSize: 20,
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
        pageSize: 20,
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

    testWidgets('asks the server for 10 at a time with the filters', (
      tester,
    ) async {
      await http.runWithClient(() async {
        await pump(tester);
        final first = records().first.queryParameters;
        expect(first['limit'], '10');
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
        // Exactly the 30 Pending entries: no stale "Received" page and no
        // stale total.
        await tester.dragUntilVisible(
          find.byKey(const ValueKey('paged-range')),
          find.byType(CustomScrollView),
          const Offset(0, -500),
        );
        expect(find.text('Showing 1–10 of 30'), findsOneWidget);
      }, server);
    });
  });
}
