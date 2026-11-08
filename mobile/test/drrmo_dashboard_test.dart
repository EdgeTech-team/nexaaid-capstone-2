// DRRMO dashboard (UC-DR1), testing Nov 3: every stat tile, "Needs your
// action" line and request button does something visible on a phone. The
// request list sits below the dashboard, so a tap that only changed the
// list off screen looked dead.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/ops_screens.dart' show DrrmoScreen;

const _phone = Size(412, 900);
var _accepted = false; // request #1, once DRRMO accepted it

Map<String, dynamic> _request(int id, String stage) => {
  'request_id': id,
  'request_type': 'Delivery',
  'delivery_id': 100 + id,
  'status': stage,
  'stage': stage,
  'scheduled_date': '2030-01-01T00:00:00Z',
  'scheduled_by': 'CSWS Main Office',
  'needs': 'Needs 1 truck',
  'notes': 'Needs 1 truck',
  'created_at': '2026-11-03T01:00:00Z',
  'requested_by_role': 'CSWS Main Office',
  'destination': 'Banilad',
  'report_label': '#5 Flood - Banilad',
  'priority_level': 'High',
  'goods': ['30 kg Rice'],
  'stops': <Object>[],
  'delivery_status': 'Preparing',
  'mine': stage == 'Accepted',
  'can_complete': false,
};

var _pickupAnswer = 200; // what POST .../picked-up answers
var _pickedUp = 0;

final _server = MockClient((req) async {
  final path = req.url.path;
  if (req.method == 'POST' && path == '/drrmo/requests/2/picked-up') {
    if (_pickupAnswer != 200) {
      return http.Response(
        jsonEncode({'detail': 'This delivery is scheduled to leave on Jan 1.'}),
        _pickupAnswer,
      );
    }
    _pickedUp++;
    return http.Response(jsonEncode(_request(2, 'In Transit')), 200);
  }
  if (req.method == 'PATCH' && path == '/drrmo/requests/1/accept') {
    _accepted = true;
    return http.Response(jsonEncode(_request(1, 'Accepted')), 200);
  }
  final body = switch (path) {
    '/drrmo/dashboard' => {
      'total_requests': 2,
      'pending_requests': _accepted ? 0 : 1,
      'scheduled': _accepted ? 2 : 1,
      'in_transit': 0,
      'completed': 0,
      'declined': 0,
    },
    '/drrmo/requests' => [
      _request(1, _accepted ? 'Accepted' : 'Pending'),
      _request(2, 'Accepted'),
    ],
    '/deliveries/' => <Object>[],
    '/deliveries/needs-action' => {
      'items': [
        if (!_accepted)
          {
            'key': 'new',
            'label': 'New requests to accept or decline',
            'view': 'Pending',
            'ids': [1],
            'count': 1,
          },
      ],
      'all_caught_up': _accepted,
    },
    '/deliveries/timing/summary' => {'accepted': 0, 'trips': 0, 'days': 30},
    _ => {'detail': 'not mocked: $path'},
  };
  return http.Response(jsonEncode(body), 200);
});

Future<void> _pumpPhone(WidgetTester tester) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: DrrmoScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// The finder's widget is on the screen, without scrolling by hand.
void _onScreen(WidgetTester tester, Finder f) {
  expect(f, findsOneWidget);
  final y = tester.getTopLeft(f).dy;
  expect(y, inInclusiveRange(0, _phone.height - 40));
}

Future<void> _scrollTo(WidgetTester tester, Finder f) async {
  await tester.scrollUntilVisible(
    f,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() {
    _accepted = false;
    _pickupAnswer = 200;
    _pickedUp = 0;
  });

  Future<void> pickUp(WidgetTester tester) async {
    await _pumpPhone(tester);
    await tester.tap(find.text('Accepted').first);
    await tester.pumpAndSettle();
    final button = find.widgetWithText(
      FilledButton,
      'Picked up · mark On the way',
    );
    await _scrollTo(tester, button);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Picked up delivery #102?'), findsOneWidget);
    await tester.tap(find.text('Yes, on the way'));
    // Not pumpAndSettle: the toast's countdown would run until it closes.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('Picked up marks the delivery On the way', (tester) async {
    await http.runWithClient(() async {
      await pickUp(tester);
      expect(_pickedUp, 1);
      expect(find.text('Delivery #102 is on the way'), findsOneWidget);
      await tester.pump(const Duration(seconds: 15)); // let the toast close
    }, () => _server);
  });

  testWidgets('A refused pick-up says why', (tester) async {
    _pickupAnswer = 409;
    await http.runWithClient(() async {
      await pickUp(tester);
      expect(
        find.text('This delivery is scheduled to leave on Jan 1.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 15));
    }, () => _server);
  });

  testWidgets('A stat tile scrolls its requests into view', (tester) async {
    await http.runWithClient(() async {
      await _pumpPhone(tester);
      expect(find.text('Request #2 · Delivery'), findsNothing); // off screen
      await tester.tap(find.text('Accepted').first);
      await tester.pumpAndSettle();
      _onScreen(tester, find.text('Request #2 · Delivery'));
      expect(find.text('Accepted: 1 request'), findsOneWidget);
      expect(find.text('Showing below'), findsOneWidget); // tile marked
    }, () => _server);
  });

  testWidgets('"New requests" works even when already selected', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pumpPhone(tester);
      await tester.tap(find.text('New requests'));
      await tester.pumpAndSettle();
      _onScreen(tester, find.text('Request #1 · Delivery'));
    }, () => _server);
  });

  testWidgets('A "Needs your action" line shows that request', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pumpPhone(tester);
      await tester.tap(find.text('New requests to accept or decline'));
      await tester.pumpAndSettle();
      _onScreen(tester, find.text('Request #1 · Delivery'));
    }, () => _server);
  });

  testWidgets('Decline asks for a reason', (tester) async {
    await http.runWithClient(() async {
      await _pumpPhone(tester);
      final decline = find.widgetWithText(OutlinedButton, 'Decline');
      await _scrollTo(tester, decline);
      await tester.tap(decline);
      await tester.pumpAndSettle();
      expect(find.text('Decline request #1'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Accept asks for the time, then follows the request', (
    tester,
  ) async {
    await http.runWithClient(() async {
      await _pumpPhone(tester);
      final accept = find.widgetWithText(FilledButton, 'Accept');
      await _scrollTo(tester, accept);
      // On a phone Decline and Accept share the row, full width.
      expect(tester.getSize(accept).width, greaterThan(150));
      await tester.tap(accept);
      await tester.pumpAndSettle();
      expect(find.text('Accept request #1'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Accept').last);
      await tester.pumpAndSettle();
      expect(_accepted, isTrue);
      // The list now shows Accepted, with request #1 on screen.
      expect(find.text('Accepted: 2 requests'), findsOneWidget);
      _onScreen(tester, find.text('Request #1 · Delivery'));
      await tester.pump(const Duration(seconds: 5)); // let the toast close
    }, () => _server);
  });
}
