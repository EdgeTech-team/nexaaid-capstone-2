import 'package:flutter/material.dart';

import 'account_tab.dart';
import 'api.dart';
import 'checks_tab.dart';
import 'modules.dart';

void main() {
  runApp(const NexaAidApp());
}

class NexaAidApp extends StatelessWidget {
  const NexaAidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NexaAid Test',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const HomeShell(),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final api = Api.instance;
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: api,
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('NexaAid Test'),
              Text(
                api.loggedIn
                    ? '${api.email} - ${api.role ?? "..."}'
                    : 'Not logged in (guest)',
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      body: IndexedStack(
        index: index,
        children: const [AccountTab(), ModulesTab(), ChecksTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.person_outline), label: 'Account'),
          NavigationDestination(
              icon: Icon(Icons.apps_outlined), label: 'Modules'),
          NavigationDestination(
              icon: Icon(Icons.fact_check_outlined), label: 'Checks'),
        ],
      ),
    );
  }
}

/// Lists every module. The ones for the logged-in role come first;
/// the rest stay tappable so you can confirm they are blocked (403).
class ModulesTab extends StatelessWidget {
  const ModulesTab({super.key});

  @override
  Widget build(BuildContext context) {
    final api = Api.instance;
    return ListenableBuilder(
      listenable: api,
      builder: (context, _) {
        final mine = modules.where((m) => m.isFor(api)).toList();
        final others = modules.where((m) => !m.isFor(api)).toList();
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Text(
                api.loggedIn
                    ? 'For ${api.role ?? "?"}'
                    : 'For guests (log in on the Account tab for more)',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final m in mine) _tile(context, m, true),
            if (others.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text('Other roles\' modules (should be blocked for you)',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              for (final m in others) _tile(context, m, false),
            ],
          ],
        );
      },
    );
  }

  Widget _tile(BuildContext context, Module m, bool mine) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      color: mine ? null : Theme.of(context).colorScheme.surfaceContainerLow,
      child: ListTile(
        leading: Icon(m.icon, color: mine ? null : Colors.grey),
        title: Text(m.title),
        subtitle: Text('Module ${m.code}  -  ${m.roles.join(", ")}'
            '${m.guest ? ", guest" : ""}'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () =>
            Navigator.of(context).push(MaterialPageRoute(builder: m.builder)),
      ),
    );
  }
}
