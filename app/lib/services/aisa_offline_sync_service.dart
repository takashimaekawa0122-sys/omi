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
  bool _isSyncing = false;

  /// 外部から同期中かどうかを確認するためのプロパティ（二重実行防止用）
  bool get isSyncing => _isSyncing;

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
    if (_isSyncing) return; // 二重実行防止
    _isCancelled = false;
    _isSyncing = true;

    // APIキー未設定の早期検出
    const groqApiKey = String.fromEnvironment('GROQ_API_KEY');
    if (groqApiKey.isEmpty) {
      debugPrint('[AISA Offline] GROQ_API_KEY未設定のためオフライン同期をスキップ');
      AisaDebugLogger.instance.error('❌ [Offline] GROQ_API_KEY未設定 - オフライン同期不可');
      _isSyncing = false;
      return;
    }

    final diskWals = pendingWals
        .where((w) => w.storage == WalStorage.disk && w.filePath != null)
        .toList();

    if (diskWals.isEmpty) {
      _isSyncing = false;
      return;
    }

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

    // 【バッチ処理】複数チャンクのWAVを結合して1回のAPI呼び出しで処理
    // 旧: 60チャンク × 5秒待機 = 5分以上
    // 新: 6バッチ × 5秒待機 = 30秒程度（10倍高速化）
    const batchSize = 10; // 最大10チャンク（約10分）を1つのWAVに結合

    // セッション分割（内部でtimerStart昇順ソート → 時系列順が保証される）
    final sessions = _groupWalsBySession(diskWals);
    int savedSessions = 0;
    int totalApiCalls = 0;
    int skipCount = 0;

    for (final sessionWals in sessions) {
      if (_isCancelled) break;

      final sessionTranscripts = <String>[];

      // セッション内チャンクをバッチに分割
      for (int batchStart = 0; batchStart < sessionWals.length; batchStart += batchSize) {
        if (_isCancelled) break;

        final batchEnd = (batchStart + batchSize).clamp(0, sessionWals.length);
        final batch = sessionWals.sublist(batchStart, batchEnd);

        // バッチ内の全チャンクをWAVに変換してVADチェック
        final validWavBytes = <List<int>>[];
        final tempFiles = <File>[];

        for (final wal in batch) {
          try {
            final fullPath = await Wal.getFilePath(wal.filePath);
            if (fullPath == null) continue;
            final file = File(fullPath);
            if (!await file.exists()) continue;

            final frames = await _readFrames(file);
            if (frames.isEmpty) continue;

            final wavUtil = WavBytesUtil(
              codec: wal.codec,
              framesPerSecond: wal.codec.getFramesPerSecond(),
            );
            final wavFile = await wavUtil.createWavByCodec(
              frames,
              filename: 'aisa_offline_${wal.id}.wav',
            );
            tempFiles.add(wavFile);

            final wavBytes = await wavFile.readAsBytes();
            final rms = _calcRms(wavBytes);
            if (rms <= 200) {
              skipCount++;
              continue; // 環境音スキップ
            }

            // WAVデータ部分のみ抽出（ヘッダー44バイトを除く）
            if (wavBytes.length > 44) {
              validWavBytes.add(wavBytes.sublist(44));
            }
          } catch (e) {
            debugPrint('[AISA Offline] WALデコード失敗: $e');
          }
        }

        // 一時ファイルを削除
        for (final f in tempFiles) {
          try { await f.delete(); } catch (_) {}
        }

        if (validWavBytes.isEmpty) continue;

        // 有効なWAVデータを1つのWAVファイルに結合
        final combinedWav = _combineWavData(validWavBytes);
        if (combinedWav == null) continue;

        // 結合ファイルサイズチェック（25MB制限）
        if (combinedWav.length > 24 * 1024 * 1024) {
          debugPrint('[AISA Offline] 結合WAVが大きすぎてスキップ (${(combinedWav.length / 1024 / 1024).toStringAsFixed(1)}MB)');
          continue;
        }

        // 結合WAVをGroq Whisperで文字起こし
        final combinedFile = await _writeTempWav(combinedWav, 'aisa_batch_${batch.first.id}.wav');

        const maxRetries = 2;
        String? transcript;
        for (int attempt = 0; attempt <= maxRetries; attempt++) {
          try {
            transcript = await AisaTranscriptionService.instance.transcribeOnly(
              combinedFile,
              previousContext: sessionTranscripts.isNotEmpty ? sessionTranscripts.last : null,
            );
            break;
          } catch (e) {
            final isRateLimit = e.toString().contains('429');
            final waitSecs = isRateLimit ? 60 : 10 * (attempt + 1);
            if (attempt < maxRetries) {
              await Future.delayed(Duration(seconds: waitSecs));
            }
          }
        }

        try { await combinedFile.delete(); } catch (_) {}
        totalApiCalls++;

        if (transcript != null && transcript.trim().isNotEmpty) {
          sessionTranscripts.add(transcript.trim());
        }

        // 次のバッチまで5秒待機（レート制限回避）
        if (batchStart + batchSize < sessionWals.length && !_isCancelled) {
          await Future.delayed(const Duration(seconds: 5));
        }
      }

      // セッションの全バッチ結果を結合して保存
      if (sessionTranscripts.isEmpty) continue;

      final combined = sessionTranscripts.join(' ');
      try {
        if (!_transcriptController.isClosed) {
          _transcriptController.add(combined);
        }
      } catch (_) {}
      await AisaFirestoreService.instance.saveTranscript(combined);
      savedSessions++;
      debugPrint('[AISA Offline] セッション保存 (${combined.length}文字)');
    }

    debugPrint('[AISA Offline] ${diskWals.length}チャンク → $savedSessions件保存 '
        '(API呼出=$totalApiCalls, スキップ=$skipCount)');
    AisaDebugLogger.instance.info(
        '[Offline] 完了: $savedSessions件保存 (API=$totalApiCalls スキップ=$skipCount)');
    _isSyncing = false;
  }

  /// 複数チャンクのPCMデータを1つのWAVファイルに結合
  Uint8List? _combineWavData(List<List<int>> pcmDataList) {
    if (pcmDataList.isEmpty) return null;

    int totalDataSize = 0;
    for (final data in pcmDataList) {
      totalDataSize += data.length;
    }

    // WAVヘッダー（44バイト）+ PCMデータ
    const sampleRate = 16000;
    const channels = 1;
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;

    final buffer = ByteData(44 + totalDataSize);

    // RIFF header
    buffer.setUint8(0, 0x52); // R
    buffer.setUint8(1, 0x49); // I
    buffer.setUint8(2, 0x46); // F
    buffer.setUint8(3, 0x46); // F
    buffer.setUint32(4, 36 + totalDataSize, Endian.little);
    buffer.setUint8(8, 0x57);  // W
    buffer.setUint8(9, 0x41);  // A
    buffer.setUint8(10, 0x56); // V
    buffer.setUint8(11, 0x45); // E

    // fmt chunk
    buffer.setUint8(12, 0x66); // f
    buffer.setUint8(13, 0x6D); // m
    buffer.setUint8(14, 0x74); // t
    buffer.setUint8(15, 0x20); // (space)
    buffer.setUint32(16, 16, Endian.little); // chunk size
    buffer.setUint16(20, 1, Endian.little);  // PCM format
    buffer.setUint16(22, channels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);

    // data chunk
    buffer.setUint8(36, 0x64); // d
    buffer.setUint8(37, 0x61); // a
    buffer.setUint8(38, 0x74); // t
    buffer.setUint8(39, 0x61); // a
    buffer.setUint32(40, totalDataSize, Endian.little);

    // PCMデータを書き込み
    int offset = 44;
    for (final data in pcmDataList) {
      for (int i = 0; i < data.length; i++) {
        buffer.setUint8(offset + i, data[i]);
      }
      offset += data.length;
    }

    return buffer.buffer.asUint8List();
  }

  /// 一時WAVファイルを書き出す
  Future<File> _writeTempWav(Uint8List wavData, String filename) async {
    final dir = await Directory.systemTemp.createTemp('aisa_batch');
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(wavData);
    return file;
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
