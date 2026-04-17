// app/lib/utils/aisa_debug_logger.dart
//
// A.I.S.A. インメモリデバッグログシステム（拡張版）
// 文字起こしパイプラインの各ステップをリアルタイムで記録し、
// アプリ内のデバッグ画面から確認できる（Xcode不要）。
//
// 拡張機能:
// - 6段階ログレベル (trace/debug/info/warning/error/critical)
// - カテゴリタグ (ble/vad/groq/claude/firestore/offline/live/f0/sync/system)
// - 構造化コンテキスト (Map<String, dynamic>)
// - リングバッファ 2000 件
// - セッション統計 (カテゴリ別/レベル別カウンタ)
// - スタックトレース捕捉
// - 絵文字からのカテゴリ自動推定 (後方互換のため)
// - 既存の info/warning/error(message) API は完全互換

import 'dart:collection';
import 'package:flutter/foundation.dart';

/// ログレベル（重要度順）
enum AisaLogLevel {
  trace,    // 最詳細: フレーム単位のイベント
  debug,    // デバッグ情報
  info,     // 通常の情報
  warning,  // 警告
  error,    // エラー
  critical, // 致命的エラー
}

/// カテゴリタグ（パイプラインのどの部分か）
enum AisaLogCategory {
  ble,       // Bluetooth接続・フレーム受信
  vad,       // 無音判定・RMS
  groq,      // Groq Whisper API
  claude,    // Claude Haiku API
  firestore, // Firestore書き込み/読み込み
  offline,   // WALオフライン同期
  live,      // ライブ文字起こしパイプライン
  f0,        // F0推定・話者分類
  sync,      // 汎用同期
  system,    // 初期化・セッション
  general,   // 未分類（後方互換）
}

extension AisaLogLevelX on AisaLogLevel {
  String get label {
    switch (this) {
      case AisaLogLevel.trace:    return 'TRACE';
      case AisaLogLevel.debug:    return 'DEBUG';
      case AisaLogLevel.info:     return 'INFO ';
      case AisaLogLevel.warning:  return 'WARN ';
      case AisaLogLevel.error:    return 'ERROR';
      case AisaLogLevel.critical: return 'CRIT ';
    }
  }

  /// 重要度（高いほど重要）
  int get severity {
    switch (this) {
      case AisaLogLevel.trace:    return 0;
      case AisaLogLevel.debug:    return 1;
      case AisaLogLevel.info:     return 2;
      case AisaLogLevel.warning:  return 3;
      case AisaLogLevel.error:    return 4;
      case AisaLogLevel.critical: return 5;
    }
  }
}

extension AisaLogCategoryX on AisaLogCategory {
  String get label {
    switch (this) {
      case AisaLogCategory.ble:       return 'BLE';
      case AisaLogCategory.vad:       return 'VAD';
      case AisaLogCategory.groq:      return 'GROQ';
      case AisaLogCategory.claude:    return 'CLAUDE';
      case AisaLogCategory.firestore: return 'FIRE';
      case AisaLogCategory.offline:   return 'OFFLINE';
      case AisaLogCategory.live:      return 'LIVE';
      case AisaLogCategory.f0:        return 'F0';
      case AisaLogCategory.sync:      return 'SYNC';
      case AisaLogCategory.system:    return 'SYS';
      case AisaLogCategory.general:   return 'GEN';
    }
  }
}

/// 1件のログエントリ
class AisaLogEntry {
  final DateTime timestamp;
  final AisaLogLevel level;
  final AisaLogCategory category;
  final String message;
  final Map<String, dynamic>? context;
  final String? stackTrace;

  AisaLogEntry({
    required this.timestamp,
    required this.level,
    required this.category,
    required this.message,
    this.context,
    this.stackTrace,
  });

  String get levelLabel => level.label;
  String get categoryLabel => category.label;

