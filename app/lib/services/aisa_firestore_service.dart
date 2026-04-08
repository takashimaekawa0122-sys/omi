// app/lib/services/aisa_firestore_service.dart
//
// A.I.S.A. Firestore書き込みサービス
// Omiの会話完了イベントをA.I.S.A.のFirestoreに保存する

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

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
    if (!_initialized || _firestore == null) return;
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

    debugPrint('[AISA] Groq文字起こし保存成功: $dateStr');
  }
}
