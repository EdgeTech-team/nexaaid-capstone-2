import 'package:flutter/material.dart';

import 'api.dart';
import 'ui/home.dart';
import 'ui/login_screen.dart';
import 'ui/widgets.dart' show Brand;

void main() {
  runApp(const NexaAidApp());
}

class NexaAidApp extends StatelessWidget {
  const NexaAidApp({super.key});

  @override
  Widget build(BuildContext context) {
    // Colors and shapes follow the Capstone 1 wireframes (manuscript
    // Figures 44-53): pink brand, white cards with light borders.
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.pink,
      primary: Brand.pink,
      onPrimary: Colors.white,
      surface: Colors.white,
    );
    final rounded = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(10),
    );
    return MaterialApp(
      title: 'NexaAid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: Brand.page,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: Brand.ink,
          surfaceTintColor: Colors.white,
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: Border(bottom: BorderSide(color: Brand.line)),
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          surfaceTintColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: Brand.line),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Brand.line),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Brand.line),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: Brand.pink, width: 1.5),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: Brand.pink,
            foregroundColor: Colors.white,
            shape: rounded,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Brand.pinkDark,
            side: const BorderSide(color: Brand.pink),
            shape: rounded,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: Brand.pinkDark),
        ),
        chipTheme: const ChipThemeData(
          side: BorderSide(color: Brand.line),
          selectedColor: Brand.pinkSoft,
        ),
        navigationBarTheme: const NavigationBarThemeData(
          backgroundColor: Colors.white,
          indicatorColor: Brand.pinkSoft,
        ),
        dividerTheme: const DividerThemeData(color: Brand.line),
      ),
      // Login first; after login (or "Donate as guest") the home screen
      // shows the menu for that role.
      home: ListenableBuilder(
        listenable: Api.instance,
        builder: (context, _) {
          final api = Api.instance;
          return api.loggedIn || api.guest
              ? RoleHome(key: ValueKey(api.role ?? 'guest'))
              : const LoginScreen();
        },
      ),
    );
  }
}
