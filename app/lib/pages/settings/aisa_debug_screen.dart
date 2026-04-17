// app/lib/pages/settings/aisa_debug_screen.dart
//
// A.I.S.A. ライブデバッグログ画面（拡張版）
// 文字起こしが動かないとき、このページを開けば何が起きているか一目でわかる。
// 設定 → Developer Settings → AISA Live Debug Log から開く。
//
// 拡張機能:
// - レベルフィルター (trace/debug/info/warning/error/critical)
// - カテゴリフィルター (ble/vad/groq/claude/firestore/offline/live/f0/sync/system)
// - 検索フィールド
// - セッション統計ヘッダー
// - 自動スクロールのON/OFFトグル
// - 構造化コンテキスト/スタックトレースの折りたたみ表示

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
  final TextEditingController _searchController = TextEditingController();

  bool _autoScroll = true;
  bool _showStats = true;
  bool _showFilters = false;

  // フィルター状態（空集合＝全許可）
  final Set<AisaLogLevel> _enabledLevels = {};
  final Set<AisaLogCategory> _enabledCategories = {};
  AisaLogLevel _minLevel = AisaLogLevel.trace;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    AisaDebugLogger.instance.addListener(_onNewLog);
  }

  @override
  void dispose() {
    AisaDebugLogger.instance.removeListener(_onNewLog);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _onNewLog() {
    if (!_autoScroll) return;
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
    final text = AisaDebugLogger.instance.exportAsText(
      levels: _enabledLevels.isEmpty ? null : _enabledLevels,
      categories: _enabledCategories.isEmpty ? null : _enabledCategories,
      searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
    );
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
      case AisaLogLevel.trace:    return Colors.grey.shade600;
      case AisaLogLevel.debug:    return Colors.cyan.shade300;
      case AisaLogLevel.info:     return Colors.grey.shade300;
      case AisaLogLevel.warning:  return Colors.orange;
      case AisaLogLevel.error:    return Colors.red.shade400;
      case AisaLogLevel.critical: return Colors.pink.shade200;
    }
  }

  Color _levelBgColor(AisaLogLevel level) {
    switch (level) {
      case AisaLogLevel.trace:    return Colors.grey.shade900;
      case AisaLogLevel.debug:    return Colors.cyan.shade900;
      case AisaLogLevel.info:     return Colors.grey.shade800;
      case AisaLogLevel.warning:  return Colors.orange.shade900;
      case AisaLogLevel.error:    return Colors.red.shade900;
      case AisaLogLevel.critical: return const Color(0xFF5C0015);
    }
  }

  Color _categoryColor(AisaLogCategory cat) {
    switch (cat) {
      case AisaLogCategory.ble:       return Colors.blue.shade300;
      case AisaLogCategory.vad:       return Colors.teal.shade300;
      case AisaLogCategory.groq:      return Colors.purple.shade300;
      case AisaLogCategory.claude:    return Colors.deepPurple.shade200;
      case AisaLogCategory.firestore: return Colors.amber.shade400;
      case AisaLogCategory.offline:   return Colors.brown.shade300;
      case AisaLogCategory.live:      return Colors.green.shade300;
      case AisaLogCategory.f0:        return Colors.pink.shade300;
      case AisaLogCategory.sync:      return Colors.indigo.shade200;
      case AisaLogCategory.system:    return Colors.blueGrey.shade200;
      case AisaLogCategory.general:   return Colors.grey.shade500;
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
          builder: (_, __) {
            final total = AisaDebugLogger.instance.length;
            return Text(
              'AISA Debug Log ($total)',
              style: const TextStyle(color: Colors.white, fontSize: 17),
            );
          },
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause_circle_outline,
              color: _autoScroll ? Colors.greenAccent : Colors.white70,
            ),
            tooltip: _autoScroll ? '自動スクロール中' : '自動スクロール停止中',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            icon: Icon(
              _showFilters ? Icons.filter_alt : Icons.filter_alt_outlined,
              color: _showFilters ? Colors.greenAccent : Colors.white70,
            ),
            tooltip: 'フィルター',
            onPressed: () => setState(() => _showFilters = !_showFilters),
          ),
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
      body: Column(
        children: [
          if (_showStats)
            ListenableBuilder(
              listenable: AisaDebugLogger.instance,
              builder: (_, __) => _StatsHeader(
                onToggle: () => setState(() => _showStats = !_showStats),
              ),
            ),
          if (_showFilters) _buildFilterPanel(),
          if (_showFilters) _buildSearchBar(),
          Expanded(child: _buildLogList()),
        ],
      ),
    );
  }

  Widget _buildFilterPanel() {
    return Container(
      color: const Color(0xFF151517),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('レベル', style: TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: AisaLogLevel.values.map((lv) {
              final selected = _enabledLevels.contains(lv);
              return FilterChip(
                label: Text(lv.label.trim(), style: const TextStyle(fontSize: 11)),
                selected: selected,
                onSelected: (v) => setState(() {
                  if (v) {
                    _enabledLevels.add(lv);
                  } else {
                    _enabledLevels.remove(lv);
                  }
                }),
                selectedColor: _levelBgColor(lv),
                backgroundColor: const Color(0xFF202024),
                labelStyle: TextStyle(color: _levelColor(lv)),
                checkmarkColor: _levelColor(lv),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          const Text('カテゴリ', style: TextStyle(color: Colors.white54, fontSize: 11)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: AisaLogCategory.values.map((cat) {
              final selected = _enabledCategories.contains(cat);
              return FilterChip(
                label: Text(cat.label, style: const TextStyle(fontSize: 11)),
                selected: selected,
                onSelected: (v) => setState(() {
                  if (v) {
                    _enabledCategories.add(cat);
                  } else {
                    _enabledCategories.remove(cat);
                  }
                }),
                selectedColor: Colors.grey.shade800,
                backgroundColor: const Color(0xFF202024),
                labelStyle: TextStyle(color: _categoryColor(cat)),
                checkmarkColor: _categoryColor(cat),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              );
            }).toList(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text('最小レベル: ', style: TextStyle(color: Colors.white54, fontSize: 11)),
              const SizedBox(width: 4),
              DropdownButton<AisaLogLevel>(
                value: _minLevel,
                dropdownColor: const Color(0xFF1C1C1E),
                style: TextStyle(color: _levelColor(_minLevel), fontSize: 12),
                items: AisaLogLevel.values
                    .map((lv) => DropdownMenuItem(value: lv, child: Text(lv.label.trim())))
                    .toList(),
                onChanged: (v) {
                  if (v != null) setState(() => _minLevel = v);
                },
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() {
                  _enabledLevels.clear();
                  _enabledCategories.clear();
                  _minLevel = AisaLogLevel.trace;
                  _searchController.clear();
                  _searchQuery = '';
                }),
                child: const Text('リセット', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      color: const Color(0xFF151517),
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: TextField(
        controller: _searchController,
        style: const TextStyle(color: Colors.white, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'メッセージ/コンテキストを検索',
          hintStyle: TextStyle(color: Colors.grey.shade600, fontSize: 13),
          prefixIcon: Icon(Icons.search, color: Colors.grey.shade500, size: 18),
          isDense: true,
          filled: true,
          fillColor: const Color(0xFF202024),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(6),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  Widget _buildLogList() {
    return ListenableBuilder(
      listenable: AisaDebugLogger.instance,
      builder: (context, _) {
        final allEntries = AisaDebugLogger.instance.entries;
        final entries = AisaDebugLogger.instance.filteredEntries(
          levels: _enabledLevels.isEmpty ? null : _enabledLevels,
          categories: _enabledCategories.isEmpty ? null : _enabledCategories,
          minLevel: _minLevel,
          searchQuery: _searchQuery.isEmpty ? null : _searchQuery,
        );

        if (allEntries.isEmpty) {
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

        if (entries.isEmpty) {
          return Center(
            child: Text(
              'フィルター条件に一致するログがありません\n(${allEntries.length}件中 0件)',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
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
              categoryColor: _categoryColor(entry.category),
            );
          },
        );
      },
    );
  }
}

class _StatsHeader extends StatelessWidget {
  final VoidCallback onToggle;
  const _StatsHeader({required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final logger = AisaDebugLogger.instance;
    final errCount = (logger.countsByLevel[AisaLogLevel.error] ?? 0) +
        (logger.countsByLevel[AisaLogLevel.critical] ?? 0);
    final warnCount = logger.countsByLevel[AisaLogLevel.warning] ?? 0;
    final duration = logger.sessionDuration;

    return InkWell(
      onTap: onToggle,
      child: Container(
        color: const Color(0xFF1C1C1E),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatChip(label: 'Session', value: logger.sessionId, color: Colors.blueGrey.shade200),
                const SizedBox(width: 6),
                _StatChip(label: 'Uptime', value: '${duration.inMinutes}m${duration.inSeconds.remainder(60)}s', color: Colors.grey.shade400),
                const SizedBox(width: 6),
                _StatChip(label: 'Total', value: '${logger.totalLogged}', color: Colors.grey.shade400),
                const SizedBox(width: 6),
                if (errCount > 0)
                  _StatChip(label: 'ERR', value: '$errCount', color: Colors.red.shade400),
                if (warnCount > 0) ...[
                  const SizedBox(width: 6),
                  _StatChip(label: 'WARN', value: '$warnCount', color: Colors.orange),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final cat in AisaLogCategory.values)
                  if ((logger.countsByCategory[cat] ?? 0) > 0)
                    _StatChip(
                      label: cat.label,
                      value: '${logger.countsByCategory[cat]}',
                      color: _staticCategoryColor(cat),
                      small: true,
                    ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Color _staticCategoryColor(AisaLogCategory cat) {
    switch (cat) {
      case AisaLogCategory.ble:       return Colors.blue.shade300;
      case AisaLogCategory.vad:       return Colors.teal.shade300;
      case AisaLogCategory.groq:      return Colors.purple.shade300;
      case AisaLogCategory.claude:    return Colors.deepPurple.shade200;
      case AisaLogCategory.firestore: return Colors.amber.shade400;
      case AisaLogCategory.offline:   return Colors.brown.shade300;
      case AisaLogCategory.live:      return Colors.green.shade300;
      case AisaLogCategory.f0:        return Colors.pink.shade300;
      case AisaLogCategory.sync:      return Colors.indigo.shade200;
      case AisaLogCategory.system:    return Colors.blueGrey.shade200;
      case AisaLogCategory.general:   return Colors.grey.shade500;
    }
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final bool small;
  const _StatChip({required this.label, required this.value, required this.color, this.small = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 8, vertical: small ? 2 : 3),
      decoration: BoxDecoration(
        color: const Color(0xFF2A2A2E),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: color,
          fontSize: small ? 10 : 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _LogRow extends StatefulWidget {
  final AisaLogEntry entry;
  final Color levelColor;
  final Color levelBgColor;
  final Color categoryColor;

  const _LogRow({
    required this.entry,
    required this.levelColor,
    required this.levelBgColor,
    required this.categoryColor,
  });

  @override
  State<_LogRow> createState() => _LogRowState();
}

class _LogRowState extends State<_LogRow> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final hasContext = widget.entry.context != null && widget.entry.context!.isNotEmpty;
    final hasStack = widget.entry.stackTrace != null;
    final expandable = hasContext || hasStack;

    return InkWell(
      onTap: expandable ? () => setState(() => _expanded = !_expanded) : null,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // タイムスタンプ
                Text(
                  widget.entry.timeLabel,
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 6),
                // レベルバッジ
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: widget.levelBgColor,
                    borderRadius: BorderRadius.circular(3),
                  ),
                  child: Text(
                    widget.entry.level.label.trim(),
                    style: TextStyle(
                      color: widget.levelColor,
                      fontSize: 9,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // カテゴリバッジ
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  decoration: BoxDecoration(
                    color: const Color(0xFF23232A),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: widget.categoryColor.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    widget.entry.category.label,
                    style: TextStyle(
                      color: widget.categoryColor,
                      fontSize: 9,
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                // メッセージ
                Expanded(
                  child: Text(
                    widget.entry.message,
                    style: TextStyle(
                      color: widget.levelColor,
                      fontSize: 12,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                if (expandable)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: Colors.grey.shade600,
                  ),
              ],
            ),
            if (_expanded && hasContext)
              Padding(
                padding: const EdgeInsets.only(left: 80, top: 3, bottom: 2),
                child: Text(
                  '{${widget.entry.contextLabel}}',
                  style: TextStyle(
                    color: Colors.cyan.shade200,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            if (_expanded && hasStack)
              Padding(
                padding: const EdgeInsets.only(left: 80, top: 3, bottom: 4),
                child: Text(
                  widget.entry.stackTrace!,
                  style: TextStyle(
                    color: Colors.grey.shade500,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
