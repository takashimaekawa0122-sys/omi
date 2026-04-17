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

  // ライブ優先制御: オフライン同期がライブ会話のAPI呼び出しに割り込まないようにする
  int _liveInFlight = 0;
  DateTime? _lastLiveCallAt;

  /// ライブ会話が直近にAPI呼び出しをしたか（オフライン同期側で待機判定に使う）
  /// 進行中 or 5秒以内に呼び出しがあった場合 true
  bool get isLiveActive {
    if (_liveInFlight > 0) return true;
    final last = _lastLiveCallAt;
    if (last == null) return false;
    return DateTime.now().difference(last) < _liveCooldown;
  }

  /// オフライン同期側で使用: ライブが静かになるまで待機（最大waitLimit秒）
  /// タイムアウト到達時は警告ログを出して呼び出し元に制御を返す（オフラインを永久停止させない）
  Future<void> waitForLiveQuiet({Duration waitLimit = _liveWaitDefaultLimit}) async {
    if (!isLiveActive) return;
    final startedAt = DateTime.now();
    final deadline = startedAt.add(waitLimit);
    while (isLiveActive && DateTime.now().isBefore(deadline)) {
      await Future.delayed(_liveWaitPollInterval);
    }
    final waited = DateTime.now().difference(startedAt);
    if (isLiveActive) {
      AisaDebugLogger.instance.warning(
          '⚠ ライブ待機タイムアウト(${waited.inSeconds}s) → オフライン続行');
    } else {
      AisaDebugLogger.instance.info('[Offline] ライブ静止検出 (${waited.inSeconds}s待機)');
    }
  }

  // ──── エンドポイントとAPIキー ────
  static const _endpoint = 'https://api.groq.com/openai/v1/audio/transcriptions';
  static const _groqApiKey = String.fromEnvironment('GROQ_API_KEY');

  static const _claudeEndpoint = 'https://api.anthropic.com/v1/messages';
  static const _anthropicApiKey = String.fromEnvironment('ANTHROPIC_API_KEY');

  // ──── ライブ優先制御 ────
  /// ライブ呼び出しのクールダウン: 最後のライブ呼び出しから何秒までを "active" 扱いにするか
  /// ライブは5秒ティックで動くので、2ティック分+余裕の15秒にすることでバースト中の隙間に
  /// オフラインが割り込むのを防ぐ
  static const Duration _liveCooldown = Duration(seconds: 15);
  /// ライブ待機の最大時間（永遠に待ち続けないためのフェイルセーフ）
  /// 会話は数分続くことを想定し、3分まで待つ。超えた場合はログを残してオフラインを進行させる
  static const Duration _liveWaitDefaultLimit = Duration(minutes: 3);
  static const Duration _liveWaitPollInterval = Duration(milliseconds: 500);

  // ──── 音量・音声判定しきい値 ────
  /// 無音判定（WAV全体）: これ未満はGroqにすら送らない
  static const double _kSilentWavRms = 50.0;
  /// セグメント単位の無音除外（会話相手の声も拾うため緩い設定）
  static const double _kSegmentQuietRms = 80.0;
  /// Whisper no_speech_prob: この値以上は非音声として除外
  static const double _kNoSpeechProbThreshold = 0.6;
  /// Whisper compression_ratio: この値超はループハルシネーション
  static const double _kCompressionRatioThreshold = 2.8;
  /// Whisper avg_logprob: この値未満は不明瞭として除外
  static const double _kMinAvgLogprob = -1.0;

  // ──── F0（基本周波数）推定 ────
  // 日本人の実測値に合わせて調整:
  //   男性: 平均120Hz、語尾上げで170Hz程度まで → maleの上限を175Hz
  //   女性: 平均220Hz、抑揚で260Hz程度まで    → femaleの上限を280Hz
  //   child判定は誤検出が多いので、300Hz超のみchild（大声・裏声もchild判定しない）
  // また、オクターブエラーで真値の2倍を拾う傾向があるため、最大値も300Hzまでに下げる
  static const double _kF0MinHz = 70.0;
  static const double _kF0MaxHz = 320.0;
  static const double _kF0MaleMaxHz = 175.0;   // < 175Hz = male
  static const double _kF0FemaleMaxHz = 280.0; // 175〜280Hz = female、以上 = child
  static const int _kF0MaxAnalysisSamples = 8000; // 0.5秒 @ 16kHz
  static const int _kF0MinSamples = 400; // 25ms未満は推定不可
  static const double _kF0MinEnergy = 1000;
  /// 相関が低い場合はF0不明扱いにしてChatに判断を委ねる
  static const double _kF0MinCorrelation = 0.4; // 0.3→0.4（誤検出を減らす）
  /// オクターブエラー対策: 候補lag×2の相関がこの割合以上なら倍音（真のlag）を優先
  static const double _kF0OctavePreferRatio = 0.85;

  /// F0マーカー削除用の正規表現（事前コンパイル）
  static final RegExp _f0MarkerRegex = RegExp(r'\[F=\d+(?:\.\d+)?\|(?:male|female|child|unknown)\]');
  static final RegExp _multiSpaceRegex = RegExp(r'\s{2,}');

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
  ///
  /// 【ライブ優先ゲート】オフライン側はAPI送信直前に必ず待機ポイントを通る。
  /// これによりリトライループ内でライブに割り込むことを防ぐ。
  Future<String?> transcribeOnly(File wavFile, {String? previousContext}) async {
    await waitForLiveQuiet();
    return await _transcribe(wavFile, previousContext: previousContext); // 例外はそのまま上に伝播
  }

  /// Groq Whisperで文字起こし＋ハルシネーション除去のみ（Claude校正なし）
  /// チャンク単位の軽量処理。会話バッファリングの各ティックで使う。
  /// WAVファイルの削除は呼び出し元の責任。
  Future<String?> transcribeChunkOnly(File wavFile, {String? previousContext}) async {
    // 開始時にもタイムスタンプを更新することで、isLiveActiveが連続ティック間のギャップで
    // falseにならないようにする。オフライン側のwaitForLiveQuietが早期に解除されるのを防ぐ
    _lastLiveCallAt = DateTime.now();
    _liveInFlight++;
    try {
      final result = await _transcribe(wavFile, previousContext: previousContext, skipClaude: true);
      _lastLiveCallAt = DateTime.now();
      return result;
    } finally {
      _liveInFlight--;
      _lastLiveCallAt = DateTime.now();
    }
  }

  /// 蓄積済みテキストをClaude校正＋話者分離してFirestoreに保存する
  /// 会話バッファのフラッシュ時に呼ぶ。
  /// Claude校正＋Firestore保存を行い、(校正済みテキスト, FirestoreドキュメントID) を返す
  Future<({String text, String? docId})?> correctAndSave(String rawText) async {
    if (rawText.trim().isEmpty) return null;
    _liveInFlight++;
    // F0マーカーを剥がしたクリーンテキストをフォールバックに使う
    final cleanRawText = _stripF0Markers(rawText);
    try {
      String result = cleanRawText;
      if (_anthropicApiKey.isNotEmpty) {
        AisaDebugLogger.instance.info('Claude校正: 開始 (${rawText.length}文字)');
        final corrected = await _correctWithClaude(rawText);
        if (corrected != null && corrected.trim().isNotEmpty) {
          result = corrected;
        }
      }
      // Firestore保存（docIdをUIの会話IDに使うことで、リロード時の重複を防ぐ）
      String? docId;
      try {
        docId = await AisaFirestoreService.instance.saveTranscript(result);
      } catch (e) {
        debugPrint('[AISA] Firestore保存失敗（UIには表示）: $e');
      }
      return (text: result, docId: docId);
    } catch (e) {
      debugPrint('[AISA] Claude校正失敗（生テキストを使用）: $e');
      String? docId;
      try {
        docId = await AisaFirestoreService.instance.saveTranscript(cleanRawText);
      } catch (_) {}
      return (text: cleanRawText, docId: docId);
    } finally {
      _lastLiveCallAt = DateTime.now();
      _liveInFlight--;
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
    // Whisperプロンプト: 装着者と会話相手の両方を正確に拾うよう指示
    // 「近距離の話者に集中」「背景音は無視」と書くとWhisperが相手の声まで無視してしまうので外した。
    final basePrompt = 'これは日本語の日常会話の録音です。装着者本人と会話相手の両方の発話を、句読点を含めて正確に文字起こししてください。';
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

      if (noSpeechProb >= _kNoSpeechProbThreshold) {
        debugPrint('[AISA VAD] 除外(no_speech=$noSpeechProb): "$text"');
        skippedNoSpeech++;
        continue;
      }
      if (compressionRatio > _kCompressionRatioThreshold) {
        debugPrint('[AISA VAD] 除外(compression=$compressionRatio): "$text"');
        skippedNoSpeech++;
        continue;
      }
      if (avgLogprob < _kMinAvgLogprob) {
        debugPrint('[AISA VAD] 除外(logprob=$avgLogprob): "$text"');
        skippedLowConf++;
        continue;
      }

      // 【重要】セグメント単位でハルシネーション辞書チェック
      // 連結後の全体チェック（L273）だけだと「ありがとうございました」の連発が素通りする
      if (_isHallucination(text)) {
        debugPrint('[AISA VAD] 除外(hallucination): "$text"');
        skippedNoSpeech++;
        continue;
      }

      // 音量フィルタ: 極端に小さい音量（ほぼ無音）のみ除外する。
      // 以前は「装着者以外の声」を弾くため閾値を高く設定していたが、
      // 会話相手の声も拾いたいユースケースに合わせて大幅に緩和。
      // Whisperのno_speech_prob/avg_logprob/compression_ratioと
      // ハルシネーション辞書で雑音・BGM・誤認識は別途除外される。
      if (pcmData != null) {
        final segStart = (seg['start'] as num?)?.toDouble() ?? 0.0;
        final segEnd = (seg['end'] as num?)?.toDouble() ?? 0.0;
        final rms = _calculateSegmentRms(pcmData, sampleRate, segStart, segEnd);
        // RMS < _kSegmentQuietRms: ほぼ完全な無音セグメントのみ除外（通常の会話相手は 100〜600）
        if (rms >= 0 && rms < _kSegmentQuietRms) {
          debugPrint('[AISA VAD] 除外(quiet rms=$rms): "$text"');
          skippedQuiet++;
          continue;
        }
      }

      // F0（基本周波数）推定 → 性別・年齢マーカーを付加
      // Claudeに話者属性のヒントとして渡し、出力時に性別/年齢絵文字を付けてもらう
      String marker = '';
      if (pcmData != null) {
        final segStart = (seg['start'] as num?)?.toDouble() ?? 0.0;
        final segEnd = (seg['end'] as num?)?.toDouble() ?? 0.0;
        final f0 = _estimateF0(pcmData, sampleRate, segStart, segEnd);
        if (f0 > 0) {
          final category = _categorizeF0(f0);
          marker = '[F=${f0.toStringAsFixed(0)}|$category]';
        }
      }
      buffer.write('$marker$text ');
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

  /// 自己相関による基本周波数（F0）推定
  /// 戻り値: Hz（70〜400Hz 範囲外または推定不可の場合は -1）
  /// 男性: 85〜180Hz / 女性: 165〜255Hz / 子供: 250〜400Hz
  static double _estimateF0(Uint8List pcmData, int sampleRate, double startSec, double endSec) {
    final startSample = (startSec * sampleRate).toInt();
    final endSample = (endSec * sampleRate).toInt();
    final startByte = startSample * 2;
    var endByte = endSample * 2;
    if (endByte > pcmData.length) endByte = pcmData.length;
    if (startByte >= endByte) return -1;

    // セグメントが長すぎる場合は先頭から最大N秒だけ解析（パフォーマンス）
    final availableSamples = (endByte - startByte) ~/ 2;
    final sampleCount = availableSamples > _kF0MaxAnalysisSamples
        ? _kF0MaxAnalysisSamples
        : availableSamples;
    if (sampleCount < _kF0MinSamples) return -1;

    // 16bit signed → double配列に変換
    final samples = List<double>.filled(sampleCount, 0);
    for (int i = 0; i < sampleCount; i++) {
      int s = pcmData[startByte + i * 2] | (pcmData[startByte + i * 2 + 1] << 8);
      if (s >= 32768) s -= 65536;
      samples[i] = s.toDouble();
    }

    // 自己相関でF0推定
    // 探索範囲: _kF0MinHz〜_kF0MaxHz → lag = sampleRate/maxHz 〜 sampleRate/minHz
    final minLag = (sampleRate / _kF0MaxHz).toInt();
    final maxLag = (sampleRate / _kF0MinHz).toInt();
    if (maxLag >= sampleCount) return -1;

    double maxCorr = 0;
    int bestLag = 0;
    // エネルギー基準（ノイズ/無声で低相関を弾く）
    double energy = 0;
    for (int i = 0; i < sampleCount; i++) {
      energy += samples[i] * samples[i];
    }
    if (energy < _kF0MinEnergy) return -1;

    // 相関値を全lagぶん保存（オクターブエラー補正で後段参照）
    final corrs = List<double>.filled(maxLag + 1, 0);
    for (int lag = minLag; lag <= maxLag; lag++) {
      double sum = 0;
      for (int i = 0; i < sampleCount - lag; i++) {
        sum += samples[i] * samples[i + lag];
      }
      corrs[lag] = sum;
      if (sum > maxCorr) {
        maxCorr = sum;
        bestLag = lag;
      }
    }

    if (bestLag == 0) return -1;
    // 正規化相関が低すぎるなら無声・雑音扱い
    final normCorr = maxCorr / energy;
    if (normCorr < _kF0MinCorrelation) return -1;

    // オクターブエラー補正: bestLag×2 の相関が maxCorr × 0.85 以上あれば、
    // bestLagはオクターブエラー（半分のlagを拾っている=倍の周波数）と判定し
    // lag×2（真のピッチ）を採用する。自己相関が倍音で同等のピークを持つ性質への対策。
    final doubleLag = bestLag * 2;
    if (doubleLag <= maxLag && corrs[doubleLag] >= maxCorr * _kF0OctavePreferRatio) {
      bestLag = doubleLag;
    }
    // 3倍音も念のためチェック（女性高音が誤って child に化けるケース）
    final tripleLag = bestLag * 3 ~/ 2; // さらに上のlagで高相関があるか
    if (tripleLag <= maxLag && corrs[tripleLag] >= corrs[bestLag] * _kF0OctavePreferRatio) {
      bestLag = tripleLag;
    }

    return sampleRate / bestLag;
  }

  /// F0から性別・年齢カテゴリを判定
  /// 境界付近（灰色ゾーン）は unknown を返し、Claude側で 🙂 を付けさせる
  static String _categorizeF0(double f0) {
    // 灰色ゾーン: 男女境界（165-185Hz）と女性/子供境界（270-300Hz）は
    // F0推定誤差のほうが大きいため判定を避ける
    if (f0 >= 165 && f0 <= 185) return 'unknown';
    if (f0 >= 270 && f0 <= 300) return 'unknown';
    if (f0 < _kF0MaleMaxHz) return 'male';
    if (f0 < _kF0FemaleMaxHz) return 'female';
    return 'child';
  }

  /// Whisperが無音・ノイズから生成する定型ハルシネーションを検出する
  /// 実際に発話していないのにWhisperが勝手に生成するフレーズのブロックリスト
  /// 外部からもハルシネーション判定を利用可能にする（オフライン同期等）
  static bool isHallucination(String text) => _isHallucination(text);

  static bool _isHallucination(String text) {
    final t = text.trim();
    // 1文字のみはノイズ扱い
    if (t.length <= 1) return true;
    // 2〜3文字の短い発話は、相槌・返事として実在するものだけ許可する
    // （Whisperがノイズから生成する無意味な2〜3文字を除外しつつ、正当な返事を残す）
    if (t.length <= 3) {
      const validShortReplies = {
        'はい', 'いえ', 'うん', 'ええ', 'ああ', 'おお', 'へえ', 'ふむ', 'そう', 'なに',
        'なぜ', 'やあ', 'まあ', 'ねえ', 'あの', 'その', 'この', 'どう', 'なる',
        'はあ', 'うーん', 'えー', 'あー', 'おー', 'ほう', 'おい', 'ほら', 'それ',
        'いいえ', 'はいよ', 'そうだ', 'そうね', 'わかった',
        'OK', 'ok', 'Ok', 'はいはい',
      };
      final stripped = t.replaceAll(RegExp(r'[。、！？.!?\s]'), '');
      if (!validShortReplies.contains(stripped)) return true;
    }

    // 同じフレーズの繰り返し検出（ハルシネーションの典型パターン）
    // 例: 「ペンダント音ペンダント音ペンダント音...」
    // 例: 「口の中で音が聞こえないように注意してください。口の中で...」
    if (_isRepetitive(t)) return true;

    // Claude校正後の削除メッセージもブロック
    if (t.contains('削除対象') || t.contains('全文削除')) return true;

    // 完全一致・末尾句読点バリエーション用の定型ハルシネーション
    const exactHallucinations = [
      // 視聴お礼系
      'ご視聴ありがとうございました',
      'ご視聴ありがとうございます',
      'ご視聴いただきありがとうございました',
      'ご視聴いただきありがとうございます',
      '最後までご視聴ありがとうございました',
      '最後までご視聴いただきありがとうございました',
      '最後までお聞きいただきありがとうございました',
      'ご清聴ありがとうございました',
      'ご清聴ありがとうございます',
      '字幕視聴ありがとうございました',
      'ご覧いただきありがとうございました',
      'お聞きいただきありがとうございました',
      // チャンネル系
      'チャンネル登録お願いします',
      'チャンネル登録よろしくお願いします',
      'チャンネル登録と高評価お願いします',
      '高評価とチャンネル登録お願いします',
      '高評価ボタンをお願いします',
      'いいねとチャンネル登録お願いします',
      'いいねボタンをお願いします',
      'ベルマークの通知をオンにしてください',
      '通知をオンにしてください',
      // 次回予告系
      '次回もお楽しみに',
      '次回をお楽しみに',
      'お楽しみに',
      'また次回',
      'また次回お会いしましょう',
      'また来週',
      'また今度',
      'それではまた',
      'それではまた次回',
      'また次回の動画でお会いしましょう',
      // 挨拶・締め
      'お疲れ様でした',
      'おつかれさまでした',
      'おやすみなさい',
      'ありがとうございました',
      'ありがとうございます',
      'よろしくお願いします',
      'さようなら',
      'またね',
      'バイバイ',
      'ばいばい',
      // 動画・制作系
      '提供',
      '制作',
      '協力',
      '字幕',
      '翻訳',
      '配信',
      'BGM',
      '音楽',
      '効果音',
      // ネタ系
      'いい加減にしろ',
      // 英語圏Whisperハルシネーション
      'Thanks for watching',
      'Thanks for watching!',
      'Thank you for watching',
      'Thank you for watching!',
      'Thank you.',
      'Thank you',
      'Please subscribe',
      'Subscribe',
      'Like and subscribe',
      'See you next time',
      'See you',
      'Bye',
      'Bye bye',
      'Goodbye',
      'Good night',
      'you',
      'You',
      '.',
      '。',
    ];
    for (final h in exactHallucinations) {
      if (t == h || t == '$h。' || t == '$h！' || t == '$h.') return true;
    }

    // プロンプトエコー系・ノイズ系は部分一致で判定
    const substringHallucinations = [
      // プロンプトエコー（Whisperがプロンプト自体を復唱する現象）
      'ペンダント型マイク',
      'ペンダントマイク',
      'ペンダントの音声',
      'ペンダント音',
      '口の中で音が聞こえない',
      '句読点を含めて正確に文字起こし',
      '背景音やノイズは無視',
      'マイクに近い話者',
      // Claudeの応答系（校正失敗時の応答パターン）
      '音声を聞いてみましょう',
      '音声を聞き取ると',
      '音声が聞こえます',
      '録音した音声を',
      '音声認識テキスト',
      '校正対象の',
      '校正してほしい',
      'テキストが記載されていません',
      'テキストをご提供',
      '提供されたテキスト',
      '以下のように校正',
      '校正結果',
      '申し訳ございません',
      '申し訳ありません',
      // YouTube系ハルシネーション
      'チャンネル登録',
      '高評価',
      'グッドボタン',
      '低評価',
      'ベルマーク',
      'コメント欄',
      '概要欄',
      '動画をご覧',
      '動画を最後まで',
      '次回の動画',
      'ご視聴',
      'ご清聴',
      '最後までお付き合い',
      'ライブ配信',
      '生放送',
      'プレミア公開',
      'YouTube',
      'Youtube',
      'youtube',
      // TV・メディア系
      'MBS毎日放送',
      'TBS',
      'フジテレビ',
      '日本テレビ',
      'テレビ朝日',
      'テレビ東京',
      'NHK',
      '提供は',
      'ご覧のスポンサー',
      'この番組は',
      '番組をお送り',
      '続きはCMの後',
      'コマーシャル',
      'コマーシャルの後',
      // アニメ・ドラマ系
      '次回予告',
      '第1話',
      '第一話',
      '最終回',
      'オープニング',
      'エンディング',
      'オープニングテーマ',
      'エンディングテーマ',
      // その他の典型Whisperハルシネーション
      '音楽が流れています',
      '音楽が流れる',
      'BGMが流れ',
      '拍手',
      '歓声',
      '笑い声',
      '沈黙',
      '無音',
      // TVナレーション・ニュース口調
      'によりますと',
      'だということです',
      'と発表しました',
      'ことがわかりました',
      'ということです',
      'お送りしました',
      'お送りいたしました',
      'リスナーの皆さん',
      'メッセージ募集',
      '番組をお送り',
      'ご覧のスポンサー',
      'この番組は',
      '続きはCMの後',
      '続いては',
      'さて続いては',
      'お伝えしました',
      '中継をお伝え',
      'スタジオからお伝え',
      'レポーターの',
      'コメンテーターの',
      // ゲーム実況
      'レベルアップしました',
      'HPが',
      'MPが',
      'やられた',
      'クリアしました',
      // ドラマ/アニメ特有
      'すいーっ',
      'ぎゃああ',
      'うわあああ',
      // 英語系ハルシネーション
      'Thanks for watching',
      'Thank you for watching',
      'Please subscribe',
      'Don\'t forget to subscribe',
      'Like and subscribe',
      'See you next',
      'See you in the next',
      'Until next time',
      'this video',
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
  /// F0マーカー `[F=180|female]` をテキストから除去する（UI表示の保険用に公開）
  static String stripF0Markers(String text) => _stripF0Markers(text);

  static String _stripF0Markers(String text) {
    return text
        .replaceAll(_f0MarkerRegex, '')
        .replaceAll(_multiSpaceRegex, ' ')
        .trim();
  }

  Future<String?> _correctWithClaude(String whisperText) async {
    // Claude失敗時のフォールバックに使う: F0マーカーを剥がした素のテキスト
    final fallbackText = _stripF0Markers(whisperText);
    try {
      const prompt = '''あなたは日本語音声認識の校正＆話者分離ツールです。
以下の音声認識結果を校正し、話者を推定してください。
この音声はペンダント型マイクで録音されたものです。主に「装着者本人」の発話ですが、会話相手・周囲のTV/動画音声も含まれる場合があります。

入力テキストの各セグメント先頭には F0（基本周波数）解析結果が [F=値|カテゴリ] 形式で付与されています：
  ・F=100前後 / male    → 男性
  ・F=200前後 / female  → 女性
  ・F=300前後 / child   → 子供
このF0マーカーは削除し、話者タグの絵文字選択の参考に使ってください。

【校正ルール】
・文脈から明らかに誤っている漢字・同音異義語のみ修正
・内容の追加・言い換えは一切禁止
・正しい可能性があるものは修正しない（迷ったら元のままにする）

【重複統合ルール（重要）】
・同じフレーズが連続または近接して3回以上繰り返される場合は1つにまとめる（Whisperハルシネーションの典型パターン）
・「ありがとうございました」「はい」「そうですね」等の短い相槌が不自然に連続する場合は削除または1回に集約
・話者タグが異なっても内容が完全に同じ繰り返しは1つに集約
・F0マーカーの値が多少違っても、同一人物の同一発話が繰り返されている場合は統合する

【TV/動画/ゲーム音声の削除ルール（厳格）】
以下に該当する内容は全文まるごと削除し、出力に含めない：
・ニュース/ナレーション口調（「〜によりますと」「〜だということです」「〜と発表しました」）
・ドラマ/アニメのセリフ（感情的な演技口調、擬音語、叫び声）
・CM/番組宣伝（「続きはCMの後」「ご覧のスポンサー」「次回予告」「次週」）
・YouTube系フレーズ（「ご視聴」「チャンネル登録」「高評価」「概要欄」「ベル通知」）
・ラジオ系フレーズ（「リスナーの皆さん」「お送りするのは」「メッセージ募集」）
・ゲーム実況特有表現（「HP」「MP」「レベルアップ」が頻出、実況口調）
・BGMに乗せたナレーション、明らかに脚本じみた言い回し
・1人で長く滔々と語り続ける（通常の会話ではない）
判断に迷う場合：装着者本人が質問や相槌を打っていなければTV音声の可能性が高い → 削除

【話者分離ルール】
・装着者本人は [自分] と表記（性別絵文字付き、後述）
・相手の名前が分かれば [田中👩] のように名前＋絵文字で表記
・名前が分からない相手は [相手🧔] のように属性絵文字のみ
・複数の相手は F0の違いで区別する
・話者が不明な場合は [自分🧔] とする（ペンダントマイクは装着者の声が最も多い）

【性別・年齢絵文字マッピング】
F0マーカーに基づき、話者タグに以下の絵文字を1つだけ付ける：
  ・male    → 🧔（成人男性）
  ・female  → 👩（成人女性）
  ・child   → 👶（子供・確信がある場合のみ）
  ・unknown → 🙂（境界で判定困難）
  ・F0不明  → 🙂（性別不明）
【注意】childと判定される誤検出が多い傾向にある。成人男性の大きな声・語尾上げ・成人女性の感情表現はF0が上がり child に化けやすい。文脈から子供の発話と明確に判断できる場合（内容・話し方）のみ 👶 を使い、迷ったら 🙂 か 🧔/👩 を使うこと。
例：
  [自分🧔] （装着者が男性の場合）
  [自分👩] （装着者が女性の場合）
  [田中👩] （田中さんが女性の場合）
  [相手🧔] （名前不明の男性相手）
  [子供👶] （子供の発話）

【出力形式】
1行目: 会話内容を表す短いタイトル（10文字以内）とタブ区切りで絵文字1つ
例: 打ち合わせ\t💼
例: 買い物\t🛒
例: 家族との雑談\t🏠
2行目以降: 話者タグ付きテキスト（各発言を改行区切り、説明不要、F0マーカーは削除）
[自分🧔] テキスト
[田中👩] テキスト
[相手🧔] テキスト
[子供👶] テキスト

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
        return fallbackText; // 失敗時はF0マーカー除去済みWhisper結果を返す
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final corrected = (json['content'] as List<dynamic>?)
          ?.whereType<Map<String, dynamic>>()
          .firstWhere((c) => c['type'] == 'text', orElse: () => {})['text'] as String?;

      if (corrected == null || corrected.trim().isEmpty) {
        return fallbackText;
      }

      // F0マーカー残留ガード: Claudeが削除し忘れた場合の保険
      final result = _stripF0Markers(corrected);

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
        return fallbackText;
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
      return fallbackText; // エラー時はF0マーカー除去済みWhisper結果を返す
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
      final isSilent = rmsValue < _kSilentWavRms;

      if (isSilent) {
        debugPrint('[AISA VAD] 無音判定: RMS=${rmsValue.toStringAsFixed(0)} (閾値: $_kSilentWavRms)');
      }
      return isSilent;
    } catch (e) {
      debugPrint('[AISA VAD] 音量チェック失敗（APIに送信する）: $e');
      return false; // エラー時はAPIに送る（安全側に倒す）
    }
  }
}
