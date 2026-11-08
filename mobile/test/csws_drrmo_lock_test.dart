// Team, Nov 4: once CSWS Main Office asks DRRMO for transport, only DRRMO
// manages the delivery. The CSWS card shows who has it and offers no Edit
// (new date, truck came back, cancel) and no next step until DRRMO declines
// or withdraws. The server refuses the same actions (test_csws_drrmo_flow).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/ops_screens.dart' show DeliveriesScreen;

MockClient _server(String? requestStatus) => MockClient((req) async {
  final body = switch (req.url.path) {
    '/deliveries/' => [
      {
        'delivery_id': 7,
        'report_id': 5,
        'destination_barangay_id': 1,
        'destination_barangay_name': 'Banilad',
        'report_label': '#5 Flood - Banilad',
        'handled_by_user_id': 1,
        'status': 'Preparing',
        'delivery_date': '2026-11-04T01:00:00Z',
        'created_at': '2026-11-04T00:00:00Z',
        'items': <Object>[],
      },
    ],
    '/lookups' => <String, Object>{},
    '/logistics/requests' => [
      if (requestStatus != null)
        {
          'request_id': 3,
          'request_type': 'Delivery',
          'delivery_id': 7,
          'status': requestStatus,
          'stage': requestStatus,
          'reason': requestStatus == 'Declined' ? 'No truck' : null,
          'needs': 'Needs 1 truck',
        },
    ],
    '/deliveries/counts' => {'Preparing': 1},
    _ => {'detail': 'not mocked: ${req.url.path}'},
  };
  return http.Response(jsonEncode(body), 200);
});

Future<void> _pump(WidgetTester tester, String? requestStatus) async {
  tester.view.physicalSize = const Size(412, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  Api.instance.role = Roles.cswsMain;
  addTearDown(() => Api.instance.role = null);
  await http.runWithClient(() async {
    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light(), home: const DeliveriesScreen()),
    );
    await tester.pumpAndSettle();
  }, () => _server(requestStatus));
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Waiting for DRRMO: CSWS can only look', (tester) async {
    await _pump(tester, 'Pending');
    expect(find.text('With DRRMO · waiting for them to accept'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Mark On the way'), findsNothing);
    expect(find.text('History'), findsOneWidget); // still visible
  });

  testWidgets('Accepted by DRRMO: only DRRMO updates it', (tester) async {
    await _pump(tester, 'Accepted');
    expect(find.text('With DRRMO · only DRRMO updates it'), findsOneWidget);
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Mark On the way'), findsNothing);
  });

  testWidgets('After DRRMO declines, the delivery is CSWS\'s again', (
    tester,
  ) async {
    await _pump(tester, 'Declined');
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Ask DRRMO again'), findsOneWidget);
    expect(find.text('Mark On the way'), findsOneWidget);
  });

  testWidgets('Without DRRMO, CSWS manages it as before', (tester) async {
    await _pump(tester, null);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Request transport'), findsOneWidget);
  });
}
