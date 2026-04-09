// app/lib/pages/settings/aisa_debug_screen.dart
//
// A.I.S.A. ライブデバッグログ画面
// 文字起こしが動かないとき、このページを開けば何が起きているか一目でわかる。
// 設定 → Developer Settings → AISA Live Debug Log から開く。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:omi/utils/aisa_debug_logger.dart';

class AisaDebugScreen extends StatefulWidget {
  const AisaDebugScreen({super.key});

  @override
  State<AisaDebugScreen> createState() => _AisaDebugScreenState();
}

class _AisaDebugScreenState extends State<AisaDebugScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    // 新しいログが追加されたら最下部へ自動スクロール
    AisaDebugLogger.instance.addListener(_onNewLog);
  }

  @override
  void dispose() {
    AisaDebugLogger.instance.removeListener(_onNewLog);
    _scrollController.dispose();
    super.dispose();
  }

  void _onNewLog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _copyToClipboard() {
    final text = AisaDebugLogger.instance.exportAsText();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ログがありません')),
      );
      return;
    }
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${AisaDebugLogger.instance.length}件のログをコピーしました'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _clearLogs() {
    AisaDebugLogger.instance.clear();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('ログをクリアしました'),
        duration: Duration(seconds: 1),
      ),
    );
  }

  Color _levelColor(AisaLogLevel level) {
    switch (level) {
      case AisaLogLevel.info:    return Colors.grey.shade400;
      case AisaLogLevel.warning: return Colors.orange;
      case AisaLogLevel.error:   return Colors.red.shade400;
    }
  }

  Color _levelBgColor(AisaLogLevel level) {
    switch (level) {
      case AisaLogLevel.info:    return Colors.grey.shade800;
      case AisaLogLevel.warning: return Colors.orange.shade900;
      case AisaLogLevel.error:   return Colors.red.shade900;
    }
  }

  String _levelText(AisaLogLevel level) {
    switch (level) {
      case AisaLogLevel.info:    return 'INFO';
      case AisaLogLevel.warning: return 'WARN';
      case AisaLogLevel.error:   return 'ERR ';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1C1C1E),
        title: ListenableBuilder(
          listenable: AisaDebugLogger.instance,
          builder: (_, __) => Text(
            'AISA Debug Log (${AisaDebugLogger.instance.length})',
            style: const TextStyle(color: Colors.white, fontSize: 17),
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.white70),
            tooltip: 'クリップボードにコピー',
            onPressed: _copyToClipboard,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white70),
            tooltip: 'ログをクリア',
            onPressed: _clearLogs,
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: AisaDebugLogger.instance,
        builder: (context, _) {
          final entries = AisaDebugLogger.instance.entries;

          if (entries.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.terminal, size: 48, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  Text(
                    'ログがまだありません',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ペンダントを接続して話しかけると\nここにログが表示されます',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade700, fontSize: 13),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return _LogRow(
                entry: entry,
                levelColor: _levelColor(entry.level),
                levelBgColor: _levelBgColor(entry.level),
                levelText: _levelText(entry.level),
              );
            },
          );
        },
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  final AisaLogEntry entry;
  final Color levelColor;
  final Color levelBgColor;
  final String levelText;

  const _LogRow({
    required this.entry,
    required this.levelColor,
    required this.levelBgColor,
    required this.levelText,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // タイムスタンプ
          Text(
            entry.timeLabel,
            style: TextStyle(
              color: Colors.grey.shade600,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          // レベルバッジ
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: levelBgColor,
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              levelText,
              style: TextStyle(
                color: levelColor,
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // メッセージ
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                color: levelColor,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
