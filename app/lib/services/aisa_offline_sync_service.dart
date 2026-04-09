// app/lib/services/aisa_offline_sync_service.dart
//
// A.I.S.A. Phase 2 - オフライン同期サービス
// アプリを閉じていた間にペンダントが録音したWAL(.bin)ファイルを
// Groq Whisperで文字起こしして会話リストに追加する

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:omi/services/aisa_firestore_service.dart';
import 'package:omi/services/aisa_transcription_service.dart';
import 'package:omi/services/wals/local_wal_sync.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/audio/wav_bytes.dart';
import 'package:omi/utils/aisa_debug_logger.dart';

class AisaOfflineSyncService {
  AisaOfflineSyncService._();
  static final AisaOfflineSyncService instance = AisaOfflineSyncService._();

  /// 文字起こし完了時にテキストを流すStream（CaptureProviderが購読）
  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();
  Stream<String> get transcriptStream => _transcriptController.stream;

  bool _isCancelled = false;

  /// 進行中の同期を中断する（手動同期開始時にSyncProviderから呼ばれる）
  void cancelSync() {
    _isCancelled = true;
    debugPrint('[AISA Offline] キャンセルリクエスト受信');
  }

  /// 未同期のWAL（ディスク上の.binファイル）をGroq Whisperで処理する
  /// SyncProviderの_triggerAisaOfflineSyncIfNeeded()から呼ばれる
  Future<void> syncPendingWals(
    List<Wal> pendingWals,
    LocalWalSyncImpl phoneSync,
  ) async {
    _isCancelled = false; // 新規実行開始時にリセット

    // APIキー未設定の早期検出
    const groqApiKey = String.fromEnvironment('GROQ_API_KEY');
    if (groqApiKey.isEmpty) {
      debugPrint('[AISA Offline] GROQ_API_KEY未設定のためオフライン同期をスキップ');
      AisaDebugLogger.instance.error('❌ [Offline] GROQ_API_KEY未設定 - オフライン同期不可');
      return;
    }

    final diskWals = pendingWals
        .where((w) => w.storage == WalStorage.disk && w.filePath != null)
        .toList();

    if (diskWals.isEmpty) return;

    debugPrint('[AISA Offline] ${diskWals.length}件のオフライン録音を処理開始');
    AisaDebugLogger.instance.info('[Offline] ${diskWals.length}件のオフライン録音を処理開始');

    // Omiクラウドへの音声流出を防ぐため、Groq処理の前に全WALをsynced済みとしてマークする
    // 【パフォーマンス最適化】全WALのstatusを直接更新してから最後に1回だけ保存・通知する
    // （phone.syncAll()はstatus==missのWALのみ対象なので、これで確実にOmi送信を防ぐ）
    for (final wal in diskWals) {
      wal.status = WalStatus.synced; // 直接更新（同一オブジェクト参照）
    }
    try {
      // 最後の1件でまとめて保存＆通知（1回のディスク書き込みとUI更新で済む）
      await phoneSync.markWalSyncedAndPersist(diskWals.last);
    } catch (e) {
      debugPrint('[AISA Offline] WAL一括マーク失敗（続行）: $e');
    }

    // Groq Whisperで文字起こし（synced済みマーク後なのでOmiには送られない）
    // Groqレート制限: free tier 20 req/min → 最低5秒間隔で送信
    //
    // 【設計方針】セッション単位で処理することで2つのバグを防ぐ：
    //   Bug1: diskWalsは時系列順とは限らないため、先にセッション分割（内部でtimerStart昇順ソート済み）
    //   Bug2: previousTranscriptがセッション境界をまたがないようセッション毎にリセット
    int successCount = 0;
    int skipCount = 0;
    int failCount = 0;
    final Map<String, String> walTranscripts = {}; // walId → transcript

    // セッション分割（内部でtimerStart昇順ソート → 時系列順が保証される）
    final sessions = _groupWalsBySession(diskWals);

    int processedCount = 0; // 全チャンクを通じたカウンター（レート制限タイミング用）

    for (final sessionWals in sessions) {
      // セッションをまたぐ文脈の汚染を防ぐため、セッション毎にリセット
      String? previousTranscript;

      for (final wal in sessionWals) {
        // キャンセルチェック（手動同期開始時などに中断）
        if (_isCancelled) {
          debugPrint('[AISA Offline] キャンセルにより中断（処理済み: $processedCount/${diskWals.length}）');
          break;
        }

        try {
          final transcript = await _transcribeWalOnly(wal, previousContext: previousTranscript);
          if (transcript == null) {
            skipCount++; // 無音またはデコード失敗
            previousTranscript = null; // 無音は文脈をリセット（話題の区切りの可能性）
          } else if (transcript.trim().isNotEmpty) {
            walTranscripts[wal.id] = transcript.trim();
            successCount++;
            previousTranscript = transcript.trim(); // 次のチャンクへ文脈を引き継ぐ
          }
        } catch (e) {
          debugPrint('[AISA Offline] WAL文字起こし失敗 ${wal.id}: $e');
          AisaDebugLogger.instance.error('❌ [Offline] WAL失敗 ${wal.id}: $e');
          failCount++;
          // 失敗時はpreviousTranscriptをそのまま維持（直前の成功チャンクの文脈を保持）
        }

        processedCount++;
        // 最後のチャンク以外は5秒待機してレート制限を回避
        if (processedCount < diskWals.length && !_isCancelled) {
          await Future.delayed(const Duration(seconds: 5));
        }
      }

      if (_isCancelled) break;
    }

    // 同一録音セッションのチャンクを結合して1件の会話として保存
    // キャンセル済みでも収集済みのテキストは保存する（途中までの内容を失わないため）
    int savedSessions = 0;
    for (final sessionWals in sessions) {
      final transcripts = sessionWals
          .map((w) => walTranscripts[w.id])
          .where((t) => t != null && t!.isNotEmpty)
          .cast<String>()
          .toList();

      if (transcripts.isEmpty) continue;

      final combined = transcripts.join(' ');
      // dispose()後にstreamへの追加を試みると例外が発生するためガードする
      if (!_transcriptController.isClosed) {
        _transcriptController.add(combined);
      }
      await AisaFirestoreService.instance.saveTranscript(combined);
      savedSessions++;
      debugPrint('[AISA Offline] ${sessionWals.length}チャンクを1件の会話として保存 '
          '(${combined.length}文字, ${sessionWals.first.timerStart})'
          '${_isCancelled ? " [キャンセル後の残存データ]" : ""}');
    }

    debugPrint('[AISA Offline] ${diskWals.length}チャンク処理完了 → $savedSessions件の会話として保存 '
        '(成功: $successCount, スキップ: $skipCount, 失敗: $failCount)');
    AisaDebugLogger.instance.info(
        '[Offline] 完了: $savedSessions件保存 (成功=$successCount スキップ=$skipCount 失敗=$failCount)');
  }

