import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:omi/models/aisa_daily_summary.dart';
import 'package:omi/services/aisa_firestore_service.dart';
import 'package:omi/utils/aisa_debug_logger.dart';

class AisaSummaryService {
  AisaSummaryService._();
  static final AisaSummaryService instance = AisaSummaryService._();

  static const _claudeEndpoint = 'https://api.anthropic.com/v1/messages';
  static const _anthropicApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');

  int _lastEntryCount = -1;

  /// 今日の全会話を要約する。新しい会話がなければスキップ。
  Future<AisaDailySummary?> generateDailySummary() async {
    if (_anthropicApiKey.isEmpty) {
      debugPrint('[AISA Summary] ANTHROPIC_API_KEY未設定');
      return null;
    }

    try {
      // 今日のエントリを取得
      final entries = await AisaFirestoreService.instance.loadRecentEntries(days: 1);
      if (entries.isEmpty) {
        debugPrint('[AISA Summary] 今日のエントリなし → スキップ');
        return null;
      }

      // エントリ数が変わっていなければスキップ
      if (entries.length == _lastEntryCount) {
        debugPrint('[AISA Summary] エントリ数変化なし (${entries.length}) → スキップ');
        return null;
      }

      // 合計文字数チェック
      final totalChars = entries.fold<int>(0, (sum, e) => sum + e.text.length);
      if (totalChars < 100) {
        debugPrint('[AISA Summary] テキスト量不足 (${totalChars}文字) → スキップ');
        return null;
      }

      // 会話テキストを結合
      final conversationText = entries.map((e) {
        final time = '${e.timestamp.hour.toString().padLeft(2, '0')}:${e.timestamp.minute.toString().padLeft(2, '0')}';
        return '【$time】\n${e.text}';
      }).join('\n\n');

      // Claude Haikuで要約生成
      final summary = await _callClaude(conversationText, entries.length);
      if (summary == null) return null;

      _lastEntryCount = entries.length;

      // Firestoreに保存
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      await AisaFirestoreService.instance.saveSummary(dateStr, summary);

      AisaDebugLogger.instance.info('[Summary] 要約生成完了 (${entries.length}件の会話)');
      return summary;
    } catch (e) {
      debugPrint('[AISA Summary] 生成失敗: $e');
      AisaDebugLogger.instance.error('[Summary] 生成失敗: $e');
      return null;
    }
  }

  /// Firestoreから今日の要約を読み込む
  Future<AisaDailySummary?> loadTodaySummary() async {
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    return AisaFirestoreService.instance.loadSummary(dateStr);
  }

  Future<AisaDailySummary?> _callClaude(String conversationText, int entryCount) async {
    const prompt = '''あなたは日本語の会話分析アシスタントです。以下は今日の会話記録です。
構造化された分析レポートをJSON形式で出力してください。

【重要】
・会話の内容が薄い、意味のある情報がない場合は「null」とだけ返してください
・実質的な会話内容がある場合のみ分析してください

【出力形式（JSONのみ、説明不要）】
{
  "conclusions": "今日の会話全体から導かれる結論・要点（2-3文）",
  "summary": "会話内容の要約（5文以内）",
  "issues": ["課題やTODO項目1", "課題やTODO項目2"],
  "sentiment": "全体的な感情分析（ポジティブ/ネガティブ/ニュートラル + 簡単な理由）"
}

【会話記録】
''';

    try {
      final response = await http.post(
        Uri.parse(_claudeEndpoint),
        headers: {
          'x-api-key': _anthropicApiKey,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: jsonEncode({
          'model': 'claude-haiku-4-5-20251001',
          'max_tokens': 1024,
          'temperature': 0.2,
          'messages': [
            {'role': 'user', 'content': '$prompt$conversationText'},
          ],
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        debugPrint('[AISA Summary] Claude API失敗 ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final text = (json['content'] as List<dynamic>?)
          ?.whereType<Map<String, dynamic>>()
          .firstWhere((c) => c['type'] == 'text', orElse: () => {})['text'] as String?;

      if (text == null || text.trim() == 'null' || text.trim().isEmpty) {
        debugPrint('[AISA Summary] Claude判定: 要約不要');
        return null;
      }

      // JSON部分を抽出（Claudeが前後にテキストを付けることがある）
      final jsonMatch = RegExp(r'\{[\s\S]*\}').firstMatch(text.trim());
      if (jsonMatch == null) {
        debugPrint('[AISA Summary] JSON解析失敗: $text');
        return null;
      }

      final summaryJson = jsonDecode(jsonMatch.group(0)!) as Map<String, dynamic>;
      final now = DateTime.now();
      final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

      return AisaDailySummary(
        date: dateStr,
        conclusions: summaryJson['conclusions'] as String? ?? '',
        summary: summaryJson['summary'] as String? ?? '',
        issues: (summaryJson['issues'] as List<dynamic>?)?.cast<String>() ?? [],
        sentiment: summaryJson['sentiment'] as String? ?? '',
        entryCount: entryCount,
        generatedAtMs: now.millisecondsSinceEpoch,
      );
    } catch (e) {
      debugPrint('[AISA Summary] Claude呼び出し失敗: $e');
      return null;
    }
  }
}
