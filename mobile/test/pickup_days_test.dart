// Oct 10 notes: Door to Door donors choose the days they are home
// (M / T / W / Th ...) in a pop-out with a 9 AM - 5 PM note; the Disaster
// Unit's pickup map numbers the pins in a one-way, nearest-next order; and
// DRRMO request cards highlight what is needed and when it was asked (7.2).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/location_picker.dart' show PickupRules;
import 'package:mobile/ui/logistics_cards.dart';
import 'package:mobile/ui/pickup_days.dart';
import 'package:mobile/ui/pickup_route.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('Pickup day labels match the backend', () {
    expect(pickupDaysLabel({5, 1, 3}), 'Mon, Wed, Fri');
    expect(pickupDaysLabel({1, 2, 3, 4, 5}), 'Mon to Fri');
    expect(pickupDaysLabel({1, 2}), 'Mon, Tue');
    expect(pickupDaysLabel(<int>{}), '');
    expect(pickupDaysOf([3, 1, 9]), {1, 3});
    expect(pickupDaysOf('2,4'), {2, 4});
    expect(pickupDaysOf(null), isEmpty);
    expect(pickupHoursLabel(const PickupRules()), '9:00 AM to 5:00 PM');
  });

  test('One-way order visits nearby stops one after another', () {
    // Five stops along a street, given out of order.
    const street = [
      LatLng(10.3300, 123.9400), // 0: 3rd
      LatLng(10.3200, 123.9400), // 1: 1st
      LatLng(10.3400, 123.9400), // 2: 5th
      LatLng(10.3250, 123.9400), // 3: 2nd
      LatLng(10.3350, 123.9400), // 4: 4th
    ];
    // Starting at the office south of the street: south to north.
    final fromOffice = planOneWayRoute(
      street,
      start: const LatLng(10.3100, 123.9400),
    );
    expect(fromOffice, [1, 3, 0, 4, 2]);
    // No office: start at one end, never jump back and forth.
    final noOffice = planOneWayRoute(street);
    expect(noOffice, anyOf(equals([1, 3, 0, 4, 2]), equals([2, 4, 0, 3, 1])));
    final km = pathKm([for (final i in fromOffice) street[i]]);
    expect(km, closeTo(2.2, 0.1)); // 0.02 deg of latitude, about 2.2 km
    expect(niceKm(0.84), '840 m');
    expect(niceKm(3.24), '3.2 km');
    expect(planOneWayRoute(const []), isEmpty);
    expect(planOneWayRoute(const [LatLng(10, 123)]), [0]);
  });

  testWidgets('Donor taps the days they are home; weekends have no pickups', (
    tester,
  ) async {
    Set<int>? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  chosen = await pickPickupDays(context, const PickupRules()),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('When are you home?'), findsOneWidget);
    expect(
      find.textContaining(
        'Pickup hours are 9:00 AM to 5:00 PM',
        findRichText: true,
      ),
      findsOneWidget,
    );
    // Done stays off until a day is chosen.
    final done = find.widgetWithText(FilledButton, 'Done');
    expect(tester.widget<FilledButton>(done).onPressed, isNull);

    for (final day in ['M', 'W', 'Sa']) {
      // Saturday has no pickups, so its button does nothing.
      await tester.tap(find.text(day));
      await tester.pumpAndSettle();
    }
    expect(find.text('Home on Mon, Wed'), findsOneWidget);

    await tester.tap(done);
    await tester.pumpAndSettle();
    expect(chosen, {1, 3});
  });

  testWidgets('DRRMO card highlights the request and when it was made', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: LogisticsRequestCard({
              'request_id': 7,
              'request_type': 'Pickup',
              'stage': 'Pending',
              'status': 'Pending',
              'needs': 'Needs 1 truck, 2 volunteers',
              'notes': 'Needs 1 truck, 2 volunteers\nGate is blue',
              // 06:30 UTC = 2:30 PM in the Philippines
              'created_at': '2026-10-13T06:30:00+00:00',
              'requested_by_role': 'CSWS Disaster Unit',
              'pickup_date': '2026-10-14',
              'destination': '2 Door to Door stops near Parkmall',
              'report_label': 'Door to Door pickups on Wed, Oct 14 (2 stops)',
              'goods': ['2 kg Rice'],
              'stops': [
                {
                  'stop': 1,
                  'batch_reference': 'DON-A',
                  'landmark': 'Parkmall',
                  'address': '1 Ouano Ave',
                  'goods': ['2 kg Rice'],
                },
              ],
            }),
          ),
        ),
      ),
    );
    expect(find.text('Needs 1 truck, 2 volunteers'), findsOneWidget);
    expect(
      find.textContaining('Tue, Oct 13 · 2:30 PM', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('Pickup on Wed, Oct 14'), findsOneWidget);
    expect(find.text('Parkmall'), findsOneWidget);
    expect(find.text('Gate is blue'), findsOneWidget); // other notes, once
  });
}
