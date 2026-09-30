import 'package:flutter/material.dart';

import 'api.dart';
import 'ui/home.dart';
import 'ui/login_screen.dart';

void main() {
  runApp(const NexaAidApp());
}

class NexaAidApp extends StatelessWidget {
  const NexaAidApp({super.key});

  @override
  Widget build(BuildContext context) {
    const brand = Color(0xFF00695C);
    return MaterialApp(
      title: 'NexaAid',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: brand),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
        ),
        cardTheme: const CardThemeData(elevation: 0.5),
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
