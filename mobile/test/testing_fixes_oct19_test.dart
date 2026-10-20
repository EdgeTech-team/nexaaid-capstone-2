// Oct 19 testing fixes: 4.1 (no "sack" as a quantity unit) and the saved
// form drafts (typed text kept after a refresh), and the toasts that
// replace the bottom message bar (X, closes by itself, pauses on hover).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/form_draft.dart';
import 'package:mobile/ui/quantity_units.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('4.1 quantity units', () {
    test('sack is packaging, not a unit', () {
      expect(quantityUnits, isNot(contains('sack')));
      expect(quantityUnits, isNot(contains('sacks')));
      expect(isPackagingUnit('Sacks'), isTrue);
      expect(normalizeUnit('sack'), isNull);
    });

    test('common spellings map to the list', () {
      expect(normalizeUnit('KG'), 'kg');
      expect(normalizeUnit('kilos'), 'kg');
      expect(normalizeUnit('piece'), 'pcs');
      expect(normalizeUnit('Gallon'), 'gallons');
      expect(normalizeUnit(''), isNull);
    });
  });

  group('form drafts', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('saved, loaded, then cleared after submit', () async {
      final draft = FormDraft('donate:1');
      draft.save(
        () => {
          'guest_name': 'Juan',
          'lines': [
            {'qty': '5'},
          ],
        },
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final back = await draft.load();
      expect(back!.str('guest_name'), 'Juan');
      expect(back.maps('lines').single.str('qty'), '5');

      await draft.clear();
      expect(await draft.load(), isNull);
    });

    test('flush keeps the last letters typed before leaving', () async {
      final draft = FormDraft('report');
      draft.save(() => {'description': 'Flood near the chap'});
      draft.flush(() => {'description': 'Flood near the chapel'});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((await draft.load())!.str('description'), 'Flood near the chapel');
    });
  });

  group('toasts', () {
    Future<void> open(
      WidgetTester tester,
      void Function(BuildContext) show,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (c) =>
                  TextButton(onPressed: () => show(c), child: const Text('go')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(Motion.normal);
    }

    testWidgets('closes with its X', (tester) async {
      await open(tester, (c) => AppToast.success(c, 'Report #1 validated'));
      expect(find.text('Report #1 validated'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Report #1 validated'), findsNothing);
    });

    testWidgets('closes by itself when left alone', (tester) async {
      await open(tester, (c) => AppToast.success(c, 'Saved'));
      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Saved'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsNothing);
    });

    testWidgets('waits while the pointer is on it', (tester) async {
      await open(tester, (c) => AppToast.success(c, 'Saved'));
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.text('Saved')));
      await tester.pump(const Duration(seconds: 10));
      expect(find.text('Saved'), findsOneWidget); // paused
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('Saved'), findsNothing);
      await mouse.removePointer();
    });

    testWidgets('a new notification has View, and View opens it', (
      tester,
    ) async {
      var opened = false;
      await open(
        tester,
        (c) => AppToast.show(
          c,
          'Report #7 has been validated.',
          title: 'Report validated',
          action: ToastAction('View', () => opened = true),
        ),
      );
      expect(find.text('Report validated'), findsOneWidget);
      await tester.tap(find.text('View'));
      await tester.pumpAndSettle();
      expect(opened, isTrue);
      expect(find.text('Report validated'), findsNothing);
    });

    testWidgets('no more than 3 at a time, no duplicates', (tester) async {
      await open(tester, (c) {
        for (final m in ['a', 'b', 'b', 'c', 'd']) {
          AppToast.info(c, m);
        }
      });
      expect(AppToast.visibleCount, 3);
      expect(find.text('a'), findsNothing);
      expect(find.text('b'), findsOneWidget);
      AppToast.dismissAll();
      await tester.pumpAndSettle();
    });
  });
}
