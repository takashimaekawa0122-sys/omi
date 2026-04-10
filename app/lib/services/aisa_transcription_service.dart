// app/lib/services/aisa_transcription_service.dart
//
// A.I.S.A. Groq Whisper 文字起こしサービス
// 音声フレームをWAVに変換し、Groq Whisper APIで文字起こしして Firestore に保存する

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:omi/services/aisa_firestore_service.dart';
import 'package:omi/utils/aisa_debug_logger.dart';

class AisaTranscriptionService {
  AisaTranscriptionService._();
  static final AisaTranscriptionService instance = AisaTranscriptionService._();

  static const _endpoint = 'https://api.groq.com/openai/v1/audio/transcriptions';
  static const _groqApiKey = String.fromEnvironment('GROQ_API_KEY');

  static const _claudeEndpoint = 'https://api.anthropic.com/v1/messages';
  static const _anthropicApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');

  /// 音声ファイルを文字起こししてFirestoreに保存し、テキストを返す
  /// Firestore保存に失敗してもトランスクリプトはUIに返す（保存失敗で表示も消えるバグを修正）
  Future<String?> processAndSave(File wavFile) async {
    try {
      final transcript = await _transcribe(wavFile);
      if (transcript != null && transcript.trim().isNotEmpty) {
        // Firestoreへの保存失敗はログのみ — UIへの表示はFirestore成功・失敗に関係なく行う
        try {
          await AisaFirestoreService.instance.saveTranscript(transcript);
        } catch (saveError) {
          debugPrint('[AISA] Firestore保存失敗（UIには表示）: $saveError');
          AisaDebugLogger.instance.warning('⚠ Firestore保存失敗（UIには表示）: $saveError');
        }
        debugPrint('[AISA] 文字起こし成功: $transcript');
        return transcript;
      }
      return null;
    } catch (e) {
      debugPrint('[AISA] 文字起こし処理失敗: $e');
      AisaDebugLogger.instance.error('❌ 文字起こし処理失敗: $e');
      return null;
    } finally {
      try {
        if (await wavFile.exists()) {
          await wavFile.delete();
        }
      } catch (_) {}
    }
  }

  /// 文字起こしのみ行い、Firestoreには保存しない
  /// [previousContext]: 直前チャンクの末尾テキスト（Whisperプロンプトに付加して文脈を提供）
  /// 失敗時は例外をthrow（呼び出し元でリトライ処理するため）
  /// WAVファイルの削除は呼び出し元の責任
  Future<String?> transcribeOnly(File wavFile, {String? previousContext}) async {
    return await _transcribe(wavFile, previousContext: previousContext); // 例外はそのまま上に伝播
  }

