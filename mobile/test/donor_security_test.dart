// Dave's donor-side security tasks (Nov 18 brief):
//   NF-004      guests: Door to Door locked by default (GUEST_DOOR_TO_DOOR),
//               or one pickup waiting per number when 'limited'
//   D4 (NF-006)  a Door to Door pickup waiting for the email code
//   D5 (NF-007)  every pickup stop needs "Called – confirmed"
//   D7 (G-003)   one "Edit donation": changed lines -> PUT, new lines ->
//                POST /items, pledged lines with history stay read-only
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/pickup_plan.dart';
import 'package:mobile/ui/verify_email_sheet.dart';
import 'package:mobile/ui/widgets.dart' show Names;
import 'package:shared_preferences/shared_preferences.dart';

import 'step_form_helpers.dart';

final _lookups = <String, dynamic>{
  'items': [
    {
      'id': 1,
      'name': 'Rice (kg)',
      'item_name': 'Rice',
      'unit': 'kg',
      'kind': 'weight',
      'size_units': ['kg', 'g'],
      'sizes': [
        {'id': 1, 'label': '1 kg pack', 'amount': 1.0},
      ],
    },
  ],
};
const _report = <String, dynamic>{
  'id': 7,
  'disaster': 'Flood',
  'barangay': 'Looc',
};

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: home,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: true),
        child: child!,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Records every request; answers {} (200) unless [answer] says otherwise.
class _Recorder {
  final calls = <(String, String, Map?)>[];
  http.Response Function(http.Request req)? answer;

  MockClient get client => MockClient((req) async {
    calls.add((
      req.method,
      req.url.path,
      req.body.isEmpty ? null : jsonDecode(req.body) as Map?,
    ));
    return answer?.call(req) ?? http.Response(jsonEncode({}), 200);
  });
}