  /// WAL 1件を文字起こしのみ（Firestoreには保存しない）
  /// [previousContext]: 直前チャンクの末尾テキスト（Whisperプロンプトへの文脈提供用）
  /// 複数チャンクを結合して1件として保存するため、保存は呼び出し元に任せる
  /// 失敗時は最大2回リトライする（タイムアウト・ネットワークエラー対策）
  Future<String?> _transcribeWalOnly(Wal wal, {String? previousContext}) async {
    final fullPath = await Wal.getFilePath(wal.filePath);
    if (fullPath == null) return null;

    final file = File(fullPath);
    if (!await file.exists()) return null;

    // .binファイルからOpusフレームを読み出す
    final frames = await _readFrames(file);
    if (frames.isEmpty) {
      debugPrint('[AISA] チャンク ${wal.id}: フレームなし → スキップ');
      return null;
    }

    // OpusフレームをWAVに変換
    // wal.idでファイル名を一意にする（timerStartは同一になりうるため）
    final wavUtil = WavBytesUtil(
      codec: wal.codec,
      framesPerSecond: wal.codec.getFramesPerSecond(),
    );
    final wavFile = await wavUtil.createWavByCodec(
      frames,
      filename: 'aisa_offline_${wal.id}.wav',
    );

    // VADチェック：完全な無音のみスキップ（閾値を低く設定）
    // SDカード録音はユーザーが意図的に録音したものなので非常に寛容な閾値にする
    // 閾値50: ほぼ無音（ホワイトノイズのみ）のチャンクだけスキップ
    final wavBytes = await wavFile.readAsBytes();
    final rms = _calcRms(wavBytes);
    if (rms <= 50) {
      debugPrint('[AISA] チャンク ${wal.id}: VADスキップ (RMS=$rms ≤ 50)');
      await wavFile.delete();
      return null;
    }

    // ファイルサイズ確認（Groq Whisperは25MB制限）
    final wavSize = wavBytes.length;
    if (wavSize > 24 * 1024 * 1024) {
      debugPrint('[AISA] チャンク ${wal.id}: WAVが大きすぎてスキップ '
          '(${(wavSize / 1024 / 1024).toStringAsFixed(1)}MB)');
      await wavFile.delete();
      return null;
    }

    // Groq Whisper 文字起こし（最大2回リトライ）
    // タイムアウト・ネットワークエラー・レートリミットに対応
    const maxRetries = 2;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        final transcript = await AisaTranscriptionService.instance.transcribeOnly(wavFile, previousContext: previousContext);
        // 成功: WAVを削除して返す
        try { await wavFile.delete(); } catch (_) {}
        return transcript;
      } catch (e) {
        final isRateLimit = e.toString().contains('429');
        final waitSecs = isRateLimit ? 60 : 10 * (attempt + 1); // レートリミットは60秒待機

        if (attempt < maxRetries) {
          debugPrint('[AISA] チャンク ${wal.id}: 文字起こし失敗 '
              '(試行 ${attempt + 1}/$maxRetries, ${waitSecs}s後リトライ): $e');
          await Future.delayed(Duration(seconds: waitSecs));
        } else {
          debugPrint('[AISA] チャンク ${wal.id}: 全試行失敗 → スキップ: $e');
        }
      }
    }

    // 全リトライ失敗: WAVを削除してnullを返す
    try { await wavFile.delete(); } catch (_) {}
    return null;
  }

  /// WAVバイト列のRMS値を計算（VADチェック用）
  double _calcRms(List<int> wavBytes) {
    if (wavBytes.length <= 44) return 0;
    double sumSquares = 0;
    int count = 0;
    for (int i = 44; i < wavBytes.length - 1; i += 2) {
      int sample = (wavBytes[i + 1] << 8) | wavBytes[i];
      if (sample > 32767) sample -= 65536;
      sumSquares += sample * sample;
      count++;
    }
    if (count == 0) return 0;
    return sqrt(sumSquares / count);
  }

  /// 同一録音セッションのWALをグループ化する
  /// 連続する60秒チャンクを同一セッションと判定（65秒以内のギャップ、同一デバイス）
  /// 例：20分録音 → 20チャンク → 1グループ → 1件の会話
  List<List<Wal>> _groupWalsBySession(List<Wal> wals) {
    if (wals.isEmpty) return [];

    // timerStart順にソート
    final sorted = [...wals]..sort((a, b) => a.timerStart.compareTo(b.timerStart));

    final groups = <List<Wal>>[];
    var currentGroup = [sorted[0]];

    for (int i = 1; i < sorted.length; i++) {
      final prev = sorted[i - 1];
      final curr = sorted[i];

      // 前チャンクの終了時刻と現チャンクの開始時刻の差が65秒以内 かつ 同一デバイス
      // → 同じ録音セッションの連続チャンクと判定
      final prevEnd = prev.timerStart + prev.seconds;
      final gap = curr.timerStart - prevEnd;

      if (gap <= 65 && curr.device == prev.device) {
        currentGroup.add(curr);
      } else {
        groups.add(currentGroup);
        currentGroup = [curr];
      }
    }
    groups.add(currentGroup);

    debugPrint('[AISA Offline] ${wals.length}チャンク → ${groups.length}セッションにグループ化');
    return groups;
  }


  /// WAL .binファイルのフォーマット: [uint32_LE(フレームサイズ)][フレームバイト列] の繰り返し
  Future<List<List<int>>> _readFrames(File file) async {
    final bytes = await file.readAsBytes();
    final frames = <List<int>>[];
    int offset = 0;

    while (offset + 4 <= bytes.length) {
      final frameLen =
          ByteData.sublistView(bytes, offset, offset + 4).getUint32(0, Endian.little);
      offset += 4;

      if (frameLen == 0 || offset + frameLen > bytes.length) break;

      frames.add(bytes.sublist(offset, offset + frameLen));
      offset += frameLen;
    }

    return frames;
  }

  void dispose() {
    _transcriptController.close();
  }
}
