// app/lib/services/aisa_transcription_service.dart
//
// A.I.S.A. Groq Whisper 文字起こしサービス
// 音声フレームをWAVに変換し、Groq Whisper APIで文字起こしして Firestore に保存する

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show sqrt;

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

  /// Groq Whisperで文字起こし＋ハルシネーション除去のみ（Claude校正なし）
  /// チャンク単位の軽量処理。会話バッファリングの各ティックで使う。
  /// WAVファイルの削除は呼び出し元の責任。
  Future<String?> transcribeChunkOnly(File wavFile, {String? previousContext}) async {
    return await _transcribe(wavFile, previousContext: previousContext, skipClaude: true);
  }

  /// 蓄積済みテキストをClaude校正＋話者分離してFirestoreに保存する
  /// 会話バッファのフラッシュ時に呼ぶ。
  Future<String?> correctAndSave(String rawText) async {
    if (rawText.trim().isEmpty) return null;
    try {
      String result = rawText;
      if (_anthropicApiKey.isNotEmpty) {
        AisaDebugLogger.instance.info('Claude校正: 開始 (${rawText.length}文字)');
        final corrected = await _correctWithClaude(rawText);
        if (corrected != null && corrected.trim().isNotEmpty) {
          result = corrected;
        }
      }
      // Firestore保存
      try {
        await AisaFirestoreService.instance.saveTranscript(result);
      } catch (e) {
        debugPrint('[AISA] Firestore保存失敗（UIには表示）: $e');
      }
      return result;
    } catch (e) {
      debugPrint('[AISA] Claude校正失敗（生テキストを使用）: $e');
      // 校正失敗時は生テキストをそのまま保存
      try {
        await AisaFirestoreService.instance.saveTranscript(rawText);
      } catch (_) {}
      return rawText;
    }
  }

  Future<String?> _transcribe(File wavFile, {String? previousContext, bool skipClaude = false}) async {
    // APIキー未設定チェック（ビルド時に--dart-define=GROQ_API_KEY=...が必要）
    if (_groqApiKey.isEmpty) {
      AisaDebugLogger.instance.error('❌ GROQ_API_KEY未設定！build.sh でリビルドしてください');
      debugPrint('[AISA] ⚠️ GROQ_API_KEY未設定！build.sh を使ってリビルドしてください。文字起こし不可。');
      return null;
    }

    final fileSize = await wavFile.length();

    // 無音検出: WAVファイルの音量(RMS)が極端に低い場合はAPIを呼ばない
    // 無音データをWhisperに送るとハルシネーション（「ご視聴ありがとう」等）を生成する
    if (await _isSilentWav(wavFile)) {
      AisaDebugLogger.instance.info('無音検出 → Groq APIスキップ (${(fileSize / 1024).toStringAsFixed(0)}KB)');
      debugPrint('[AISA] 無音検出 → APIスキップ: ${wavFile.path}');
      return null;
    }

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
    // WAVファイルのPCMデータをメモリに読み込む（ファイル削除後もセグメント音量計算可能にする）
    Uint8List? pcmSnapshot;
    int wavSampleRate = 16000;
    try {
      final wavBytes = await wavFile.readAsBytes();
      if (wavBytes.length > 44) {
        wavSampleRate = wavBytes[24] | (wavBytes[25] << 8) | (wavBytes[26] << 16) | (wavBytes[27] << 24);
        if (wavSampleRate <= 0 || wavSampleRate > 96000) wavSampleRate = 16000;
        pcmSnapshot = Uint8List.fromList(wavBytes.sublist(44));
      }
    } catch (_) {}
    final filtered = _filterSpeechSegments(json, pcmData: pcmSnapshot, sampleRate: wavSampleRate);
    if (filtered == null || filtered.isEmpty) return filtered;

    // Whisperハルシネーション除去: 無音・ノイズから生成される定型文をブロック
    if (_isHallucination(filtered)) {
      AisaDebugLogger.instance.warning('⚠ ハルシネーション除外: "$filtered"');
      debugPrint('[AISA] ハルシネーション除外: "$filtered"');
      return null;
    }

    // Claude Haiku後処理: 文脈から明らかに誤った漢字・同音異義語を修正
    // skipClaude=trueの場合はWhisper結果のみ返す（チャンク単位の軽量処理用）
    // APIキー未設定の場合もスキップ
    if (!skipClaude && _anthropicApiKey.isNotEmpty) {
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
  String? _filterSpeechSegments(Map<String, dynamic> json, {Uint8List? pcmData, int sampleRate = 16000}) {
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
    int skippedQuiet = 0;

    final buffer = StringBuffer();
    for (final seg in segments) {
      final noSpeechProb = (seg['no_speech_prob'] as num?)?.toDouble() ?? 0.0;
      final avgLogprob = (seg['avg_logprob'] as num?)?.toDouble() ?? 0.0;
      final text = (seg['text'] as String?)?.trim() ?? '';
      final compressionRatio = (seg['compression_ratio'] as num?)?.toDouble() ?? 1.0;

      if (noSpeechProb >= 0.6) {
        debugPrint('[AISA VAD] 除外(no_speech=$noSpeechProb): "$text"');
        skippedNoSpeech++;
        continue;
      }
      if (compressionRatio > 2.8) {
        debugPrint('[AISA VAD] 除外(compression=$compressionRatio): "$text"');
        skippedNoSpeech++;
        continue;
      }
      if (avgLogprob < -1.0) {
        debugPrint('[AISA VAD] 除外(logprob=$avgLogprob): "$text"');
        skippedLowConf++;
        continue;
      }

      // 音量フィルタ: セグメントの時間範囲のRMSを計算し、小さい声（＝他人・遠方）を除外
      // ペンダントマイクは装着者の声が大きく、他人やTVの声は小さい
      if (pcmData != null) {
        final segStart = (seg['start'] as num?)?.toDouble() ?? 0.0;
        final segEnd = (seg['end'] as num?)?.toDouble() ?? 0.0;
        final rms = _calculateSegmentRms(pcmData, sampleRate, segStart, segEnd);
        // RMS < 800: 遠方の声と判定（装着者の通常の声は 2000〜10000）
        // 閾値800は小声でも拾えるが、TV・他人の声（通常300〜700）を除外する
        if (rms >= 0 && rms < 800) {
          debugPrint('[AISA VAD] 除外(quiet rms=$rms): "$text"');
          skippedQuiet++;
          continue;
        }
      }

      buffer.write(text);
      kept++;
    }

    final result = buffer.toString().trim();
    AisaDebugLogger.instance.info(
      'セグメントフィルタ: $total件中 $kept件採用'
      ' (ノイズ=$skippedNoSpeech 低信頼度=$skippedLowConf 小音量=$skippedQuiet)'
      ' → ${result.length}文字${result.isEmpty ? " [空のため破棄]" : ""}',
    );
    debugPrint('[AISA] Groq成功: $total セグメント中 $kept件を採用 '
        '(ノイズ除外: $skippedNoSpeech件, 低確信度: $skippedLowConf件, 小音量: $skippedQuiet件) '
        '→ ${result.length}文字');

    return result.isEmpty ? null : result;
  }

  /// PCMデータの指定時間範囲のRMS（音量）を計算する
  /// 戻り値: RMS値（0〜32768）。計算不能の場合は-1
  static double _calculateSegmentRms(Uint8List pcmData, int sampleRate, double startSec, double endSec) {
    final startSample = (startSec * sampleRate).toInt();
    final endSample = (endSec * sampleRate).toInt();
    final startByte = startSample * 2; // 16bit = 2バイト
    final endByte = endSample * 2;

    if (startByte >= pcmData.length || startByte >= endByte) return -1;
    final actualEnd = endByte > pcmData.length ? pcmData.length : endByte;

    double sumSquares = 0;
    int count = 0;
    // パフォーマンスのため最大2000サンプルをチェック
    final totalSamples = (actualEnd - startByte) ~/ 2;
    final step = totalSamples > 2000 ? totalSamples ~/ 2000 : 1;

    for (int i = startByte; i < actualEnd - 1; i += step * 2) {
      int sample = pcmData[i] | (pcmData[i + 1] << 8);
      if (sample >= 32768) sample -= 65536;
      sumSquares += sample * sample;
      count++;
    }

    if (count == 0) return -1;
    return sqrt(sumSquares / count);
  }

  /// Whisperが無音・ノイズから生成する定型ハルシネーションを検出する
  /// 実際に発話していないのにWhisperが勝手に生成するフレーズのブロックリスト
  /// 外部からもハルシネーション判定を利用可能にする（オフライン同期等）
  static bool isHallucination(String text) => _isHallucination(text);

  static bool _isHallucination(String text) {
    final t = text.trim();
    // 短すぎるテキスト（3文字以下）は意味のある発話ではない可能性が高い
    if (t.length <= 3) return true;

    // 同じフレーズの繰り返し検出（ハルシネーションの典型パターン）
    // 例: 「ペンダント音ペンダント音ペンダント音...」
    // 例: 「口の中で音が聞こえないように注意してください。口の中で...」
    if (_isRepetitive(t)) return true;

    // Claude校正後の削除メッセージもブロック
    if (t.contains('削除対象') || t.contains('全文削除')) return true;

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

    // プロンプトエコー系・ノイズ系は部分一致で判定
    const substringHallucinations = [
      'ペンダント型マイク',
      'ペンダントマイク',
      'ペンダントの音声',
      'ペンダント音',
      '口の中で音が聞こえない',
      '句読点を含めて正確に文字起こし',
      '背景音やノイズは無視',
      'マイクに近い話者',
      '音声を聞いてみましょう',
      '音声を聞き取ると',
      '音声が聞こえます',
      '録音した音声を',
      '音声認識テキスト',
      '校正対象の',
      '校正してほしい',
      'テキストが記載されていません',
      'テキストをご提供',
    ];
    for (final h in substringHallucinations) {
      if (t.contains(h)) return true;
    }

    return false;
  }

  /// 同じフレーズが繰り返されているかチェック
  /// テキストの先頭20文字が3回以上出現していればハルシネーション
  static bool _isRepetitive(String text) {
    if (text.length < 30) return false;

    // 句読点で分割して同一フレーズの繰り返しをチェック
    final sentences = text.split(RegExp(r'[。．.、]')).where((s) => s.trim().isNotEmpty).toList();
    if (sentences.length >= 3) {
      final first = sentences[0].trim();
      if (first.length >= 5) {
        final repeatCount = sentences.where((s) => s.trim() == first).length;
        if (repeatCount >= 3) return true;
      }
    }

    // 短いフレーズの連続繰り返しチェック（句読点なしのケース）
    // 例: 「ペンダント音ペンダント音ペンダント音」
    for (int len = 3; len <= 15 && len <= text.length ~/ 3; len++) {
      final pattern = text.substring(0, len);
      int count = 0;
      int pos = 0;
      while (pos + len <= text.length) {
        if (text.substring(pos, pos + len) == pattern) {
          count++;
          pos += len;
        } else {
          break;
        }
      }
      if (count >= 3) return true;
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
      const prompt = '''あなたは日本語音声認識の校正＆話者分離ツールです。
以下の音声認識結果を校正し、話者を推定してください。
この音声はペンダント型マイクで録音されたものです。主に「装着者本人」の発話ですが、会話相手の発言も含まれる場合があります。

【校正ルール】
・文脈から明らかに誤っている漢字・同音異義語のみ修正
・内容の追加・削除・言い換えは一切禁止
・正しい可能性があるものは修正しない（迷ったら元のままにする）
・アニメ・動画・テレビ・YouTubeのセリフやナレーションと思われる内容は丸ごと削除する（装着者本人の発話ではないため）

【話者分離ルール】
・発言の文脈（質問↔回答、指示↔了承、話題の切り替え）から話者を推定する
・装着者本人は常に [自分] と表記する
・相手の名前が会話中に出てきた場合（例：「田中さん、これお願い」）、その相手の発言は [田中] のように名前で表記する
・名前の検出方法：
  - 「〇〇さん」「〇〇くん」「〇〇ちゃん」「〇〇先生」など敬称付きで呼びかけている場合 → 〇〇が相手の名前
  - 「〇〇、これやって」のように名前で直接呼びかけている場合も同様
  - 複数の相手がいる場合は、それぞれの名前で区別する（[田中] [佐藤] など）
・名前が分からない相手は [相手] と表記する
・判断基準：
  - 質問・依頼・指示を出す側 → 多くの場合 [自分]（ペンダント装着者が主導権を持つことが多い）
  - 応答・返事・報告する側 → 多くの場合 [相手] または [名前]
  - 独り言・メモ・つぶやき → [自分]
・話者が不明な場合は [自分] とする（ペンダントマイクは装着者の声を最も拾うため）
・1人で話しているだけの場合は、無理に分離せず全て [自分] とする

【出力形式】
1行目: 会話内容を表す短いタイトル（10文字以内）と、内容にふさわしい絵文字1つをタブ区切りで出力
例: 打ち合わせ\t💼
例: 買い物リスト\t🛒
例: 雑談\t💬
2行目以降: 話者タグ付きテキスト
[自分] テキスト
[田中] テキスト（名前が判明している場合）
[相手] テキスト（名前が不明な場合）
※各発言を改行で区切る。説明・コメントは不要。

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

      // Claude校正後のテキストもハルシネーションチェック
      // Claudeが「テキストが記載されていません」等の応答を返すケースを捕捉
      if (_isHallucination(result)) {
        AisaDebugLogger.instance.warning('⚠ Claude校正結果がハルシネーション → 破棄: "$result"');
        return null;
      }

      // Claude校正結果が元テキストより大幅に長い場合は校正を拒否（余計な説明を追加している）
      // 話者タグ「[自分] 」「[相手] 」が行ごとに付くため、元テキストの3倍まで許容する
      if (result.length > whisperText.length * 3 + 50) {
        AisaDebugLogger.instance.warning('⚠ Claude校正が過剰に長い → Whisper結果を使用 (${whisperText.length}→${result.length}文字)');
        return whisperText;
      }

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

  /// WAVファイルの音量(RMS)を計算し、無音に近いかどうかを判定する
  /// WAVヘッダー(44バイト)をスキップして16bit PCMサンプルのRMSを計算
  /// RMS < 50 の場合は無音と判定（通常の会話は 200〜5000）
  static Future<bool> _isSilentWav(File wavFile) async {
    try {
      final bytes = await wavFile.readAsBytes();
      if (bytes.length < 100) return true; // ヘッダーのみ = 無音

      // WAVヘッダーをスキップ（標準44バイト）
      const headerSize = 44;
      if (bytes.length <= headerSize) return true;

      // 16bit PCMサンプルのRMSを計算（最大10000サンプルをチェック）
      final dataBytes = bytes.sublist(headerSize);
      final sampleCount = dataBytes.length ~/ 2; // 16bit = 2バイト
      if (sampleCount == 0) return true;

      final step = sampleCount > 10000 ? sampleCount ~/ 10000 : 1;
      double sumSquares = 0;
      int count = 0;

      for (int i = 0; i < dataBytes.length - 1; i += step * 2) {
        // Little-endian 16bit signed
        int sample = dataBytes[i] | (dataBytes[i + 1] << 8);
        if (sample >= 32768) sample -= 65536; // unsigned → signed
        sumSquares += sample * sample;
        count++;
      }

      final rmsValue = count > 0 ? sqrt(sumSquares / count) : 0.0;
      final isSilent = rmsValue < 50;

      if (isSilent) {
        debugPrint('[AISA VAD] 無音判定: RMS=${rmsValue.toStringAsFixed(0)} (閾値: 50)');
      }
      return isSilent;
    } catch (e) {
      debugPrint('[AISA VAD] 音量チェック失敗（APIに送信する）: $e');
      return false; // エラー時はAPIに送る（安全側に倒す）
    }
  }
}
