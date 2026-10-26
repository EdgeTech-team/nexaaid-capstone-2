// Oct 23 (Dave): a donor adds items to a pledged donation (same QR) or
// removes one after a strong warning; CSWS sees the batches and why an item
// was removed, when scanning and without scanning.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/batch_sheet.dart';
import 'package:mobile/ui/donate_screen.dart';
import 'package:mobile/ui/donor_dashboard.dart';
import 'package:mobile/ui/widgets.dart' show Names;

Map<String, dynamic> _item(int id, String name, int batch, {String? removed}) =>
    {
      'donation_id': id,
      'qr_reference': 'DON-ADD-$id',
      'item_name': name,
      'quantity': 5,
      'unit': 'pcs',
      'packaging': 'Box',
      'status': removed == null ? 'Pending' : 'Cancelled',
      'addition_no': batch,
      'added_later': batch > 1,
      'added_at': '2026-10-23T08:00:00Z',
      'removed_by_donor': removed != null,
      'removed_reason': removed,
      'actual_quantity_received': null,
    };

/// Rice pledged first; canned goods and water added later; water removed.
final _entry = <String, dynamic>{
  'batch_reference': 'DON-ADD',
  'report_id': 2,
  'report_label': '#2 Flood - Banilad',
  'status': 'Pending',
  'handover_method': 'Drop Off',
  'created_at': '2026-10-20T08:00:00Z',
  'donor': 'Ana Cruz',
  'total_items': 3,
  'pending_items': 2,
  'removed_items': 1,
  'removed_notes': [
    {'item_name': 'Bottled water', 'reason': 'Expired stock'},
  ],
  'summary_text': '2 pending · 1 removed',
  'can_change_items': true,
  'change_blocked_reason': null,
  'items': [
    _item(1, 'Rice', 1),
    _item(2, 'Canned goods', 2),
    _item(3, 'Bottled water', 2, removed: 'Expired stock'),
  ],
};

