// Oct 23: Door to Door donors tap specific dates on a calendar, and pickup
// is only offered in the service areas (Mandaue, Cebu City,
// Consolacion, Lapu-Lapu). Same rules as the backend.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/api.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/location_picker.dart' show PickupRules, placeIn;
import 'package:mobile/ui/pickup_days.dart';
import 'package:mobile/ui/pickup_plan.dart';
import 'package:mobile/ui/widgets.dart' show Names;

final _lookups = <String, dynamic>{
  'items': [
    {
      'id': 3,
      'name': 'Canned Goods (cans)',
      'item_name': 'Canned Goods',
      'unit': 'cans',
      'kind': 'count',
      'size_units': ['cans'],
      'sizes': <Object>[],
    },
  ],
};

/// The next [weekday] at least two days from now (a CSWS pickup day).
DateTime _next(int weekday) {
  final now = DateTime.now();
  var d = DateTime(now.year, now.month, now.day).add(const Duration(days: 2));
  while (d.weekday != weekday) {
    d = d.add(const Duration(days: 1));
  }
  return d;
}

void main() {
  test('Service areas match the backend', () {
    const rules = PickupRules();
    expect(rules.inServiceArea('12 Del Rosario St., Mandaue City'), isTrue);
    expect(
      rules.inServiceArea('Gaisano Country Mall, Banilad, Cebu City'),
      isTrue,
    );
    expect(rules.inServiceArea('Talamban, Cebu City'), isTrue);
    expect(rules.inServiceArea('Poblacion, Consolacion, Cebu'), isTrue);
    expect(rules.inServiceArea('Marigondon, Lapu-Lapu City'), isTrue);
    expect(rules.inServiceArea('Mactan Newtown, Lapulapu'), isTrue);
    expect(rules.inServiceArea('Colon St, Cebu City'), isTrue); // whole city
    expect(rules.inServiceArea('Pusok, Opon, Cebu'), isTrue);
    expect(rules.inServiceArea('Poblacion, Talisay City'), isFalse);
  });

  test('The town is read from the landmark text', () {
    expect(placeIn('Carcar Diversion Road, Dapdap, Carcar, Cebu'), 'Carcar');
    expect(placeIn('Bogo City Hall, Bogo City, Cebu'), 'Bogo City');
    expect(placeIn('Jollibee'), 'Jollibee');
    expect(placeIn(''), isNull);
  });

  test('Pickup dates parse, sort and print', () {
    final d = pickupDatesOf(['2026-10-28', '2026-10-26', 'x', '2026-10-26']);
    expect(sortedDates(d), [DateTime(2026, 10, 26), DateTime(2026, 10, 28)]);
    expect(pickupDateIso(DateTime(2026, 10, 6)), '2026-10-06');
    expect(pickupDateShort(DateTime(2026, 10, 26)), 'Mon, Oct 26');
  });

  test('Only CSWS pickup days from today can be chosen', () {
    const rules = PickupRules(); // Mon to Fri, 30 days ahead
    final now = PickupRules.phNow();
    final today = DateTime(now.year, now.month, now.day);
    var weekday = today;
    while (weekday.weekday > 5) {
      weekday = weekday.add(const Duration(days: 1));
    }
    var weekend = today;
    while (weekend.weekday < 6) {
      weekend = weekend.add(const Duration(days: 1));
    }
    expect(rules.isPickupDate(weekday), isTrue);
    expect(rules.isPickupDate(weekend), isFalse);
    expect(
      rules.isPickupDate(today.subtract(const Duration(days: 1))),
      isFalse,
    );
    expect(rules.isPickupDate(today.add(const Duration(days: 45))), isFalse);
  });

  testWidgets('Outside the areas: sorry, and one tap to Drop Off', (
    tester,
  ) async {
    var dropOff = 0, change = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OutOfAreaNotice(
              place: 'Carcar',
              areas: const PickupRules().serviceAreas,
              onDropOff: () => dropOff++,
              onChangeLandmark: () => change++,
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('Sorry, door-to-door pickup isn’t available in Carcar yet'),
      findsOneWidget,
    );
    // Information, not an error: no red anywhere on the notice.
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(OutOfAreaNotice),
            matching: find.byType(Container),
          )
          .first,
    );
    final scheme = Theme.of(tester.element(find.byType(OutOfAreaNotice)))
        .colorScheme;
    expect(
      (box.decoration as BoxDecoration).color,
      isNot(scheme.errorContainer),
    );
    expect(find.textContaining('current limitation'), findsOneWidget);
    expect(find.textContaining('Lapu-Lapu City'), findsOneWidget);
    await tester.tap(find.text('Switch to Drop Off'));
    await tester.tap(find.text('Choose another landmark'));
    expect((dropOff, change), (1, 1));
  });

  test('A donor with dates is home only on those dates', () {
    final stop = PlanStop.fromJson({
      'stop_id': 'STOP-A',
      'lat': 10.33,
      'lng': 123.94,
      'days': [1, 3],
      'dates': ['2026-10-26'],
      'donations': [],
    });
    expect(stop.availableOn(DateTime(2026, 10, 26)), isTrue);
    expect(stop.availableOn(DateTime(2026, 11, 2)), isFalse); // also a Monday
    expect(stop.availableOn(DateTime(2026, 10, 28)), isFalse);

    // Older entries (weekdays only) still work by weekday.
    final old = PlanStop.fromJson({
      'stop_id': 'STOP-B',
      'lat': 10.33,
      'lng': 123.94,
      'days': [1],
      'donations': [],
    });
    expect(old.availableOn(DateTime(2026, 11, 2)), isTrue);
  });

  // Oct 23 bug: "Choose at least one day..." even with dates chosen. A server
  // not yet updated reads only weekdays, so both are sent.
  testWidgets('Door to Door sends the chosen dates and their weekdays', (
    tester,
  ) async {
    final tue = _next(DateTime.tuesday), wed = _next(DateTime.wednesday);
    Map<String, dynamic>? sent;
    final server = MockClient((req) async {
      if (req.method == 'PUT') {
        sent = Map<String, dynamic>.from(jsonDecode(req.body) as Map);
        return http.Response(jsonEncode({'batch_reference': 'DON-DTD1'}), 200);
      }
      return http.Response(jsonEncode({'detail': 'not mocked'}), 404);
    });
    Api.instance.token = 'test-token';
    addTearDown(() => Api.instance.token = null);
    tester.view.physicalSize = const Size(900, 6000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: DonateScreen(
            report: const {'id': 7, 'disaster': 'Flood', 'barangay': 'Looc'},
            names: Names(_lookups),
            edit: {
              'batch_reference': 'DON-DTD1',
              'handover_method': 'Door to Door',
              'pickup_address': '12 Del Rosario St.',
              'pickup_landmark': 'Oakridge IT Center, Banilad, Mandaue City',
              'pickup_lat': 10.3367,
              'pickup_lng': 123.9142,
              'pickup_dates': [pickupDateIso(wed), pickupDateIso(tue)],
              'items': [
                {'item_id': 3, 'quantity': 10, 'packaging': 'Box'},
              ],
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save changes'));
      await tester.pumpAndSettle();
    }, () => server);
    final dates = [pickupDateIso(tue), pickupDateIso(wed)]..sort();
    expect(sent?['pickup_dates'], dates);
    // Weekdays are sent sorted (Tuesday 2, Wednesday 3), whichever date
    // comes first.
    expect(sent?['pickup_days'], [DateTime.tuesday, DateTime.wednesday]);
  });
}
