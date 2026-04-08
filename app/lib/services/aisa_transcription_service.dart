// app/lib/services/aisa_transcription_service.dart
//
// A.I.S.A. Groq Whisper 文字起こしサービス
// 音声フレームをWAVに変換し、Groq Whisper APIで文字起こしして Firestore に保存する

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
      await AisaFirestoreService.instance.saveTranscript('[診断] processAndSave例外: $e');
      return null;
    } finally {
      try {
        if (await wavFile.exists()) {
          await wavFile.delete();
        }
      } catch (_) {}
    }
  }

  Future<String?> _transcribe(File wavFile) async {
    final request = http.MultipartRequest('POST', Uri.parse(_endpoint));
    request.headers['Authorization'] = 'Bearer $_groqApiKey';
    request.headers['User-Agent'] = 'AISA/1.0 (iOS; Flutter)';
    request.headers['Accept'] = 'application/json';
    request.fields['model'] = 'whisper-large-v3';
    request.fields['language'] = 'ja';
    request.fields['response_format'] = 'json';
    request.files.add(await http.MultipartFile.fromPath('file', wavFile.path));

    final streamedResponse = await request.send();
    final body = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      debugPrint('[AISA] Groq API エラー ${streamedResponse.statusCode}: $body');
      await AisaFirestoreService.instance.saveTranscript(
          '[診断] Groq HTTP ${streamedResponse.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}');
      return null;
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    return json['text'] as String?;
  }
}