Map<String, dynamic> _pledged({
  int additionNo = 1,
  String status = 'Pending',
}) => {
  'batch_reference': 'DON-EDIT1',
  'handover_method': 'Drop Off',
  'status': status,
  'can_change_items': true,
  'items': [
    {
      'donation_id': 11,
      'item_id': 1,
      'item_name': 'Rice',
      'unit': 'kg',
      'quantity': 5,
      'pack_count': 5,
      'per_pack': 1,
      'size_label': '1 kg pack',
      'packaging': 'Pack',
      'amount_text': '5 packs x 1 kg pack',
      'status': status,
      'addition_no': additionNo,
    },
  ],
};

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => Api.instance.token = null);

  testWidgets('Guests (blocked, the default): Door to Door shows, locked', (
    tester,
  ) async {
    Api.instance.token = null;
    await http.runWithClient(() async {
      await _pump(
        tester,
        DonateScreen(report: _report, names: Names(_lookups)),
      );
      await openStep(tester, 'Handover'); // UI redesign: in steps
      expect(find.byKey(const ValueKey('door-to-door-locked')), findsOneWidget);
      expect(find.text(guestPickupBlockedText), findsOneWidget);
      expect(find.text('Register (takes 2 minutes)'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    }, () => _Recorder().client);
  });

  testWidgets('Guests (limited): Door to Door works, one pickup at a time', (
    tester,
  ) async {
    Api.instance.token = null;
    final rec = _Recorder()
      ..answer = (req) => req.url.path == '/donations/pickup-rules'
          ? http.Response(
              jsonEncode({
                'days': [1, 2, 3, 4, 5],
                'guest_door_to_door': 'limited',
              }),
              200,
            )
          : http.Response(jsonEncode({}), 200);
    await http.runWithClient(() async {
      await _pump(
        tester,
        DonateScreen(report: _report, names: Names(_lookups)),
      );
      await openStep(tester, 'Handover'); // UI redesign: in steps
      expect(find.byKey(const ValueKey('door-to-door-locked')), findsNothing);
      await tester.tap(find.text('Door to Door'));
      await tester.pumpAndSettle();
      expect(find.text(guestPickupLimitText), findsOneWidget);
    }, () => rec.client);
  });

  testWidgets('After signing in, the guest donation reopens filled in', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await rememberGuestDonation(_report, {
      'report_id': 7,
      'handover': 'Door to Door',
      'lines': <Object>[],
    });
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(
        tester,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => resumeGuestDonation(context),
                child: const Text('home'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('home'));
      await tester.pumpAndSettle();
      expect(find.byType(DonateScreen), findsOneWidget);
      expect(find.text('We kept what you typed last time.'), findsOneWidget);
      // Only once.
      final p = await SharedPreferences.getInstance();
      expect(p.getString('resume_guest_donation'), isNull);
    }, () => _Recorder().client);
  });

  testWidgets('D1: a signed-in donor can still choose Door to Door', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    await http.runWithClient(() async {
      await _pump(
        tester,
        DonateScreen(report: _report, names: Names(_lookups)),
      );
      await openStep(tester, 'Handover'); // UI redesign: in steps
      expect(find.text('Door to Door'), findsOneWidget);
      expect(find.text(guestPickupLimitText), findsNothing);
    }, () => _Recorder().client);
  });

  testWidgets('D7: one Edit form; pledged lines are saved with one PUT', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    final rec = _Recorder();
    await http.runWithClient(() async {
      await _pump(
        tester,
        DonateScreen(report: _report, names: Names(_lookups), edit: _pledged()),
      );
      expect(find.text('Edit donation'), findsOneWidget);
      expect(find.text('+ Add item'), findsOneWidget);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      final sent = rec.calls.where(
        (c) => c.$2.startsWith('/donations/entries'),
      );
      expect(
        [for (final c in sent) '${c.$1} ${c.$2}'],
        ['PUT /donations/entries/DON-EDIT1'],
      );
      expect((sent.first.$3!['items'] as List).length, 1);
    }, () => rec.client);
  });

  testWidgets('D7: with items added later, pledged items are read-only', (
    tester,
  ) async {
    Api.instance.token = 'test-token';
    final rec = _Recorder();
    await http.runWithClient(() async {
      await _pump(
        tester,
        DonateScreen(
          report: _report,
          names: Names(_lookups),
          edit: _pledged(additionNo: 2),
        ),
      );
      expect(find.text('Already in DON-EDIT1'), findsOneWidget);
      expect(find.textContaining('5 packs x 1 kg pack'), findsOneWidget);
      // The handover can't change here (the history stays).
      expect(find.text('How will you hand it over?'), findsNothing);
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
      // The new line is still empty: nothing is sent, no PUT ever.
      expect(rec.calls.where((c) => c.$1 == 'PUT'), isEmpty);
    }, () => rec.client);
  });

  testWidgets('D4: a held pickup asks for the email code', (tester) async {
    await _pump(tester, const Scaffold(body: EmailHoldNote()));
    expect(find.text(emailHoldText), findsOneWidget);
    expect(find.text('Enter code'), findsOneWidget);
  });

  testWidgets('D5: each stop shows the number and Called – confirmed', (
    tester,
  ) async {
    final outcomes = <String>[];
    final stop = PlanStop.fromJson({
      'stop_id': 'STOP-DON-1',
      'lat': 10.32,
      'lng': 123.94,
      'landmark': 'Mandaue City Hall',
      'address': 'Centro, Mandaue City',
      'days': [3],
      'status': 'planned',
      'planned_date': '2026-11-25',
      'contact_confirmed': false,
      'flags': ['call_to_confirm'],
      'donations': [
        {
          'batch_reference': 'DON-1',
          'donor': 'Ana Cruz',
          'donor_contact': '09171234567',
          'pickup_days': [3],
          'contact_outcome': null,
          'contact_confirmed': false,
          'items': [
            {
              'item_name': 'Rice',
              'unit': 'kg',
              'packaging': 'Sack',
              'quantity': 50,
              'amount_text': '2 packs x 25 kg sack',
            },
          ],
        },
      ],
    });
    expect(stop.contactConfirmed, isFalse);
    await _pump(
      tester,
      Scaffold(
        body: StopDetailsSheet(
          stop: stop,
          number: 1,
          onContactCheck: (d, outcome) async => outcomes.add(outcome),
        ),
      ),
    );
    expect(find.text('09171234567'), findsOneWidget);
    expect(find.text('Called – confirmed? (required)'), findsOneWidget);
    // G-002 (D8): the readable amount and packaging.
    expect(
      find.textContaining('Rice · 2 packs x 25 kg sack (Sack)'),
      findsOneWidget,
    );
    await tester.tap(find.text('Reached'));
    await tester.pump();
    expect(outcomes, ['Reached']);
  });
}
