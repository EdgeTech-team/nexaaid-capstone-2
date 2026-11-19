// UI redesign (Nov 2026): the logo, the SVG icon set, the nav bar using it,
// and the sort sheet.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';

Widget _app(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: Center(child: child)),
);

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('logo tile draws the SVG logo', (tester) async {
    await tester.pumpWidget(_app(const NexaAidLogoTile(size: 40)));
    expect(find.byType(SvgPicture), findsOneWidget);
    expect(find.bySemanticsLabel('NexaAid'), findsOneWidget);
  });

  test('every bottom-menu tab has an icon in the set', () {
    for (final label in [
      'Dashboard', 'Overview', 'Reports', 'My giving', 'Profile', 'Validate',
      'Encode SMS', 'Monitoring', 'Records', 'Accounts', 'Logistics',
      'Deliveries', 'New report', 'SMS report', 'Receive', 'Pickups',
      'Acknowledge', 'History', 'Incoming aid', 'Donation info',
    ]) {
      final name = appIconForTab(label);
      expect(name, isNotNull, reason: label);
      expect(AppIcon.has(name!), isTrue, reason: label);
    }
    expect(appIconForTab('Something new'), isNull);
  });

  testWidgets('nav bar uses the SVG icon and keeps the label', (tester) async {
    var picked = -1;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          bottomNavigationBar: FloatingNavBar(
            selectedIndex: 0,
            onSelected: (i) => picked = i,
            items: const [
              FloatingNavItem(Icons.dashboard_outlined, 'Overview', art: 'dashboard'),
              FloatingNavItem(Icons.qr_code_scanner, 'Receive', art: 'qrscan'),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(AppIcon), findsNWidgets(2));
    expect(find.byIcon(Icons.qr_code_scanner), findsNothing);
    await tester.tap(find.bySemanticsLabel('Receive'));
    expect(picked, 1);
  });

  testWidgets('sort sheet returns the picked option', (tester) async {
    String? result;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => SortButton(
            current: 'Item A–Z',
            onPressed: () async {
              result = await showSortSheet<String>(
                context,
                selected: 'item_az',
                options: const [
                  SortOption('item_az', 'Item A–Z'),
                  SortOption('quantity_high', 'Quantity: high to low'),
                ],
              );
            },
          ),
        ),
      ),
    );
    expect(find.text('Sort: Item A–Z'), findsOneWidget);
    await tester.tap(find.byType(SortButton));
    await tester.pumpAndSettle();
    expect(find.text('Sort by'), findsOneWidget);
    await tester.tap(find.text('Quantity: high to low'));
    await tester.pumpAndSettle();
    expect(result, 'quantity_high');
  });

  test('tints pass 4.5:1', () {
    double lum(Color c) {
      double ch(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
    }

    for (final t in [
      AppTints.amber,
      AppTints.blue,
      AppTints.red,
      AppTints.green,
      AppTints.teal,
      AppTints.neutral,
    ]) {
      final ratio = (lum(t.bg) + 0.05) / (lum(t.fg) + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: '${t.fg} on ${t.bg}');
    }
  });
}