Widget _app(Widget home) => MaterialApp(theme: AppTheme.light(), home: home);

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Remove warns, and needs a reason and "I am sure"', (
    tester,
  ) async {
    String? reason = 'not asked';
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => reason = await confirmRemoveItem(
                context,
                _item(2, 'Canned goods', 2),
                'DON-ADD',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Remove this item?'), findsOneWidget);
    expect(find.textContaining('Are you sure'), findsOneWidget);
    expect(find.textContaining('cannot be undone'), findsOneWidget);

    bool enabled() => tester
        .widget<FilledButton>(
          find.ancestor(
            of: find.text('Remove item'),
            matching: find.byWidgetPredicate((w) => w is FilledButton),
          ),
        )
        .enabled;
    expect(enabled(), isFalse);
    await tester.enterText(find.byType(TextField), 'Expired stock');
    await tester.pump();
    expect(enabled(), isFalse); // still needs the tick
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(enabled(), isTrue);
    await tester.tap(find.text('Remove item'));
    await tester.pumpAndSettle();
    expect(reason, 'Expired stock');
  });

  for (final open in [true, false]) {
    testWidgets(
      'Donor page: batches, removed note, ${open ? 'Add items and Remove' : 'locked once picked up'}',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 7200);
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final entry = {
          ..._entry,
          'can_change_items': open,
          'change_blocked_reason': open
              ? null
              : 'CSWS has already picked up or received this donation, so '
                    'it can no longer be changed.',
        };
        final server = MockClient(
          (req) async => http.Response(jsonEncode({}), 200),
        );
        await http.runWithClient(() async {
          await tester.pumpWidget(_app(DonationDetailScreen(entry: entry)));
          await tester.pumpAndSettle();
          expect(find.text('Batch 1'), findsOneWidget);
          expect(find.text('Batch 2'), findsOneWidget);
          expect(find.text('Added later'), findsOneWidget);
          expect(find.text('1 item removed by the donor'), findsOneWidget);
          expect(find.text('Bottled water: Expired stock'), findsOneWidget);
          expect(
            find.text('Want to add more?'),
            open ? findsOneWidget : findsNothing,
          );
          expect(find.text('Add items'), open ? findsOneWidget : findsNothing);
          // Still waiting: it can be cancelled (never deleted). Items were
          // added later, so the whole-list edit is not offered.
          expect(find.text('Cancel donation'), findsOneWidget);
          expect(find.text('Delete donation'), findsNothing);
          expect(find.text('Update details'), findsNothing);
          expect(
            find.byTooltip('Remove Rice'),
            open ? findsOneWidget : findsNothing,
          );
          expect(find.byTooltip('Remove Bottled water'), findsNothing);
          expect(
            find.textContaining('can no longer be changed'),
            open ? findsNothing : findsOneWidget,
          );
        }, () => server);
      },
    );
  }

  testWidgets('Cancel, not delete: a reason, or Others with why; no red', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    Map<String, dynamic>? cancelled;
    final server = MockClient((req) async {
      if (req.url.path.endsWith('/cancel')) {
        cancelled = Map<String, dynamic>.from(jsonDecode(req.body) as Map);
        return http.Response(jsonEncode({'cancelled_items': 1}), 200);
      }
      if (req.url.path == '/donations/expiry-rules') {
        return http.Response(
          jsonEncode({
            'cancel_reasons': [
              'I changed my mind',
              'I cannot bring them in time',
            ],
          }),
          200,
        );
      }
      return http.Response(jsonEncode({}), 200);
    });
    final plain = {
      ..._entry,
      'removed_items': 0,
      'removed_notes': [],
      'items': [_item(1, 'Rice', 1)],
    };
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(DonationDetailScreen(entry: plain)));
      await tester.pumpAndSettle();
      expect(find.text('Want to add more?'), findsOneWidget);
      expect(find.text('Update details'), findsOneWidget);
      expect(find.text('Edit donation'), findsNothing);
      expect(find.byTooltip('Remove Rice'), findsNothing); // the only item
      final cancelBtn = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Cancel donation'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(
        cancelBtn.style?.foregroundColor?.resolve({}),
        isNot(AppColors.danger),
      );

      await tester.tap(find.text('Cancel donation'));
      await tester.pumpAndSettle();
      expect(find.text('Cancel this donation?'), findsOneWidget);
      expect(find.text('I changed my mind'), findsOneWidget);
      bool canConfirm() => tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('Yes, cancel it'),
              matching: find.byWidgetPredicate((w) => w is FilledButton),
            ),
          )
          .enabled;
      expect(canConfirm(), isFalse); // a reason is required
      await tester.tap(find.text('Others'));
      await tester.pumpAndSettle();
      expect(find.text('Please specify why'), findsOneWidget);
      expect(canConfirm(), isFalse);
      await tester.enterText(find.byType(TextField), 'Typhoon, roads closed');
      await tester.pump();
      expect(canConfirm(), isTrue);
      await tester.tap(find.text('Yes, cancel it'));
      await tester.pumpAndSettle();
    }, () => server);
    expect(cancelled?['reason'], 'Typhoon, roads closed');
  });

  testWidgets('Add items: same QR, and keep at least one item', (tester) async {
    tester.view.physicalSize = const Size(1080, 4800);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final server = MockClient(
      (req) async => http.Response(jsonEncode({'detail': 'x'}), 404),
    );
    await http.runWithClient(() async {
      await tester.pumpWidget(
        _app(
          DonateScreen(
            report: const {'id': 2, 'disaster': 'Flood', 'barangay': 'Banilad'},
            names: Names(const {'items': []}),
            addTo: _entry,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Adding to DON-ADD'), findsOneWidget);
      expect(
        find.textContaining(
          'Keep at least one item in your donation.',
          findRichText: true,
        ),
        findsOneWidget,
      );
    }, () => server);
  });

  // Oct 25: the CMO's acknowledgement is not a donor step.
  testWidgets('Donor: an acknowledged donation reads as received', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 7200);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final acknowledged = {
      ..._entry,
      'status': 'Confirmed',
      'can_change_items': false,
      'removed_items': 0,
      'removed_notes': [],
      'items': [
        {..._item(1, 'Rice', 1), 'status': 'Confirmed'},
        {..._item(2, 'Canned goods', 1), 'status': 'Received'},
      ],
    };
    final server = MockClient(
      (req) async => http.Response(jsonEncode({}), 200),
    );
    await http.runWithClient(() async {
      await tester.pumpWidget(_app(DonationDetailScreen(entry: acknowledged)));
      await tester.pumpAndSettle();
      expect(find.textContaining('CMO'), findsNothing);
      expect(find.textContaining('Acknowledged'), findsNothing);
      expect(find.text('Received'), findsOneWidget); // the status chip
      expect(find.text('Received by CSWS'), findsOneWidget); // the timeline
    }, () => server);
  });

  testWidgets('CSWS scan: batches, summary, why an item was removed', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SingleChildScrollView(
            child: BatchSheet({
              ..._entry,
              'history': [
                {
                  'action': 'ADD DONATION ITEMS',
                  'by': 'Ana Cruz',
                  'at': '2026-10-23T08:00:00Z',
                },
              ],
            }),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Batch 1'), findsOneWidget);
    expect(find.text('Original pledge'), findsOneWidget);
    expect(find.text('Added later'), findsOneWidget);
    expect(find.text('2 pending · 1 removed'), findsOneWidget);
    expect(find.text('Bottled water: Expired stock'), findsOneWidget);
    expect(find.text('Removed by the donor: Expired stock'), findsOneWidget);
    // Only the two waiting items can be received; a removed item is not
    // "reopened" either.
    expect(
      find.widgetWithText(TextFormField, 'Actual quantity received'),
      findsNWidgets(2),
    );
    expect(find.text('Reopen so it can be received'), findsNothing);
    expect(find.text('History (1)'), findsOneWidget);
  });
}
