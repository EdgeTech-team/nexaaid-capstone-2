import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/design/gallery_screen.dart';

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  test('Each status always gets the same color', () {
    expect(StatusColors.base('In Transit'), StatusColors.base('in transit'));
    expect(StatusColors.base('Received'), isNot(StatusColors.base('Pending')));
    // Every step of the donation timeline has its own color.
    final colors = donationLifecycle.map(StatusColors.base).toSet();
    expect(colors.length, donationLifecycle.length);
  });

  test('Priorities sort Critical first, unknown last', () {
    final list = ['Low', null, 'Critical', 'Medium', 'High'];
    list.sort(
      (a, b) => PriorityColors.rank(a).compareTo(PriorityColors.rank(b)),
    );
    expect(list, ['Critical', 'High', 'Medium', 'Low', null]);
  });

  for (final dark in [false, true]) {
    testWidgets('Gallery builds in ${dark ? 'dark' : 'light'} mode', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: const DesignGalleryScreen(),
        ),
      );
      await tester.pump();
      expect(find.text('Design system'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Core components fit a phone at 200% text size', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 800),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              padding: Space.page,
              child: Column(
                children: [
                  const StatCardGrid([
                    StatCard(
                      label: 'Families affected',
                      value: '1,284',
                      icon: Icons.groups,
                    ),
                    StatCard(
                      label: 'Reports needing help',
                      value: '12',
                      icon: Icons.campaign,
                    ),
                  ]),
                  Gaps.v16,
                  const FulfillmentBar(delivered: 40, needed: 100),
                  Gaps.v16,
                  const StatusTimeline(
                    steps: donationLifecycle,
                    labels: donationLifecycleLabels,
                    current: 'Delivered',
                  ),
                  Gaps.v16,
                  const Wrap(
                    children: [
                      StatusChip('In Transit'),
                      PriorityChip('Critical'),
                    ],
                  ),
                  Gaps.v16,
                  AppButton(
                    'Donate to this report',
                    icon: Icons.favorite,
                    expand: true,
                    onPressed: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Timeline tells screen readers the current step', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: StatusTimeline(
            steps: donationLifecycle,
            labels: donationLifecycleLabels,
            current: 'Confirmed',
          ),
        ),
      ),
    );
    expect(
      find.bySemanticsLabel('Status: Acknowledged by CMO, step 3 of 6'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('Password field has a show/hide button', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: AppTextField(label: 'Password', password: true),
        ),
      ),
    );
    expect(find.byTooltip('Show password'), findsOneWidget);
    await tester.tap(find.byTooltip('Show password'));
    await tester.pump();
    expect(find.byTooltip('Hide password'), findsOneWidget);
  });
}
