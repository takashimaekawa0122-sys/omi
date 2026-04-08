// app/lib/services/aisa_offline_sync_service.dart
//
// A.I.S.A. Phase 2 - オフライン同期サービス
// アプリを閉じていた間にペンダントが録音したWAL(.bin)ファイルを
// Groq Whisperで文字起こしして会話リストに追加する

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:omi/services/aisa_transcription_service.dart';
import 'package:omi/services/wals/local_wal_sync.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/utils/audio/wav_bytes.dart';

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
      return;
    }

    final diskWals = pendingWals
        .where((w) => w.storage == WalStorage.disk && w.filePath != null)
        .toList();

    if (diskWals.isEmpty) return;

    debugPrint('[AISA Offline] ${diskWals.length}件のオフライン録音を処理開始');

    // Omiクラウドへの音声流出を防ぐため、Groq処理の前に全WALをsynced済みとしてマークする
    // （phone.syncAll()はstatus==missのWALのみ対象にするため、これで送信を確実に防ぐ）
    for (final wal in diskWals) {
      try {
        await phoneSync.markWalSyncedAndPersist(wal);
      } catch (e) {
        debugPrint('[AISA Offline] WAL事前マーク失敗（続行） ${wal.id}: $e');
      }
    }

    // Groq Whisperで文字起こし（synced済みマーク後なのでOmiには送られない）
    // Groqレート制限: free tier 20 req/min → 最低3秒間隔で送信
    // 大量WAL処理時に429エラーで全滅するのを防ぐ
    int successCount = 0;
    int failCount = 0;
    for (int i = 0; i < diskWals.length; i++) {
      // キャンセルチェック（手動同期開始時などに中断）
      if (_isCancelled) {
        debugPrint('[AISA Offline] キャンセルにより中断（処理済み: $i/${diskWals.length}）');
        break;
      }

      final wal = diskWals[i];
      try {
        final transcript = await _processWal(wal);
        if (transcript != null && transcript.trim().isNotEmpty) {
          _transcriptController.add(transcript);
          successCount++;
        }
      } catch (e) {
        debugPrint('[AISA Offline] WAL文字起こし失敗 ${wal.id}: $e');
        failCount++;
      }

      // 最後の1件以外は3秒待機してレート制限を回避
      if (i < diskWals.length - 1 && !_isCancelled) {
        await Future.delayed(const Duration(seconds: 3));
      }
    }

    debugPrint('[AISA Offline] ${diskWals.length}件処理完了 (成功: $successCount, 失敗: $failCount)');
  }

  /// WAL 1件を処理：.binファイル読み込み → フレームデコード → WAV変換 → Groq Whisper
  Future<String?> _processWal(Wal wal) async {
    final fullPath = await Wal.getFilePath(wal.filePath);
    if (fullPath == null) return null;

    final file = File(fullPath);
    if (!await file.exists()) return null;

    // .binファイルからOpusフレームを読み出す
    final frames = await _readFrames(file);
    if (frames.isEmpty) return null;

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

    // ファイルサイズ確認（Groq Whisperは25MB制限）
    final wavSize = await wavFile.length();
    if (wavSize > 24 * 1024 * 1024) {
      debugPrint('[AISA Offline] WAVが大きすぎてスキップ: ${(wavSize / 1024 / 1024).toStringAsFixed(1)}MB (${wal.id})');
      await wavFile.delete();
      return null;
    }

    // VAD + Groq Whisper 文字起こし + Firestore保存
    return await AisaTranscriptionService.instance.processAndSave(wavFile);
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
