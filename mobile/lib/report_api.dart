import 'api.dart';
import 'report_model.dart';

class ReportApi {
  /// Same endpoint the team's validated-reports list uses.
  final String path;

  const ReportApi({this.path = '/reports/validated'});

  Future<List<Report>> fetchReports({String? priorityLevel}) async {
    final r = await Api.instance.get(
      path,
      query: {'priority_level': ?priorityLevel},
    );
    if (!r.ok) {
      throw Exception(
        r.status == 0
            ? r.raw
            : 'Failed to load reports (${r.status}): ${r.errorText}',
      );
    }
    if (r.json is! List) {
      throw Exception('Unexpected response from $path');
    }
    final lookups = await Api.instance.lookups();
    return (r.json as List).map((e) {
      final j = e as Map<String, dynamic>;
      return Report(
        reportId: j['report_id'] as int,
        disasterType: _name(lookups, 'disaster_types', j['disaster_type_id']),
        barangay: _name(lookups, 'barangays', j['barangay_id']),
        description: j['description'] as String?,
        assistanceNeeded: '${j['assistance_needed'] ?? ''}',
        priorityLevel: '${j['priority_level'] ?? ''}',
        aiRecommendation: j['ai_recommendation'] as String?,
        priorityGuidance: j['priority_guidance'] as String?,
        createdAt:
            DateTime.tryParse('${j['created_at'] ?? ''}') ?? DateTime.now(),
        fulfillmentPercentage:
            (num.tryParse('${j['fulfillment_percentage']}') ?? 0).toDouble(),
      );
    }).toList();
  }

  static String _name(Map<String, dynamic> lookups, String list, dynamic id) {
    for (final row in (lookups[list] as List? ?? const [])) {
      if ('${row['id']}' == '$id') return '${row['name']}';
    }
    return 'Unknown';
  }
}
