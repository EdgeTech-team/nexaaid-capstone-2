import 'package:flutter/material.dart';

import 'report_model.dart';
import 'report_api.dart';
import 'nexa_widgets.dart';
import 'report_detail_screen.dart';

/// Screen 1: "Validated post-disaster reports" browse list.
class ReportListScreen extends StatefulWidget {
  final ReportApi api;
  const ReportListScreen({super.key, required this.api});

  @override
  State<ReportListScreen> createState() => _ReportListScreenState();
}

class _ReportListScreenState extends State<ReportListScreen> {
  late Future<List<Report>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.fetchReports();
  }

  Future<void> _reload() async {
    setState(() {
      _future = widget.api.fetchReports();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return GradientPage(
      child: Column(
        children: [
          const NexaHeader(
            actions: [HeaderPill(label: 'Log In', filled: true)],
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: FutureBuilder<List<Report>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return _Message(
                      text: 'Could not load reports.\n${snap.error}',
                      onRetry: _reload,
                    );
                  }
                  final reports = snap.data!;
                  return ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                    itemCount: reports.isEmpty ? 2 : reports.length + 1,
                    itemBuilder: (context, i) {
                      if (i == 0) return const _Intro();
                      if (reports.isEmpty) {
                        return const Padding(
                          padding: EdgeInsets.only(top: 40),
                          child: Center(
                            child: Text('No validated reports yet.'),
                          ),
                        );
                      }
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _ReportCard(report: reports[i - 1]),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Intro extends StatelessWidget {
  const _Intro();
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Text(
              'SEE WHAT’S HAPPENING BEFORE YOU SIGN IN',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
            ),
          ),
          SizedBox(height: 6),
          Center(
            child: Text(
              'Browse live relief operations and donate directly - '
              'no account needed.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13),
            ),
          ),
          SizedBox(height: 20),
          Text(
            'Validated post-disaster reports',
            style: TextStyle(fontSize: 17),
          ),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final Report report;
  const _ReportCard({required this.report});

  @override
  Widget build(BuildContext context) {
    return WhiteCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  report.disasterType,
                  style: const TextStyle(fontSize: 24),
                ),
              ),
              PriorityBadge(level: report.priorityLevel),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            report.title,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
          ),
          if (report.needs.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(report.needs.join(', '), style: const TextStyle(fontSize: 14)),
          ],
          const SizedBox(height: 12),
          FulfillmentBar(percent: report.fulfillmentPercentage),
          const SizedBox(height: 10),
          InkWell(
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ReportDetailScreen(report: report),
              ),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('View Details', style: TextStyle(fontSize: 12)),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_right_alt, size: 22),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;
  const _Message({required this.text, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 120),
        Center(child: Text(text, textAlign: TextAlign.center)),
        const SizedBox(height: 12),
        Center(
          child: ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
        ),
      ],
    );
  }
}
