// app/lib/services/aisa_firestore_service.dart
//
// A.I.S.A. Firestore書き込みサービス
// Omiの会話完了イベントをA.I.S.A.のFirestoreに保存する

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:omi/models/aisa_daily_summary.dart';
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
      // Firebase.initializeAppは2回呼ぶと例外を投げるため、既存のappを先に確認
      FirebaseApp app;
      try {
        app = Firebase.app('aisa');
      } catch (_) {
        app = await Firebase.initializeApp(
          name: 'aisa',
          options: _aisaFirebaseOptions,
        );
      }
      _firestore = FirebaseFirestore.instanceFor(app: app);

      final auth = FirebaseAuth.instanceFor(app: app);
      if (auth.currentUser == null) {
        await auth.signInAnonymously();
        debugPrint('[AISA] Firestore匿名認証完了: uid=${auth.currentUser?.uid}');
      } else {
        debugPrint('[AISA] Firestore既存認証: uid=${auth.currentUser?.uid}');
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

  /// Firestoreへ会話を保存する。
  /// [transcript] は Claude 出力の生テキスト（"タイトル\t絵文字\n本文" 形式）。
  /// [title] / [emoji] / [body] を渡すとパース済みフィールドも一緒に保存する（後方互換のため任意）。
  /// パース済みフィールドがあれば読み込み時の再パース事故を防げる。
  Future<String?> saveTranscript(
    String transcript, {
    String? title,
    String? emoji,
    String? body,
  }) async {
    if (!_initialized || _firestore == null) {
      AisaDebugLogger.instance.warning('⚠ Firestore未初期化 - 保存スキップ');
      return null;
    }
    if (transcript.trim().isEmpty) return null;

    final now = DateTime.now();
    final dateStr =
        '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';

    final data = <String, dynamic>{
      'text': transcript, // 後方互換のため生テキストも残す
      'timestampMs': now.millisecondsSinceEpoch,
      'deleted': false,
      'source': 'groq',
    };
    // パース済みフィールド（新スキーマ）
    if (title != null && title.trim().isNotEmpty) data['title'] = title.trim();
    if (emoji != null && emoji.trim().isNotEmpty) data['emoji'] = emoji.trim();
    if (body != null && body.trim().isNotEmpty) data['body'] = body.trim();

    final docRef = await _firestore!
        .collection('sessions')
        .doc(dateStr)
        .collection('entries')
        .add(data);

    AisaDebugLogger.instance.info('Firestore保存: $dateStr (${transcript.length}文字)');
    debugPrint('[AISA] Groq文字起こし保存成功: $dateStr id=${docRef.id}');
    return docRef.id;
  }

  /// Firestoreから今日の会話を読み込む（起動時に呼び出し）
  /// 直近7日分を取得して会話リストに復元する
  Future<List<AisaEntry>> loadRecentEntries({int days = 7}) async {
    debugPrint('[AISA load] loadRecentEntries開始: initialized=$_initialized, firestore=${_firestore != null}');
    if (!_initialized || _firestore == null) {
      AisaDebugLogger.instance.warning('⚠ Firestore未初期化 - 読み込みスキップ');
      debugPrint('[AISA load] ❌ Firestore未初期化のため読み込み不可');
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
        // orderByなしでシンプルに全件取得（orderByインデックスエラーを回避）
        final snapshot = await _firestore!
            .collection('sessions')
            .doc(dateStr)
            .collection('entries')
            .get();

        debugPrint('[AISA load] $dateStr: ${snapshot.docs.length}件取得');

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
            title: data['title'] as String?,
            emoji: data['emoji'] as String?,
            body: data['body'] as String?,
          ));
        }
      } catch (e) {
        debugPrint('[AISA load] ❌ $dateStr エラー: $e');
        AisaDebugLogger.instance.error('Firestore読み込みエラー ($dateStr): $e');
      }
    }

    // タイムスタンプでソート（新しい順）
    entries.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    AisaDebugLogger.instance.info('Firestore読み込み: ${entries.length}件 (${days}日分)');
    debugPrint('[AISA load] 読み込み完了: ${entries.length}件');
    return entries;
  }
  /// 日次要約をFirestoreに保存
  Future<void> saveSummary(String dateStr, AisaDailySummary summary) async {
    if (!_initialized || _firestore == null) return;
    try {
      await _firestore!.collection('sessions').doc(dateStr).set(
        {'summary': summary.toJson()},
        SetOptions(merge: true),
      );
      debugPrint('[AISA] 要約保存成功: $dateStr');
    } catch (e) {
      debugPrint('[AISA] 要約保存失敗: $e');
    }
  }

  /// 日次要約をFirestoreから読み込む
  Future<AisaDailySummary?> loadSummary(String dateStr) async {
    if (!_initialized || _firestore == null) return null;
    try {
      final doc = await _firestore!.collection('sessions').doc(dateStr).get();
      if (!doc.exists) return null;
      final data = doc.data();
      final summaryData = data?['summary'] as Map<String, dynamic>?;
      if (summaryData == null) return null;
      return AisaDailySummary.fromJson(summaryData);
    } catch (e) {
      debugPrint('[AISA] 要約読み込み失敗: $e');
      return null;
    }
  }
}

/// Firestoreから読み込んだ会話エントリ
/// 新スキーマでは [title] / [emoji] / [body] がパース済みで保存されている。
/// レガシースキーマでは [text] のみ（呼び出し側で再パースする）。
class AisaEntry {
  final String id;
  final String text;
  final DateTime timestamp;
  final String? title;
  final String? emoji;
  final String? body;

  AisaEntry({
    required this.id,
    required this.text,
    required this.timestamp,
    this.title,
    this.emoji,
    this.body,
  });

  /// 新スキーマで保存されているか（パース済みフィールドを持つか）
  bool get hasParsedFields => (body != null && body!.trim().isNotEmpty);
}
