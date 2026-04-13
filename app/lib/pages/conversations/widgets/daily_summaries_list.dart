import 'package:flutter/material.dart';

import 'package:omi/models/aisa_daily_summary.dart';
import 'package:omi/services/aisa_summary_service.dart';

class DailySummariesList extends StatefulWidget {
  const DailySummariesList({super.key});

  @override
  State<DailySummariesList> createState() => _DailySummariesListState();
}

class _DailySummariesListState extends State<DailySummariesList> {
  AisaDailySummary? _summary;
  bool _isLoading = true;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _loadSummary();
  }

  Future<void> _loadSummary() async {
    setState(() => _isLoading = true);
    final summary = await AisaSummaryService.instance.loadTodaySummary();
    if (mounted) {
      setState(() {
        _summary = summary;
        _isLoading = false;
      });
    }
  }

  Future<void> _generateNow() async {
    setState(() => _isGenerating = true);
    final summary = await AisaSummaryService.instance.generateDailySummary();
    if (mounted) {
      setState(() {
        if (summary != null) _summary = summary;
        _isGenerating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator(color: Colors.white54)),
        ),
      );
    }

    if (_summary == null) {
      return SliverToBoxAdapter(child: _buildEmptyState());
    }

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ヘッダー
            Row(
              children: [
                const Text('📊', style: TextStyle(fontSize: 24)),
                const SizedBox(width: 8),
                Text(
                  '${_summary!.date} のまとめ',
                  style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                // 更新ボタン
                GestureDetector(
                  onTap: _isGenerating ? null : _generateNow,
                  child: _isGenerating
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54))
                      : const Icon(Icons.refresh, color: Colors.white54, size: 20),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // 結論
            _buildSection(
              icon: '💡',
              title: '結論',
              child: Text(
                _summary!.conclusions,
                style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
              ),
            ),

            // 要約
            _buildSection(
              icon: '📝',
              title: '要約',
              child: Text(
                _summary!.summary,
                style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
              ),
            ),

            // 課題
            if (_summary!.issues.isNotEmpty)
              _buildSection(
                icon: '✅',
                title: '課題・TODO',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: _summary!.issues
                      .map((issue) => Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('・', style: TextStyle(color: Colors.white70, fontSize: 15)),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    issue,
                                    style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.4),
                                  ),
                                ),
                              ],
                            ),
                          ))
                      .toList(),
                ),
              ),

            // 感情分析
            _buildSection(
              icon: '💭',
              title: '感情分析',
              child: Text(
                _summary!.sentiment,
                style: const TextStyle(color: Colors.white, fontSize: 15, height: 1.5),
              ),
            ),

            // 生成時刻
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 80),
              child: Text(
                _formatGeneratedAt(_summary!.generatedAtMs),
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({required String icon, required String title, required Widget child}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F25),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(height: 40),
            const Text('📊', style: TextStyle(fontSize: 64)),
            const SizedBox(height: 16),
            Text(
              'まだ要約がありません',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 18, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 8),
            Text(
              '会話が蓄積されると自動的に要約が生成されます',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 14),
            ),
            const SizedBox(height: 24),
            GestureDetector(
              onTap: _isGenerating ? null : _generateNow,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF6C63FF),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: _isGenerating
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('今すぐ生成', style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatGeneratedAt(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '最終更新: ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
