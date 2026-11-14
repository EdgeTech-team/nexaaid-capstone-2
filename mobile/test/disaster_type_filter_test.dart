// NF-001 (T2): the Administrator's records screen filters every tab by
// disaster type on the server, one page at a time, and keeps the choice
// while switching tabs.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/records_screens.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  late List<Uri> requests;

  MockClient server() => MockClient((req) async {
    requests.add(req.url);
    final path = req.url.path;
    if (path == '/lookups') {
      return http.Response(
        jsonEncode({
          'disaster_types': [
            {'id': 1, 'name': 'Flood'},
            {'id': 2, 'name': 'Typhoon'},
          ],
        }),
        200,
      );
    }
    if (path == '/donations/records/counts') {
      return http.Response(
        jsonEncode({'all': 0, 'by_status': {}, 'reports': []}),
        200,
      );
    }
    if (path == '/deliveries/counts') {
      return http.Response(jsonEncode({'total': 0}), 200);
    }
    return http.Response('[]', 200, headers: {'x-total-count': '0'});
  });

  setUp(() {
    requests = [];
    Api.instance.token = 'test-token';
    Api.instance.role = Roles.admin;
    Api.instance.refreshLookups();
  });
  tearDown(() {
    Api.instance.token = null;
    Api.instance.role = null;
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: AdminRecordsScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Iterable<Map<String, String>> to(String path) =>
      requests.where((u) => u.path == path).map((u) => u.queryParameters);

  testWidgets('every tab asks only for the chosen disaster type', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await pump(tester);
      // All types: no filter on the first request
      expect(
        to('/donations/records').first.containsKey('disaster_type_id'),
        isFalse,
      );

      await tester.tap(find.byKey(const ValueKey('records-disaster-type')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Typhoon').last);
      await tester.pumpAndSettle();

      final donations = to('/donations/records').last;
      expect(donations['disaster_type_id'], '2');
      expect(donations['limit'], '20');
      expect(donations['offset'], '0');
      expect(to('/donations/records/counts').last['disaster_type_id'], '2');
      expect(find.text('No donations for Typhoon yet.'), findsOneWidget);

      await tester.tap(
        find.text('Per report').first,
      ); // the tab, not the inner toggle
      await tester.pumpAndSettle();
      final summaries = to('/cmo/report-summaries').last;
      expect(summaries['disaster_type_id'], '2');
      expect(summaries['limit'], '20');

      await tester.tap(find.text('Deliveries'));
      await tester.pumpAndSettle();
      final deliveries = to('/deliveries/').last;
      expect(deliveries['disaster_type_id'], '2');
      expect(deliveries['limit'], '20'); // no longer a fixed 200
      expect(deliveries['offset'], '0');
      expect(to('/deliveries/counts').last['disaster_type_id'], '2');
      expect(find.text('No deliveries for Typhoon yet.'), findsOneWidget);

      await tester.tap(find.text('Logistics'));
      await tester.pumpAndSettle();
      final logistics = to('/logistics/requests').last;
      expect(logistics['disaster_type_id'], '2');
      expect(logistics['stage'], 'Completed');
      expect(logistics['limit'], '20');

      // The choice stays when going back to Donations
      await tester.tap(find.text('Donations'));
      await tester.pumpAndSettle();
      expect(to('/donations/records').last['disaster_type_id'], '2');
    }, server);
  });

  testWidgets('a logistics stage chip is a server filter', (tester) async {
    await http.runWithClient(() async {
      await pump(tester);
      await tester.tap(find.text('Logistics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Declined'));
      await tester.pumpAndSettle();
      final last = to('/logistics/requests').last;
      expect(last['stage'], 'Declined');
      expect(last['offset'], '0');
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(to('/logistics/requests').last.containsKey('stage'), isFalse);
    }, server);
  });
}
