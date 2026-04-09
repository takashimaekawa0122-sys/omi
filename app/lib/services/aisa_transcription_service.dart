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

class AisaTranscriptionService {
  AisaTranscriptionService._();
  static final AisaTranscriptionService instance = AisaTranscriptionService._();

  static const _endpoint = 'https://api.groq.com/openai/v1/audio/transcriptions';
  static const _groqApiKey = String.fromEnvironment('GROQ_API_KEY');

  /// 音声ファイルを文字起こししてFirestoreに保存し、テキストを返す
  Future<String?> processAndSave(File wavFile) async {
    try {
      final transcript = await _transcribe(wavFile);
      if (transcript != null && transcript.trim().isNotEmpty) {
        await AisaFirestoreService.instance.saveTranscript(transcript);
        debugPrint('[AISA] 文字起こし成功: $transcript');
        return transcript;
      }
      return null;
    } catch (e) {
      debugPrint('[AISA] 文字起こし処理失敗: $e');
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
  /// 失敗時は例外をthrow（呼び出し元でリトライ処理するため）
  /// WAVファイルの削除は呼び出し元の責任
  Future<String?> transcribeOnly(File wavFile) async {
    return await _transcribe(wavFile); // 例外はそのまま上に伝播
  }

  Future<String?> _transcribe(File wavFile) async {
    final fileSize = await wavFile.length();
    debugPrint('[AISA] Groq送信: ${wavFile.path} (${(fileSize / 1024).toStringAsFixed(0)}KB)');

    final request = http.MultipartRequest('POST', Uri.parse(_endpoint));
    request.headers['Authorization'] = 'Bearer $_groqApiKey';
    request.headers['User-Agent'] = 'AISA/1.0 (iOS; Flutter)';
    request.headers['Accept'] = 'application/json';
    request.fields['model'] = 'whisper-large-v3';
    request.fields['language'] = 'ja';
    request.fields['response_format'] = 'json';
    request.files.add(await http.MultipartFile.fromPath('file', wavFile.path));

    // 90秒タイムアウト: タイムアウト時はTimeoutExceptionをthrow（呼び出し元でリトライ）
    final streamedResponse = await request.send().timeout(
      const Duration(seconds: 90),
      onTimeout: () => throw TimeoutException('Groq API request timed out after 90s'),
    );
    final body = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode == 429) {
      // レートリミット: 呼び出し元で待機・リトライできるよう専用例外をthrow
      throw Exception('Groq rate limit (429): $body');
    }

    if (streamedResponse.statusCode != 200) {
      debugPrint('[AISA] Groq API エラー ${streamedResponse.statusCode}: $body');
      throw Exception('Groq API error ${streamedResponse.statusCode}: $body');
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final text = json['text'] as String?;
    debugPrint('[AISA] Groq成功: ${text?.length ?? 0}文字');
    return text;
  }
}