  Future<String?> _transcribe(File wavFile, {String? previousContext}) async {
    // APIキー未設定チェック（ビルド時に--dart-define=GROQ_API_KEY=...が必要）
    if (_groqApiKey.isEmpty) {
      AisaDebugLogger.instance.error('❌ GROQ_API_KEY未設定！build.sh でリビルドしてください');
      debugPrint('[AISA] ⚠️ GROQ_API_KEY未設定！build.sh を使ってリビルドしてください。文字起こし不可。');
      return null;
    }

    final fileSize = await wavFile.length();
    AisaDebugLogger.instance.info('Groq API送信: ${(fileSize / 1024).toStringAsFixed(0)}KB'
        '${previousContext != null ? ", 文脈あり(${previousContext.length}chars)" : ""}');
    debugPrint('[AISA] Groq送信: ${wavFile.path} (${(fileSize / 1024).toStringAsFixed(0)}KB)');

    final request = http.MultipartRequest('POST', Uri.parse(_endpoint));
    request.headers['Authorization'] = 'Bearer $_groqApiKey';
    request.headers['User-Agent'] = 'AISA/1.0 (iOS; Flutter)';
    request.headers['Accept'] = 'application/json';
    request.fields['model'] = 'whisper-large-v3';
    request.fields['language'] = 'ja';
    // verbose_json: セグメントごとにno_speech_prob/avg_logprobを取得してBGM・雑音を除外できる
    request.fields['response_format'] = 'verbose_json';
    // ペンダント（近距離マイク）の話者の声に集中するよう誘導
    // previousContextがある場合は直前チャンクの末尾テキストを付加して文脈を提供する
    // （文の途中切れ防止 + 同音異義語の文脈補助）
    final basePrompt = 'これはペンダント型マイクで録音した音声です。句読点を含めて正確に文字起こしします。背景音やノイズは無視してください。';
    if (previousContext != null && previousContext.isNotEmpty) {
      // Whisperのpromptは最大224トークン。末尾200文字を渡して文脈を与える
      final tail = previousContext.length > 200 ? previousContext.substring(previousContext.length - 200) : previousContext;
      request.fields['prompt'] = '$basePrompt 前の発話：$tail';
    } else {
      request.fields['prompt'] = basePrompt;
    }
    request.files.add(await http.MultipartFile.fromPath('file', wavFile.path));

    // 90秒タイムアウト: タイムアウト時はTimeoutExceptionをthrow（呼び出し元でリトライ）
    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 90),
      onTimeout: () => throw TimeoutException('Groq API request timed out after 90s'),
    );
    final body = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode == 429) {
      AisaDebugLogger.instance.error('❌ Groq レートリミット(429) - 60秒後にリトライ');
      throw Exception('Groq rate limit (429): $body');
    }

    if (streamedResponse.statusCode != 200) {
      AisaDebugLogger.instance.error('❌ Groq APIエラー ${streamedResponse.statusCode}: ${body.substring(0, body.length.clamp(0, 100))}');
      debugPrint('[AISA] Groq API エラー ${streamedResponse.statusCode}: $body');
      throw Exception('Groq API error ${streamedResponse.statusCode}: $body');
    }
    AisaDebugLogger.instance.info('Groq APIレスポンス: HTTP ${streamedResponse.statusCode} OK');

    final json = jsonDecode(body) as Map<String, dynamic>;
    final filtered = _filterSpeechSegments(json);
    if (filtered == null || filtered.isEmpty) return filtered;

    // Whisperハルシネーション除去: 無音・ノイズから生成される定型文をブロック
    if (_isHallucination(filtered)) {
      AisaDebugLogger.instance.warning('⚠ ハルシネーション除外: "$filtered"');
      debugPrint('[AISA] ハルシネーション除外: "$filtered"');
      return null;
    }

    // Claude Haiku後処理: 文脈から明らかに誤った漢字・同音異義語を修正
    // APIキー未設定の場合はスキップ（Whisper結果をそのまま返す）
    if (_anthropicApiKey.isNotEmpty) {
      AisaDebugLogger.instance.info('Claude校正: 開始 (${filtered.length}文字)');
      return await _correctWithClaude(filtered);
    }
    AisaDebugLogger.instance.info('Claude校正: スキップ (ANTHROPIC_API_KEY未設定)');
    return filtered;
  }

  /// verbose_jsonのセグメントから人の声らしい区間だけを抽出する
  ///
  /// Whisperは各セグメントに以下のスコアを付与する:
  ///   no_speech_prob : 0〜1 (高いほど「声ではない」確率が高い)
  ///   avg_logprob    : 0以下 (0に近いほど高確信度, -1以下は不明瞭)
  ///
  /// 除外基準:
  ///   no_speech_prob >= 0.6  → BGM・環境音・ノイズと判定（元の閾値に戻す: 0.5は厳しすぎた）
  ///   compression_ratio > 2.8 → Whisperハルシネーション（同じテキストを繰り返す異常状態）
  ///   avg_logprob < -1.0     → Whisperが内容を認識できない（ノイズや遠方音）
  String? _filterSpeechSegments(Map<String, dynamic> json) {
    final segments = json['segments'] as List<dynamic>?;

    // verbose_jsonのセグメント情報が取れない場合はtextフィールドをそのまま返す
    if (segments == null || segments.isEmpty) {
      final text = json['text'] as String?;
      debugPrint('[AISA] Groq成功（セグメントなし）: ${text?.length ?? 0}文字');
      return text?.trim().isEmpty == true ? null : text;
    }

    int total = segments.length;
    int kept = 0;
    int skippedNoSpeech = 0;
    int skippedLowConf = 0;

    final buffer = StringBuffer();
    for (final seg in segments) {
      final noSpeechProb = (seg['no_speech_prob'] as num?)?.toDouble() ?? 0.0;
      final avgLogprob = (seg['avg_logprob'] as num?)?.toDouble() ?? 0.0;
      final text = (seg['text'] as String?)?.trim() ?? '';

      final compressionRatio = (seg['compression_ratio'] as num?)?.toDouble() ?? 1.0;

      if (noSpeechProb >= 0.6) {
        // BGM・環境音・ノイズと判定 → 除外
        debugPrint('[AISA VAD] 除外(no_speech=$noSpeechProb): "$text"');
        skippedNoSpeech++;
        continue;
      }
      if (compressionRatio > 2.8) {
        // Whisperハルシネーション: 同じテキストを繰り返し生成する異常状態
        // 閾値2.8: 通常の会話（〜1.8）や多少の繰り返し（〜2.4）は通過させる
        debugPrint('[AISA VAD] 除外(compression=$compressionRatio): "$text"');
        skippedNoSpeech++;
        continue;
      }
      if (avgLogprob < -1.0) {
        // Whisperが内容を認識できない（遠方・不明瞭） → 除外
        debugPrint('[AISA VAD] 除外(logprob=$avgLogprob): "$text"');
        skippedLowConf++;
        continue;
      }

      buffer.write(text);
      kept++;
    }

    final result = buffer.toString().trim();
    AisaDebugLogger.instance.info(
      'セグメントフィルタ: $total件中 $kept件採用'
      ' (ノイズ除外=$skippedNoSpeech 低信頼度=$skippedLowConf)'
      ' → ${result.length}文字${result.isEmpty ? " [空のため破棄]" : ""}',
    );
    debugPrint('[AISA] Groq成功: $total セグメント中 $kept件を採用 '
        '(ノイズ除外: $skippedNoSpeech件, 低確信度除外: $skippedLowConf件) '
        '→ ${result.length}文字');

    return result.isEmpty ? null : result;
  }

  /// Whisperが無音・ノイズから生成する定型ハルシネーションを検出する
  /// 実際に発話していないのにWhisperが勝手に生成するフレーズのブロックリスト
  static bool _isHallucination(String text) {
    final t = text.trim();
    // 短すぎるテキスト（3文字以下）は意味のある発話ではない可能性が高い
    if (t.length <= 3) return true;

    // 完全一致・末尾句読点バリエーション用の定型ハルシネーション
    const exactHallucinations = [
      'ご視聴ありがとうございました',
      'ご視聴ありがとうございます',
      'チャンネル登録お願いします',
      'チャンネル登録よろしくお願いします',
      'お疲れ様でした',
      'おやすみなさい',
      'ありがとうございました',
      '字幕視聴ありがとうございました',
      'ご清聴ありがとうございました',
      '最後までご視聴ありがとうございました',
      'いい加減にしろ',
      'Thanks for watching',
      'Thank you for watching',
      'Subscribe',
      'Bye bye',
      'Goodbye',
    ];
    for (final h in exactHallucinations) {
      if (t == h || t == '$h。' || t == '$h！' || t == '$h.') return true;
    }

    // プロンプトエコー系は部分一致で判定する
    // Whisperが送信プロンプトの単語をそのまま出力に混ぜるケースがあり、
    // 「ペンダント型マイクで録音した音声を、ペンダント型マイクで再生してください」のような
    // 微妙にバリエーションした派生を完全一致では捕まえられないため。
    const substringHallucinations = [
      'ペンダント型マイク',
      'ペンダントマイク',
      '句読点を含めて正確に文字起こし',
      '背景音やノイズは無視',
      'マイクに近い話者',
      '音声を聞いてみましょう',
      '録音した音声を',
    ];
    for (final h in substringHallucinations) {
      if (t.contains(h)) return true;
    }

    return false;
  }

  /// Claude Haiku APIで音声認識結果を校正する
  ///
  /// Whisperは音だけで漢字を選ぶため同音異義語を間違えることがある。
  /// Claude Haikuは文脈から「機械」と「機会」のどちらが正しいか判断できる。
  ///
  /// ハルシネーション防止のため:
  /// - 「修正後のテキストのみ返す」と明示し余計な説明を排除
  /// - 「正しい可能性があるものは修正しない」と保守的な姿勢を指示
  Future<String?> _correctWithClaude(String whisperText) async {
    try {
      const prompt = '''あなたは日本語音声認識の校正ツールです。
以下の音声認識結果を校正してください。

【ルール】
・文脈から明らかに誤っている漢字・同音異義語のみ修正
・内容の追加・削除・言い換えは一切禁止
・正しい可能性があるものは修正しない（迷ったら元のままにする）
・修正後のテキストのみ返す（説明・コメント不要）

【音声認識テキスト】
''';

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
          'temperature': 0.1, // 低温度で決定論的な校正
          'messages': [
            {'role': 'user', 'content': '$prompt$whisperText'},
          ],
        }),
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode != 200) {
        debugPrint('[AISA Claude] 校正失敗 ${response.statusCode}: ${response.body}');
        return whisperText; // 失敗時はWhisper結果をそのまま返す
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final corrected = (json['content'] as List<dynamic>?)
          ?.whereType<Map<String, dynamic>>()
          .firstWhere((c) => c['type'] == 'text', orElse: () => {})['text'] as String?;

      if (corrected == null || corrected.trim().isEmpty) {
        return whisperText;
      }

      final result = corrected.trim();
      if (result != whisperText) {
        AisaDebugLogger.instance.info('Claude校正: 変更あり (${whisperText.length}→${result.length}文字)');
        debugPrint('[AISA Claude] 校正完了: ${whisperText.length}文字 → ${result.length}文字');
      } else {
        AisaDebugLogger.instance.info('Claude校正: 変更なし (${result.length}文字)');
      }
      return result;
    } catch (e) {
      AisaDebugLogger.instance.warning('⚠ Claude校正エラー (Whisper結果を使用): $e');
      debugPrint('[AISA Claude] 校正エラー（Whisper結果を使用）: $e');
      return whisperText; // エラー時はWhisper結果をそのまま返す
    }
  }
}
