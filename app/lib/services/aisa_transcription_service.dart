// app/lib/services/aisa_transcription_service.dart
//
// A.I.S.A. Avalon API 文字起こしサービス
// 音声フレームをWAVに変換し、Avalon APIで文字起こしして Firestore に保存する

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:omi/services/aisa_firestore_service.dart';

class AisaTranscriptionService {
  AisaTranscriptionService._();
  static final AisaTranscriptionService instance = AisaTranscriptionService._();

  static const _endpoint = 'https://api.aqua.sh/v1/audio/transcriptions';
  static const _avalonApiKey = 'ava_T36UOxfEN_QUrpg2V-l6fzhZfplNoCFJUHLwAylKzrY';

  /// 音声ファイルを文字起こししてFirestoreに保存し、テキストを返す
  Future<String?> processAndSave(File wavFile) async {
    try {
      const apiKey = _avalonApiKey;
      await AisaFirestoreService.instance.saveTranscript('[診断] APIキー確認OK length=${apiKey.length} prefix=${apiKey.substring(0, 8)}');

      final transcript = await _transcribe(wavFile, apiKey);
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

  Future<String?> _transcribe(File wavFile, String apiKey) async {
    final request = http.MultipartRequest('POST', Uri.parse(_endpoint));
    request.headers['Authorization'] = 'Bearer $apiKey';
    request.fields['model'] = 'avalon-1';
    request.fields['language'] = 'ja';
    request.files.add(await http.MultipartFile.fromPath('file', wavFile.path));

    // SSL証明書検証をスキップするカスタムクライアント（api.aqua.sh対応）
    final httpClient = HttpClient()
      ..badCertificateCallback = (cert, host, port) => true;
    final ioClient = IOClient(httpClient);

    final streamedResponse = await ioClient.send(request);
    final body = await streamedResponse.stream.bytesToString();
    ioClient.close();

    if (streamedResponse.statusCode != 200) {
      debugPrint('[AISA] Avalon API エラー ${streamedResponse.statusCode}: $body');
      await AisaFirestoreService.instance.saveTranscript(
          '[診断] Avalon HTTP ${streamedResponse.statusCode}: ${body.length > 200 ? body.substring(0, 200) : body}');
      return null;
    }

    final json = jsonDecode(body) as Map<String, dynamic>;
    final text = json['text'] as String?;
    await AisaFirestoreService.instance.saveTranscript(
        '[診断] Avalon HTTP 200 text="${text}" json_keys=${json.keys.toList()}');
    return text;
  }
}
