// G-003 (D7): My Giving must load for an account with many entries in every
// state. test/fixtures/my_giving_real.json is what the real server sends
// (GET /donations/mine/entries and /counts) for an organization with
// Pending, Partly Received, Received, Expired and Cancelled entries, items
// the donor removed and items added later (backend test
// test_my_giving_loads.py builds the same history).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/core/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/features/donations/donor_dashboard.dart';
import 'package:mobile/features/donations/my_giving.dart';

// A 1 x 1 PNG, for the QR image.
const _png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Map _real() =>
    jsonDecode(File('test/fixtures/my_giving_real.json').readAsStringSync())
        as Map;

MockClient _server(Map data) => MockClient((req) async {
  final path = req.url.path;
  if (path == '/donations/mine/entries/counts') {
    return http.Response(jsonEncode(data['counts']), 200);
  }
  if (path == '/donations/mine/entries') {
    final rows = (data['entries'] as List);
    final offset = int.tryParse(req.url.queryParameters['offset'] ?? '') ?? 0;
    final limit = int.tryParse(req.url.queryParameters['limit'] ?? '') ?? 10;
    return http.Response(
      jsonEncode(rows.skip(offset).take(limit).toList()),
      200,
      headers: {'x-total-count': '${rows.length}'},
    );
  }
  if (path.startsWith('/donations/batch/')) {
    return http.Response(jsonEncode({'qr_image_base64': _png}), 200);
  }
  return http.Response('[]', 200);
});

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
      home: Scaffold(body: body),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('My giving loads with every entry state from the server', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    final data = _real();
    await http.runWithClient(() async {
      await _pump(tester, const MyGivingScreen());
      expect(tester.takeException(), isNull);
      expect(find.text('Donations made'), findsOneWidget);
      expect(find.text('Donation status'), findsOneWidget);
      // The first cards of the list (the rest are built when scrolled to).
      for (final e in (data['entries'] as List).cast<Map>().take(2)) {
        expect(
          find.textContaining('${e['batch_reference']}'),
          findsWidgets,
          reason: '${e['status']} entry is listed',
        );
      }
    }, () => _server(data));
  });

  testWidgets('Every entry from the server opens its detail screen', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    final data = _real();
    await http.runWithClient(() async {
      for (final e in (data['entries'] as List).cast<Map>()) {
        await _pump(tester, DonationDetailScreen(entry: e));
        expect(
          tester.takeException(),
          isNull,
          reason: '${e['status']} ${e['batch_reference']}',
        );
      }
    }, () => _server(data));
  });
}
