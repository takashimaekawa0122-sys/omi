// app/lib/utils/aisa_debug_logger.dart
//
// A.I.S.A. インメモリデバッグログシステム（拡張版 + ファイル永続化）
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
// - 【新】ファイル永続化（アプリkill後もログが残る。クラッシュ診断用。）
//   * getApplicationDocumentsDirectory()/aisa_debug_YYYYMMDD.log
//   * 10MBローテーション、3日間保持
//   * 書き込みは単一キューでシリアル実行（レース無し、fire-and-forget）
//   * devLogsToFileEnabled に非依存で常時ON
//   * AisaDebugLogger.initFileLogging() をmain()で呼ぶだけで有効化

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
///
/// 【クラッシュ診断用ファイル永続化】
/// initFileLogging()を起動時に呼ぶと、以降のログが
/// getApplicationDocumentsDirectory()/aisa_debug_YYYYMMDD.log に追記される。
/// アプリkillされてもファイルは残るので、次回起動時に共有できる。
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

  /// ファイルローテーション上限（10MB）
  static const int _maxFileBytes = 10 * 1024 * 1024;

  /// ファイル保持日数
  static const int _retainDays = 3;

  final ListQueue<AisaLogEntry> _entries = ListQueue();
  final DateTime _sessionStartedAt;
  late final String sessionId = _generateSessionId(_sessionStartedAt);

  /// カテゴリ別・レベル別カウンタ（セッション開始からの累積）
  final Map<AisaLogCategory, int> _countsByCategory = {};
  final Map<AisaLogLevel, int> _countsByLevel = {};
  int _totalLogged = 0;

  // === ファイル永続化 ===
  File? _logFile;
  bool _fileLoggingEnabled = false;
  bool _fileInitInProgress = false;
  // 書き込みを1つずつシリアライズするFutureチェーン
  Future<void> _writeQueue = Future<void>.value();

  /// 現在のログファイル（未初期化ならnull）
  File? get logFile => _logFile;

  /// ファイル永続化が有効か
  bool get isFileLoggingEnabled => _fileLoggingEnabled;

  /// 【起動時に1回呼ぶ】ファイル永続化を有効化する。
  /// 失敗してもログ機能自体は壊れない（メモリロギングは継続）。
  Future<void> initFileLogging() async {
    if (_fileLoggingEnabled || _fileInitInProgress) return;
    _fileInitInProgress = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      await _pruneOldLogFiles(dir);
      final f = File('${dir.path}/${_dailyFileName()}');
      if (!(await f.exists())) {
        await f.create(recursive: true);
      }
      _logFile = f;
      _fileLoggingEnabled = true;

      // ヘッダ行を追記（セッション境界が一目でわかるように）
      final header =
          '===== AISA SESSION START ${_sessionStartedAt.toIso8601String()} '
          'sessionId=$sessionId =====\n';
      _enqueueWrite(header);

      // 既存のインメモリエントリを一括でディスクに吐き出す
      // （initFileLogging前のログも保存するため）
      final backlog = _entries.toList();
      if (backlog.isNotEmpty) {
        final sb = StringBuffer();
        for (final e in backlog) {
          sb.writeln(_formatForFile(e));
        }
        _enqueueWrite(sb.toString());
      }

      log(
        'AISA ファイル永続化 有効化',
        level: AisaLogLevel.info,
        category: AisaLogCategory.system,
        context: {'path': f.path},
      );
    } catch (e, st) {
      // ファイル初期化失敗はメモリログに残す
      log(
        'AISA ファイル永続化 初期化失敗: $e',
        level: AisaLogLevel.warning,
        category: AisaLogCategory.system,
        stackTrace: st,
      );
    } finally {
      _fileInitInProgress = false;
    }
  }

  static String _dailyFileName() {
    final d = DateTime.now().toUtc();
    final y = d.year.toString().padLeft(4, '0');
    final m = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return 'aisa_debug_$y$m$day.log';
  }

  static String _formatForFile(AisaLogEntry e) {
    // 1行= JSON（機械処理しやすい + 改行セーフ）
    final payload = <String, Object?>{
      'ts': e.timestamp.toIso8601String(),
      'level': e.level.label.trim(),
      'category': e.category.label,
      'message': e.message,
      if (e.context != null && e.context!.isNotEmpty)
        'context': e.context!.map((k, v) => MapEntry(k, v?.toString())),
      if (e.stackTrace != null) 'stack': e.stackTrace,
    };
    try {
      return jsonEncode(payload);
    } catch (_) {
      // Mapの中に非JSON値が入っていた場合のフォールバック
      return '{"ts":"${e.timestamp.toIso8601String()}","level":"${e.level.label.trim()}","category":"${e.category.label}","message":${jsonEncode(e.message)}}';
    }
  }

  /// 書き込みをキューに投入（fire-and-forget）。
  /// 書き込み失敗時は握りつぶす（ログ機構自体が例外を投げないように）。
  void _enqueueWrite(String line) {
    final f = _logFile;
    if (f == null || !_fileLoggingEnabled) return;
    _writeQueue = _writeQueue.then((_) async {
      try {
        // サイズ上限チェック（10MB超えたらファイルをtruncate）
        final len = await f.length();
        if (len > _maxFileBytes) {
          await f.writeAsString(
            '===== LOG ROTATED ${DateTime.now().toIso8601String()} =====\n',
            mode: FileMode.write,
            flush: true,
          );
        }
        await f.writeAsString(line, mode: FileMode.append, flush: false);
      } catch (_) {
        // 握りつぶす
      }
    });
  }

  /// 3日より古いログファイルを削除
  Future<void> _pruneOldLogFiles(Directory dir) async {
    try {
      final now = DateTime.now().toUtc();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : '';
        if (!name.startsWith('aisa_debug_') || !name.endsWith('.log')) continue;
        final datePart =
            name.replaceAll('aisa_debug_', '').replaceAll('.log', '');
        if (datePart.length != 8) continue;
        final y = int.tryParse(datePart.substring(0, 4));
        final m = int.tryParse(datePart.substring(4, 6));
        final d = int.tryParse(datePart.substring(6, 8));
        if (y == null || m == null || d == null) continue;
        final fileDate = DateTime.utc(y, m, d);
        if (now.difference(fileDate).inDays > _retainDays) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// 利用可能なログファイル一覧（新しい順）。UI共有用。
  Future<List<File>> listLogFiles() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final files = <File>[];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : '';
        if (!name.startsWith('aisa_debug_') || !name.endsWith('.log')) continue;
        files.add(entity);
      }
      files.sort((a, b) =>
          b.uri.pathSegments.last.compareTo(a.uri.pathSegments.last));
      return files;
    } catch (_) {
      return const <File>[];
    }
  }

  /// 書き込みキューが空になるまで待つ（共有前のフラッシュ用）
  Future<void> flush() async {
    try {
      await _writeQueue;
    } catch (_) {}
  }

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

    // ファイル永続化（fire-and-forget。失敗してもログ機能は継続）
    if (_fileLoggingEnabled) {
      _enqueueWrite('${_formatForFile(entry)}\n');
    }

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
