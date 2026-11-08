// CSWS Main Office <-> DRRMO delivery flow (UC-DR1 step 5, Table 36 alt 4a,
// Table 37): DRRMO accepts with its time, staff read plain step names.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/api.dart' show ApiResult;
import 'package:mobile/realtime.dart';
import 'package:mobile/ui/delivery_widgets.dart' show deliveryWord;
import 'package:mobile/ui/notifications_screen.dart' show pollDue;
import 'package:mobile/ui/widgets.dart' show Loader;
import 'package:mobile/ui/logistics_cards.dart'
    show showAcceptDeliveryDialog, vehicleAndDriver;

Map<String, dynamic>? _result;

/// Opens DRRMO's accept dialog for request [r]; its answer lands in _result.
Future<void> _openAccept(WidgetTester tester, Map r) async {
  _result = null;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              _result = await showAcceptDeliveryDialog(context, r),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  test('Delivery steps in plain staff words', () {
    expect(deliveryWord('Preparing'), 'Being packed');
    expect(deliveryWord('In Transit'), 'On the way');
    expect(deliveryWord('Delivered'), 'Arrived');
    expect(deliveryWord('Confirmed'), 'Received by barangay');
    expect(deliveryWord('Cancelled'), 'Cancelled');
  });

  testWidgets('DRRMO accepts with the planned time, vehicle and driver', (
    tester,
  ) async {
    final planned = DateTime.now().add(const Duration(days: 2)).toUtc();
    await _openAccept(tester, {
      'request_id': 7,
      'needs': 'Needs 1 truck',
      'destination': 'Banilad',
      'scheduled_date': planned.toIso8601String(),
    });
    expect(find.text('Accept request #7'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), ' Truck 2 ');
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(_result, isNotNull);
    expect(DateTime.parse(_result!['scheduled_date'] as String), planned);
    expect(_result!['vehicle'], 'Truck 2');
    expect(_result!.containsKey('driver'), isFalse); // optional, left empty
  });

  testWidgets('A time is required when the planned one has passed', (
    tester,
  ) async {
    await _openAccept(tester, {
      'request_id': 8,
      'scheduled_date': DateTime.now()
          .subtract(const Duration(days: 1))
          .toUtc()
          .toIso8601String(),
    });
    expect(find.text('Tap to pick the date and time'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(find.text('Pick the date and time'), findsOneWidget);
    expect(find.text('Accept request #8'), findsOneWidget); // still open
    expect(_result, isNull);
  });

  testWidgets('A live update reloads the screen (Loader.refresh)', (
    tester,
  ) async {
    final live = ValueNotifier<int>(0);
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Loader(
            refresh: live,
            load: [
              () async => ApiResult(200, {'n': ++loads}, ''),
            ],
            builder: (_, data) => Text('load ${(data[0] as Map)['n']}'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('load 1'), findsOneWidget);
    live.value++; // e.g. DRRMO accepted a request
    await tester.pumpAndSettle();
    expect(find.text('load 2'), findsOneWidget);
  });

  test('Without live updates the bell keeps polling', () {
    expect(Realtime.instance.connected, isFalse);
    expect(pollDue(DateTime.now()), isTrue);
  });

  test('Vehicle and driver line', () {
    expect(vehicleAndDriver({}), isNull);
    expect(
      vehicleAndDriver({'vehicle': 'Truck 2', 'driver': 'Juan'}),
      'Truck 2 · Driver: Juan',
    );
  });
}
