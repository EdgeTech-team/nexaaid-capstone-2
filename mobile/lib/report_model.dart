/// One row of GET /reports/monitoring (ReportMonitoringResponse).
///
/// Keys marked (CONFIRM) are my best guess: they weren't visible in the
/// chat export. Check them against your Swagger /docs and rename here only.
class Report {
  final int reportId;
  final String disasterType; // (CONFIRM) 'disaster_type_name'
  final String barangay; // (CONFIRM) 'barangay_name'
  final String? description; // (CONFIRM) 'description'
  final String? assistanceNeeded; // comma-separated text (CONFIRM)
  final int? affectedFamilies;
  final String? priorityLevel; // 3.11
  final String? aiRecommendation; // 3.11
  final DateTime? createdAt;
  final double fulfillmentPercentage; // 0-100, 0 when no fulfillment row yet

  const Report({
    required this.reportId,
    required this.disasterType,
    required this.barangay,
    this.description,
    this.assistanceNeeded,
    this.affectedFamilies,
    this.priorityLevel,
    this.aiRecommendation,
    this.createdAt,
    required this.fulfillmentPercentage,
  });

  /// "Flooding in Barangay Tipolo"
  String get title => '$disasterType in Barangay $barangay';

  /// "Water, ready-to-eat food" -> ['Water', 'ready-to-eat food']
  List<String> get needs => (assistanceNeeded ?? '')
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  factory Report.fromJson(Map<String, dynamic> j) {
    return Report(
      reportId: j['report_id'] as int,
      disasterType: (j['disaster_type_name'] ?? 'Report') as String,
      barangay: (j['barangay_name'] ?? '') as String,
      description: j['description'] as String?,
      assistanceNeeded: j['assistance_needed'] as String?,
      affectedFamilies: j['affected_families'] as int?,
      priorityLevel: j['priority_level'] as String?,
      aiRecommendation: j['ai_recommendation'] as String?,
      createdAt: DateTime.tryParse((j['created_at'] ?? '') as String),
      // Pydantic serializes Decimal as a STRING ("75.00"), so parse both.
      fulfillmentPercentage: _toDouble(j['fulfillment_percentage']) ?? 0,
    );
  }

  static double? _toDouble(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }
}
