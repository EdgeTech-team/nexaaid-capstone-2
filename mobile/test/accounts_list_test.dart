// UC-A1: Accounts > Accounts list. Each row opens the account detail
// screen (Edit details, Deactivate). The old ⋮ menu with its limited
// "Edit" dialog (contact number and barangay only) is gone.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile/design/design.dart';
import 'package:mobile/ui/account_detail_screen.dart';
import 'package:mobile/ui/admin_screens.dart';
import 'package:mobile/ui/donation_info.dart' show BarangayDonationInfoScreen;
import 'package:mobile/api.dart';

/// Answers the few API calls these screens make, without a server.
final _server = MockClient((req) async {
  final body = switch (req.url.path) {
    '/admin/users' => [
      {
        'user_id': 7,
        'name': 'Maria Santos',
        'email': 'maria@example.com',
        'role': 'Individual Donor',
        'is_active': true,
        'assigned_barangay': null,
        'organization': null,
      },
    ],
    '/admin/users/7' => {
      'user_id': 7,
      'first_name': 'Maria Santos',
      'last_name': '',
      'email': 'maria@example.com',
      'contact_number': '09170000010',
      'role': 'Individual Donor',
      'is_active': true,
      'id_type': null,
      'created_at': '2026-09-01T08:00:00',
    },
    '/admin/users/7/documents' => <Object>[],
    '/lookups' => {
      'barangays': [
        {'id': 1, 'name': 'Tipolo'},
      ],
    },
    _ => {'detail': 'not mocked: ${req.url.path}'},
  };
  return http.Response(jsonEncode(body), 200);
});

void main() {
  setUpAll(() => AppTheme.useGoogleFonts = false);

  testWidgets('Account rows have no ⋮ menu; tapping opens the detail screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: UsersScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Maria Santos'), findsOneWidget);
      expect(find.byType(PopupMenuButton<String>), findsNothing);
      expect(find.byTooltip('Actions'), findsNothing);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Deactivate'), findsNothing);

      await tester.tap(find.text('Maria Santos'));
      await tester.pumpAndSettle();
      expect(find.byType(AccountDetailScreen), findsOneWidget);
      expect(find.text('Edit details'), findsOneWidget);
      expect(find.text('Deactivate account'), findsOneWidget);
    }, () => _server);
  });

  testWidgets('Accounts has a Donation info section (adviser item 7)', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Api.instance.role = Roles.admin;
    addTearDown(() => Api.instance.role = null);

    await http.runWithClient(() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AccountsHub()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Donation info'));
      await tester.pumpAndSettle();
      expect(find.byType(BarangayDonationInfoScreen), findsOneWidget);
      expect(find.text('Choose a barangay'), findsOneWidget);
    }, () => _server);
  });
}
