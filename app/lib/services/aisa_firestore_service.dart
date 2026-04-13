// app/lib/services/aisa_firestore_service.dart
//
// A.I.S.A. Firestore書き込みサービス
// Omiの会話完了イベントをA.I.S.A.のFirestoreに保存する

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/utils/aisa_debug_logger.dart';

const _aisaFirebaseOptions = FirebaseOptions(
  apiKey: 'AIzaSyCDMXPc798PXd2Q7V0zC3NfcG-95BXR3vY',
  appId: '1:587569678804:ios:2aa2aff62c2dd2baccee41',
  messagingSenderId: '587569678804',
  projectId: 'aisa-5c0bd',
);

class AisaFirestoreService {
  AisaFirestoreService._();
  static final AisaFirestoreService instance = AisaFirestoreService._();

  FirebaseFirestore? _firestore;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    try {
      final app = await Firebase.initializeApp(
        name: 'aisa',
        options: _aisaFirebaseOptions,
      );
      _firestore = FirebaseFirestore.instanceFor(app: app);

      final auth = FirebaseAuth.instanceFor(app: app);
      if (auth.currentUser == null) {
        await auth.signInAnonymously();
      }

      _initialized = true;
      debugPrint('[AISA] Firestore初期化完了');
    } catch (e) {
      debugPrint('[AISA] Firestore初期化失敗: $e');
    }
  }

  Future<void> saveConversation(dynamic conversation) async {
    if (!_initialized || _firestore == null) return;

    try {
      final segments = conversation.transcriptSegments as List<dynamic>;
      if (segments.isEmpty) return;

      final text = segments.map((s) {
        final speaker = (s.isUser as bool) ? '自分' : '相手';
        return '[$speaker] ${s.text}';
      }).join('\n');

      final now = DateTime.now();
      final dateStr =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';

      await _firestore!
          .collection('sessions')
          .doc(dateStr)
          .collection('entries')
          .add({
        'text': text,
        'timestampMs': now.millisecondsSinceEpoch,
        'deleted': false,
      });

      debugPrint('[AISA] 書き込み成功: $dateStr (${segments.length}セグメント)');
    } catch (e) {
      debugPrint('[AISA] 書き込み失敗: $e');
      rethrow;
    }
  }

  Future<void> saveTranscript(String transcript) async {
    if (!_initialized || _firestore == null) {
      AisaDebugLogger.instance.warning('⚠ Firestore未初期化 - 保存スキップ');
      return;
    }
    if (transcript.trim().isEmpty) return;

    final now = DateTime.now();
    final dateStr =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    await _firestore!
        .collection('sessions')
        .doc(dateStr)
        .collection('entries')
        .add({
      'text': transcript,
      'timestampMs': now.millisecondsSinceEpoch,
      'deleted': false,
      'source': 'groq',
    });

    AisaDebugLogger.instance.info('Firestore保存: $dateStr (${transcript.length}文字)');
    debugPrint('[AISA] Groq文字起こし保存成功: $dateStr');
  }

  /// Firestoreから今日の会話を読み込む（起動時に呼び出し）
  /// 直近7日分を取得して会話リストに復元する
  Future<List<AisaEntry>> loadRecentEntries({int days = 7}) async {
    if (!_initialized || _firestore == null) {
      AisaDebugLogger.instance.warning('⚠ Firestore未初期化 - 読み込みスキップ');
      return [];
    }

    final entries = <AisaEntry>[];
    final now = DateTime.now();

    for (int d = 0; d < days; d++) {
      final date = now.subtract(Duration(days: d));
      final dateStr =
          '${date.year.toString().padLeft(4, '0')}-'
          '${date.month.toString().padLeft(2, '0')}-'
          '${date.day.toString().padLeft(2, '0')}';

      try {
        // orderByのみ使用（where+orderByの複合インデックスが未設定だとエラーになるため）
        // deleted==trueのエントリはDart側でフィルタする
        final snapshot = await _firestore!
            .collection('sessions')
            .doc(dateStr)
            .collection('entries')
            .orderBy('timestampMs', descending: false)
            .get();

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final deleted = data['deleted'] as bool? ?? false;
          if (deleted) continue;
          final text = data['text'] as String? ?? '';
          final timestampMs = data['timestampMs'] as int? ?? 0;
          if (text.trim().isEmpty) continue;

          entries.add(AisaEntry(
            id: doc.id,
            text: text,
            timestamp: DateTime.fromMillisecondsSinceEpoch(timestampMs),
          ));
        }
      } catch (e) {
        debugPrint('[AISA] Firestore読み込みエラー ($dateStr): $e');
      }
    }

    AisaDebugLogger.instance.info('Firestore読み込み: ${entries.length}件 (${days}日分)');
    debugPrint('[AISA] Firestore読み込み完了: ${entries.length}件');
    return entries;
  }
}

/// Firestoreから読み込んだ会話エントリ
class AisaEntry {
  final String id;
  final String text;
  final DateTime timestamp;

  AisaEntry({required this.id, required this.text, required this.timestamp});
}
