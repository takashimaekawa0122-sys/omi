// app/lib/services/aisa_transcription_service.dart
//
// A.I.S.A. Avalon API 文字起こしサービス
// 音声フレームをWAVに変換し、Avalon APIで文字起こしして Firestore に保存する

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:omi/env/env.dart';
import 'package:omi/services/aisa_firestore_service.dart';

class AisaTranscriptionService {
  AisaTranscriptionService._();
  static final AisaTranscriptionService instance = AisaTranscriptionService._();

  static const _endpoint = 'https://api.aqua.sh/v1/audio/transcriptions';

  /// 音声ファイルを文字起こししてFirestoreに保存し、テキストを返す
  Future<String?> processAndSave(File wavFile) async {
    try {
      final apiKey = Env.avalonApiKey;
      if (apiKey == null || apiKey.isEmpty) {
        debugPrint('[AISA] AVALON_API_KEY が未設定のためスキップ');
        return null;
      }

      final transcript = await _transcribe(wavFile, apiKey);
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

  Future<String?> _transcribe(File wavFile, String apiKey) async {
    final request = http.MultipartRequest('POST', Uri.parse(_endpoint));
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = 'avalon-1';
    request.fields['language'] = 'ja';
    request.files.add(await http.MultipartFile.fromPath('file', wavFile.path));

    final streamedResponse = await request.send();
    final body = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      debugPrint('[AISA] Avalon API エラー ${streamedResponse.statusCode}: $body');
      return null;
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    return json['text'] as String?;
  }
}