  String get timeLabel {
    final t = timestamp;
    final h  = t.hour.toString().padLeft(2, '0');
    final m  = t.minute.toString().padLeft(2, '0');
    final s  = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  /// 構造化フィールドを "k=v k=v" 形式で整形
  String get contextLabel {
    final ctx = context;
    if (ctx == null || ctx.isEmpty) return '';
    return ctx.entries.map((e) => '${e.key}=${e.value}').join(' ');
  }

  @override
  String toString() {
    final ctxPart = contextLabel.isEmpty ? '' : '  {$contextLabel}';
    final base = '[${timestamp.toIso8601String()}] '
        '${level.label} '
        '[${category.label}] '
        '$message$ctxPart';
    if (stackTrace == null) return base;
    return '$base\n$stackTrace';
  }
}

/// 絵文字→カテゴリの自動推定テーブル
/// (既存コードの `logger.info('🔊 ...')` 形式で後方互換カテゴリを付ける)
const Map<String, AisaLogCategory> _emojiCategoryHints = {
  '📡': AisaLogCategory.ble,
  '🔊': AisaLogCategory.vad,
  '🔇': AisaLogCategory.vad,
  '🎙': AisaLogCategory.live,
  '🎙️': AisaLogCategory.live,
  '🎤': AisaLogCategory.live,
  '📝': AisaLogCategory.groq,
  '🤖': AisaLogCategory.claude,
  '🧠': AisaLogCategory.claude,
  '🔥': AisaLogCategory.firestore,
  '☁': AisaLogCategory.firestore,
  '☁️': AisaLogCategory.firestore,
  '💾': AisaLogCategory.offline,
  '🔄': AisaLogCategory.sync,
  '⚙': AisaLogCategory.system,
  '⚙️': AisaLogCategory.system,
  '🚫': AisaLogCategory.groq,
  '↩': AisaLogCategory.live,
};

/// 単語→カテゴリの自動推定テーブル（絵文字がないメッセージ用フォールバック）
const Map<String, AisaLogCategory> _wordCategoryHints = {
  'Firestore': AisaLogCategory.firestore,
  'Groq': AisaLogCategory.groq,
  'Claude': AisaLogCategory.claude,
  'Whisper': AisaLogCategory.groq,
  'WAL': AisaLogCategory.offline,
  'オフライン': AisaLogCategory.offline,
  'ライブ': AisaLogCategory.live,
  'VAD': AisaLogCategory.vad,
  'RMS': AisaLogCategory.vad,
  'F0': AisaLogCategory.f0,
  '話者': AisaLogCategory.f0,
  'BLE': AisaLogCategory.ble,
  'ペンダント': AisaLogCategory.ble,
};

AisaLogCategory _guessCategory(String message) {
  for (final entry in _emojiCategoryHints.entries) {
    if (message.contains(entry.key)) return entry.value;
  }
  for (final entry in _wordCategoryHints.entries) {
    if (message.contains(entry.key)) return entry.value;
  }
  return AisaLogCategory.general;
}

/// 文字起こしパイプラインのインメモリリングバッファロガー。
/// 最新 [maxEntries] 件を保持し、ChangeNotifier でUIにリアルタイム通知する。
/// ファイルI/Oなし・常時ON・セッション内で有効。
class AisaDebugLogger extends ChangeNotifier {
  AisaDebugLogger._() : _sessionStartedAt = DateTime.now() {
    // セッション開始ヘッダを投入
    log(
      'AISA Debug Logger 起動',
      level: AisaLogLevel.info,
      category: AisaLogCategory.system,
      context: {
        'sessionId': sessionId,
        'startedAt': _sessionStartedAt.toIso8601String(),
      },
    );
  }
  static final AisaDebugLogger instance = AisaDebugLogger._();

  /// リングバッファ上限（従来 200 → 2000 に拡張）
  static const int maxEntries = 2000;

  final ListQueue<AisaLogEntry> _entries = ListQueue();
  final DateTime _sessionStartedAt;
  late final String sessionId = _generateSessionId(_sessionStartedAt);

  /// カテゴリ別・レベル別カウンタ（セッション開始からの累積）
  final Map<AisaLogCategory, int> _countsByCategory = {};
  final Map<AisaLogLevel, int> _countsByLevel = {};
  int _totalLogged = 0;

  List<AisaLogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;

  DateTime get sessionStartedAt => _sessionStartedAt;
  Duration get sessionDuration => DateTime.now().difference(_sessionStartedAt);
  int get totalLogged => _totalLogged;
  Map<AisaLogCategory, int> get countsByCategory => Map.unmodifiable(_countsByCategory);
  Map<AisaLogLevel, int> get countsByLevel => Map.unmodifiable(_countsByLevel);

  /// 汎用ログメソッド
  /// - [category] 省略時はメッセージから自動推定
  /// - [context] 構造化フィールド (例: `{'rms': 142, 'threshold': 100}`)
  /// - [stackTrace] エラー時のスタックトレース (StackTrace または String)
  void log(
    String message, {
    AisaLogLevel level = AisaLogLevel.info,
    AisaLogCategory? category,
    Map<String, dynamic>? context,
    Object? stackTrace,
  }) {
    final cat = category ?? _guessCategory(message);
    if (_entries.length >= maxEntries) _entries.removeFirst();

    final entry = AisaLogEntry(
      timestamp: DateTime.now(),
      level: level,
      category: cat,
      message: message,
      context: context,
      stackTrace: stackTrace?.toString(),
    );
    _entries.addLast(entry);

    // カウンタ更新
    _totalLogged++;
    _countsByCategory[cat] = (_countsByCategory[cat] ?? 0) + 1;
    _countsByLevel[level] = (_countsByLevel[level] ?? 0) + 1;

    notifyListeners();
  }

