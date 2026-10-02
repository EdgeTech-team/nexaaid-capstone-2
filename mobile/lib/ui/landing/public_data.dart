import '../../api.dart';
import '../../design/status.dart';

/// Numbers for the "Right now in Mandaue" strip on the landing page.
class PublicStats {
  final int activeReports;
  final int familiesAffected;
  final int urgentReports; // Critical + High
  final int barangays;
  final int? donationsReceived; // only from /public/stats
  final int? deliveriesCompleted; // only from /public/stats

  const PublicStats({
    required this.activeReports,
    required this.familiesAffected,
    required this.urgentReports,
    required this.barangays,
    this.donationsReceived,
    this.deliveriesCompleted,
  });

  factory PublicStats.fromReports(List<Map<String, dynamic>> reports) {
    return PublicStats(
      activeReports: reports.length,
      familiesAffected: reports.fold<int>(
        0,
        (s, r) => s + ((r['affected_families'] as num?)?.toInt() ?? 0),
      ),
      urgentReports: reports
          .where(
            (r) => PriorityColors.rank(r['priority_level'] as String?) <= 1,
          )
          .length,
      barangays: reports.map((r) => r['barangay']).toSet().length,
    );
  }

  /// Agreed shape of GET /public/stats (Mariquit, Item 8):
  /// {active_reports, families_affected, urgent_reports, barangays,
  ///  donations_received, deliveries_completed}
  factory PublicStats.fromJson(
    Map<String, dynamic> j,
    List<Map<String, dynamic>> reports,
  ) {
    final fallback = PublicStats.fromReports(reports);
    int? n(String k) => (j[k] as num?)?.toInt();
    return PublicStats(
      activeReports: n('active_reports') ?? fallback.activeReports,
      familiesAffected: n('families_affected') ?? fallback.familiesAffected,
      urgentReports: n('urgent_reports') ?? fallback.urgentReports,
      barangays: n('barangays') ?? fallback.barangays,
      donationsReceived: n('donations_received'),
      deliveriesCompleted: n('deliveries_completed'),
    );
  }
}

class PublicSnapshot {
  final List<Map<String, dynamic>> reports; // sorted, most urgent first
  final PublicStats stats;
  const PublicSnapshot(this.reports, this.stats);
}

class PublicDataError implements Exception {
  final int status;
  final String detail;
  const PublicDataError(this.status, this.detail);
}

/// Loads what a visitor sees before signing in.
///
/// Uses Mariquit's public endpoints (`/public/reports`, `/public/stats`)
/// when they exist. Until they are merged (they return 404), it falls back
/// to the validated reports in the public `/lookups`, so the landing page
/// works today and switches over without a code change.
///
/// Each report uses the same keys as `/lookups` validated_reports, so it
/// can be passed straight to DonateScreen:
/// id, disaster, barangay, sitio, priority_level, assistance_needed,
/// affected_families, description, total_items_needed,
/// total_items_delivered, fulfillment_percentage.
Future<PublicSnapshot> loadPublicData(Api api) async {
  final results = await Future.wait([
    api.get('/public/reports'),
    api.get('/public/stats'),
  ]);
  final reportsRes = results[0], statsRes = results[1];

  List<Map<String, dynamic>> reports;
  if (reportsRes.ok && reportsRes.json is List) {
    reports = _normalize(reportsRes.json as List);
  } else if (reportsRes.status == 404 || reportsRes.status == 405) {
    final lk = await api.lookupsResult();
    if (!lk.ok || lk.json is! Map) {
      throw PublicDataError(lk.status, lk.errorText);
    }
    reports = _normalize((lk.json as Map)['validated_reports'] as List? ?? []);
  } else {
    throw PublicDataError(reportsRes.status, reportsRes.errorText);
  }

  reports.sort((a, b) {
    final p = PriorityColors.rank(a['priority_level'] as String?)
        .compareTo(PriorityColors.rank(b['priority_level'] as String?));
    if (p != 0) return p;
    // Same priority: least fulfilled first.
    return ((a['fulfillment_percentage'] as num?) ?? 0).compareTo(
      (b['fulfillment_percentage'] as num?) ?? 0,
    );
  });

  final stats = statsRes.ok && statsRes.json is Map
      ? PublicStats.fromJson(
          Map<String, dynamic>.from(statsRes.json as Map),
          reports,
        )
      : PublicStats.fromReports(reports);
  return PublicSnapshot(reports, stats);
}

List<Map<String, dynamic>> _normalize(List raw) => [
  for (final r in raw)
    if (r is Map)
      {
        ...Map<String, dynamic>.from(r),
        // Accept report_id from /public/reports; DonateScreen reads 'id'.
        'id': r['id'] ?? r['report_id'],
      },
];
