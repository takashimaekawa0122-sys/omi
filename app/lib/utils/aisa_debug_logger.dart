// app/lib/utils/aisa_debug_logger.dart
//
// A.I.S.A. インメモリデバッグログシステム
// 文字起こしパイプラインの各ステップをリアルタイムで記録し、
// アプリ内のデバッグ画面から確認できる（Xcode不要）

import 'dart:collection';
import 'package:flutter/foundation.dart';

enum AisaLogLevel { info, warning, error }

class AisaLogEntry {
  final DateTime timestamp;
  final AisaLogLevel level;
  final String message;

  AisaLogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
  });

  String get levelLabel {
    switch (level) {
      case AisaLogLevel.info:    return 'INFO   ';
      case AisaLogLevel.warning: return 'WARNING';
      case AisaLogLevel.error:   return 'ERROR  ';
    }
  }

  String get timeLabel {
    final t = timestamp;
    final h  = t.hour.toString().padLeft(2, '0');
    final m  = t.minute.toString().padLeft(2, '0');
    final s  = t.second.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    return '$h:$m:$s.$ms';
  }

  @override
  String toString() => '[${timestamp.toIso8601String()}] $levelLabel $message';
}

/// 文字起こしパイプラインのインメモリリングバッファロガー。
/// 最新 [maxEntries] 件を保持し、ChangeNotifier でUIにリアルタイム通知する。
/// ファイルI/Oなし・常時ON・セッション内で有効。
class AisaDebugLogger extends ChangeNotifier {
  AisaDebugLogger._();
  static final AisaDebugLogger instance = AisaDebugLogger._();

  static const int maxEntries = 200;
  final ListQueue<AisaLogEntry> _entries = ListQueue();

  List<AisaLogEntry> get entries => List.unmodifiable(_entries);
  int get length => _entries.length;

  void log(String message, {AisaLogLevel level = AisaLogLevel.info}) {
    if (_entries.length >= maxEntries) _entries.removeFirst();
    _entries.addLast(AisaLogEntry(
      timestamp: DateTime.now(),
      level: level,
      message: message,
    ));
    notifyListeners();
  }

  void info(String message)    => log(message, level: AisaLogLevel.info);
  void warning(String message) => log(message, level: AisaLogLevel.warning);
  void error(String message)   => log(message, level: AisaLogLevel.error);

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// クリップボードへのコピー用テキスト
  String exportAsText() {
    return _entries.map((e) => e.toString()).join('\n');
  }
}