  // === 便利メソッド（後方互換） ===
  void trace(String message, {AisaLogCategory? category, Map<String, dynamic>? context}) =>
      log(message, level: AisaLogLevel.trace, category: category, context: context);

  void debug(String message, {AisaLogCategory? category, Map<String, dynamic>? context}) =>
      log(message, level: AisaLogLevel.debug, category: category, context: context);

  void info(String message, {AisaLogCategory? category, Map<String, dynamic>? context}) =>
      log(message, level: AisaLogLevel.info, category: category, context: context);

  void warning(String message, {AisaLogCategory? category, Map<String, dynamic>? context}) =>
      log(message, level: AisaLogLevel.warning, category: category, context: context);

  void error(
    String message, {
    AisaLogCategory? category,
    Map<String, dynamic>? context,
    Object? stackTrace,
  }) =>
      log(
        message,
        level: AisaLogLevel.error,
        category: category,
        context: context,
        stackTrace: stackTrace ?? StackTrace.current,
      );

  void critical(
    String message, {
    AisaLogCategory? category,
    Map<String, dynamic>? context,
    Object? stackTrace,
  }) =>
      log(
        message,
        level: AisaLogLevel.critical,
        category: category,
        context: context,
        stackTrace: stackTrace ?? StackTrace.current,
      );

  /// パイプラインステージ別の便利メソッド
  void ble(String message, {AisaLogLevel level = AisaLogLevel.info, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.ble, context: context);

  void vad(String message, {AisaLogLevel level = AisaLogLevel.debug, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.vad, context: context);

  void groq(String message, {AisaLogLevel level = AisaLogLevel.info, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.groq, context: context);

  void claude(String message, {AisaLogLevel level = AisaLogLevel.info, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.claude, context: context);

  void firestore(String message, {AisaLogLevel level = AisaLogLevel.info, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.firestore, context: context);

  void offline(String message, {AisaLogLevel level = AisaLogLevel.info, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.offline, context: context);

  void live(String message, {AisaLogLevel level = AisaLogLevel.info, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.live, context: context);

  void f0(String message, {AisaLogLevel level = AisaLogLevel.debug, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.f0, context: context);

  void system(String message, {AisaLogLevel level = AisaLogLevel.info, Map<String, dynamic>? context}) =>
      log(message, level: level, category: AisaLogCategory.system, context: context);

  void clear() {
    _entries.clear();
    _countsByCategory.clear();
    _countsByLevel.clear();
    _totalLogged = 0;
    notifyListeners();
  }

  /// 指定フィルタでエントリを絞り込む
  List<AisaLogEntry> filteredEntries({
    Set<AisaLogLevel>? levels,
    Set<AisaLogCategory>? categories,
    String? searchQuery,
    AisaLogLevel? minLevel,
  }) {
    final query = searchQuery?.toLowerCase();
    return _entries.where((e) {
      if (minLevel != null && e.level.severity < minLevel.severity) return false;
      if (levels != null && levels.isNotEmpty && !levels.contains(e.level)) return false;
      if (categories != null && categories.isNotEmpty && !categories.contains(e.category)) return false;
      if (query != null && query.isNotEmpty) {
        if (!e.message.toLowerCase().contains(query) &&
            !(e.context?.toString().toLowerCase().contains(query) ?? false)) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  /// クリップボードへのコピー用テキスト（ヘッダ付き）
  String exportAsText({
    Set<AisaLogLevel>? levels,
    Set<AisaLogCategory>? categories,
    String? searchQuery,
  }) {
    final targets = (levels == null && categories == null && (searchQuery == null || searchQuery.isEmpty))
        ? _entries.toList()
        : filteredEntries(levels: levels, categories: categories, searchQuery: searchQuery);

    final header = StringBuffer()
      ..writeln('=== AISA Debug Log Export ===')
      ..writeln('sessionId: $sessionId')
      ..writeln('startedAt: ${_sessionStartedAt.toIso8601String()}')
      ..writeln('duration: ${sessionDuration.inSeconds}s')
      ..writeln('totalLogged: $_totalLogged')
      ..writeln('displayed: ${targets.length} / ${_entries.length} in buffer')
      ..writeln('--- countsByLevel ---');
    for (final lv in AisaLogLevel.values) {
      final c = _countsByLevel[lv] ?? 0;
      if (c > 0) header.writeln('  ${lv.label}: $c');
    }
    header.writeln('--- countsByCategory ---');
    for (final cat in AisaLogCategory.values) {
      final c = _countsByCategory[cat] ?? 0;
      if (c > 0) header.writeln('  ${cat.label}: $c');
    }
    header.writeln('=============================');

    return '$header\n${targets.map((e) => e.toString()).join('\n')}';
  }

  static String _generateSessionId(DateTime startedAt) {
    final t = startedAt;
    return '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
        '-${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}';
  }
}
