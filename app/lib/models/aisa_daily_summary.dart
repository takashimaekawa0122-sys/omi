class AisaDailySummary {
  final String date;
  final String conclusions;
  final String summary;
  final List<String> issues;
  final String sentiment;
  final int entryCount;
  final int generatedAtMs;

  const AisaDailySummary({
    required this.date,
    required this.conclusions,
    required this.summary,
    required this.issues,
    required this.sentiment,
    required this.entryCount,
    required this.generatedAtMs,
  });

  factory AisaDailySummary.fromJson(Map<String, dynamic> json) {
    return AisaDailySummary(
      date: json['date'] as String? ?? '',
      conclusions: json['conclusions'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      issues: (json['issues'] as List<dynamic>?)?.cast<String>() ?? [],
      sentiment: json['sentiment'] as String? ?? '',
      entryCount: json['entryCount'] as int? ?? 0,
      generatedAtMs: json['generatedAtMs'] as int? ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'date': date,
        'conclusions': conclusions,
        'summary': summary,
        'issues': issues,
        'sentiment': sentiment,
        'entryCount': entryCount,
        'generatedAtMs': generatedAtMs,
      };
}
