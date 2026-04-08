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

  /// 未同期のWAL（ディスク上の.binファイル）をGroq Whisperで処理する
  /// SyncProviderの_autoUploadPendingPhoneFiles()から呼ばれる
  Future<void> syncPendingWals(
    List<Wal> pendingWals,
    LocalWalSyncImpl phoneSync,
  ) async {
    final diskWals = pendingWals
        .where((w) => w.storage == WalStorage.disk && w.filePath != null)
        .toList();

    if (diskWals.isEmpty) return;

    debugPrint('[AISA Offline] ${diskWals.length}件のオフライン録音を処理開始');

    for (final wal in diskWals) {
      try {
        final transcript = await _processWal(wal);
        if (transcript != null && transcript.trim().isNotEmpty) {
          _transcriptController.add(transcript);
        }
      } catch (e) {
        debugPrint('[AISA Offline] WAL処理失敗 ${wal.id}: $e');
      } finally {
        // 成否にかかわらずAISA処理済みとしてマーク（Omiクラウドへの再送を防ぐ）
        try {
          await phoneSync.markWalSyncedAndPersist(wal);
        } catch (e) {
          debugPrint('[AISA Offline] WALマーク失敗 ${wal.id}: $e');
        }
      }
    }

    debugPrint('[AISA Offline] オフライン同期完了');
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
    final wavUtil = WavBytesUtil(
      codec: wal.codec,
      framesPerSecond: wal.codec.getFramesPerSecond(),
    );
    final wavFile = await wavUtil.createWavByCodec(
      frames,
      filename: 'aisa_offline_${wal.timerStart}.wav',
    );

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
