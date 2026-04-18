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
  /// text: 文字起こし結果、recordedAt: 実際の録音時刻（時系列表示に使う）
  final StreamController<({String text, DateTime recordedAt, String? docId})> _transcriptController =
      StreamController<({String text, DateTime recordedAt, String? docId})>.broadcast();
  Stream<({String text, DateTime recordedAt, String? docId})> get transcriptStream => _transcriptController.stream;

  bool _isCancelled = false;
  bool _isSyncing = false;

  /// ライブ優先のウォームアップ時間。
  /// アプリ起動〜BLE接続直後はライブ会話を優先させるため、
  /// この時間が経つまでオフライン同期のAPI呼び出しを保留する。
  /// Omiペンダント側の既存録音が大量にある場合にGroqレート枠を使い切り、
  /// ライブ文字起こしが最初の数分間まったく動かなくなる問題への対策。
  static const Duration _liveWarmupDuration = Duration(seconds: 120);

  /// プロセス起動時刻（サービス初期化時に固定）
  final DateTime _serviceStartedAt = DateTime.now();

  /// 外部から同期中かどうかを確認するためのプロパティ（二重実行防止用）
  bool get isSyncing => _isSyncing;

  /// ウォームアップ期間が終了しているか（テスト・デバッグ用）
  bool get isWarmupComplete =>
      DateTime.now().difference(_serviceStartedAt) >= _liveWarmupDuration;

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

    try {
      await _syncPendingWalsInternal(pendingWals, phoneSync);
    } finally {
      _isSyncing = false; // 例外が発生しても必ずリセット
    }
  }

  Future<void> _syncPendingWalsInternal(
    List<Wal> pendingWals,
    LocalWalSyncImpl phoneSync,
  ) async {
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

    if (diskWals.isEmpty) {
      return;
    }

    debugPrint('[AISA Offline] ${diskWals.length}件のオフライン録音を処理開始');
    AisaDebugLogger.instance.info('[Offline] ${diskWals.length}件のオフライン録音を処理開始');

    // 【ライブ優先ウォームアップ】起動から _liveWarmupDuration 経過するまで待機する。
    // Omiペンダントの既存録音が大量に存在する場合、即座にGroqを叩くと
    // ライブ側が429で窒息するため、最初の約2分はライブを優先させる。
    final elapsed = DateTime.now().difference(_serviceStartedAt);
    if (elapsed < _liveWarmupDuration) {
      final remaining = _liveWarmupDuration - elapsed;
      AisaDebugLogger.instance.info(
          '[Offline] ウォームアップ待機: 残り${remaining.inSeconds}秒（ライブ優先）');
      debugPrint('[AISA Offline] ウォームアップ待機: 残り${remaining.inSeconds}秒');
      // キャンセル可能な待機（1秒ごとにチェック）
      final deadline = DateTime.now().add(remaining);
      while (DateTime.now().isBefore(deadline) && !_isCancelled) {
        await Future.delayed(const Duration(seconds: 1));
      }
      if (_isCancelled) {
        AisaDebugLogger.instance.info('[Offline] ウォームアップ中にキャンセル');
        return;
      }
      AisaDebugLogger.instance.info('[Offline] ウォームアップ完了 → 同期開始');
    }

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
    // Groq free tier: 20 req/min → 8秒間隔で安全マージン確保
    const batchSize = 20; // 最大20チャンク（約20分）を1つのWAVに結合

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
            // 【修正】60秒チャンク全体のRMSは、断続的な会話では自然に低くなる
            //   （無音時間が長い場合、平均RMSは100〜400が普通）。
            // 以前の閾値 500 は会話相手・装着者の遠めの発話まで大量に捨てていた。
            // セグメント単位のVAD（_kSegmentQuietRms=80）・Whisperのno_speech_prob
            // で後段で細かく判定するため、ここでは「ほぼ完全な無音」のみ除外する。
            if (rms <= 120) {
              skipCount++;
              AisaDebugLogger.instance.vad(
                  '[Offline] チャンク除外(rms=$rms): ${wal.filePath}');
              continue;
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

        if (validWavBytes.isEmpty) {
          AisaDebugLogger.instance.info(
              '[Offline] バッチ全滅(有効0/${batch.length}) → スキップ');
          continue;
        }

        // 【修正】旧「5チャンク中1チャンクしか有効 → バッチ全破棄」ヒューリスティクスは
        // 会話の切れ目が多い自然な録音（昼休みに会話→沈黙→再開）で正当な発話を
        // 捨てていたため削除。1チャンク分でも有効な音声があれば Groq に送る。
        // 真に無音なら上段の RMS≤120 チェックで既に除外されている。
        AisaDebugLogger.instance.info(
            '[Offline] バッチ採用(${validWavBytes.length}/${batch.length}チャンク) → Groq送信');

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

        // ライブ優先制御: ライブ会話がAPI呼び出し中/直近ならそちらを優先して待機
        if (AisaTranscriptionService.instance.isLiveActive) {
          AisaDebugLogger.instance.info('[Offline] ライブ会話進行中 → API呼び出しを待機');
          await AisaTranscriptionService.instance.waitForLiveQuiet();
        }
        if (_isCancelled) {
          try { await combinedFile.delete(); } catch (_) {}
          break;
        }

        const maxRetries = 2;
        String? transcript;
        Object? lastError;
        for (int attempt = 0; attempt <= maxRetries; attempt++) {
          try {
            transcript = await AisaTranscriptionService.instance.transcribeOnly(
              combinedFile,
              previousContext: sessionTranscripts.isNotEmpty ? sessionTranscripts.last : null,
            );
            break;
          } catch (e) {
            lastError = e;
            final isRateLimit = e.toString().contains('429');
            final waitSecs = isRateLimit ? 60 : 10 * (attempt + 1);
            AisaDebugLogger.instance.warning(
                '[Offline] Groq送信失敗(${attempt + 1}/${maxRetries + 1}): $e → ${attempt < maxRetries ? "${waitSecs}s後リトライ" : "諦め"}');
            if (attempt < maxRetries) {
              await Future.delayed(Duration(seconds: waitSecs));
            }
          }
        }

        try { await combinedFile.delete(); } catch (_) {}
        totalApiCalls++;

        if (transcript == null) {
          AisaDebugLogger.instance.warning(
              '[Offline] transcribeOnly null返却 (無音orハルシネーション判定) err=$lastError');
          skipCount++;
        } else if (transcript.trim().isEmpty) {
          AisaDebugLogger.instance.info('[Offline] transcript空文字 → スキップ');
          skipCount++;
        } else {
          // ハルシネーションチェック（オフライン同期でもフィルタリング）。
          // combined 長文に対しては substring 判定は自動的にスキップされる
          // （_isHallucination 内の 50文字ゲート）。
          final trimmed = transcript.trim();
          if (!AisaTranscriptionService.isHallucination(trimmed)) {
            AisaDebugLogger.instance.info(
                '[Offline] バッチ成功: ${trimmed.length}文字採用');
            sessionTranscripts.add(trimmed);
          } else {
            AisaDebugLogger.instance.warning(
                '[Offline] ハルシネーション検出(${trimmed.length}文字) → 破棄: "${trimmed.substring(0, trimmed.length.clamp(0, 60))}${trimmed.length > 60 ? "…" : ""}"');
            debugPrint('[AISA Offline] ハルシネーション検出 → 破棄: $trimmed');
            skipCount++;
          }
        }

        // 次のバッチまで5秒待機（レート制限回避）
        if (batchStart + batchSize < sessionWals.length && !_isCancelled) {
          await Future.delayed(const Duration(seconds: 8));
        }
      }

      // セッションの全バッチ結果を結合して保存
      if (sessionTranscripts.isEmpty) {
        AisaDebugLogger.instance.warning(
            '[Offline] セッション破棄: ${sessionWals.length}チャンクから有効な文字起こし0件');
        continue;
      }

      final combined = sessionTranscripts.join(' ');
      // セッション先頭WALのtimerStartを録音時刻として使用（時系列順に並べるため）
      final firstTimerStart = sessionWals.first.timerStart;
      final recordedAt = firstTimerStart > 1000000000 // 妥当なepochか判定（2001年以降）
          ? DateTime.fromMillisecondsSinceEpoch(firstTimerStart * 1000)
          : DateTime.now();
      String? docId;
      try {
        // オフライン同期はClaude校正を行わないため、combined全体が本文（タイトル/絵文字なし）
        docId = await AisaFirestoreService.instance.saveTranscript(combined, body: combined);
      } catch (e) {
        AisaDebugLogger.instance.warning(
            '[Offline] Firestore保存失敗(UIには流す): $e');
      }
      try {
        if (!_transcriptController.isClosed) {
          _transcriptController.add((text: combined, recordedAt: recordedAt, docId: docId));
          AisaDebugLogger.instance.info(
              '[Offline] ストリーム送出: ${combined.length}文字 docId=$docId');
        } else {
          AisaDebugLogger.instance.warning(
              '[Offline] ⚠ ストリームClosed - UI更新不可');
        }
      } catch (e) {
        AisaDebugLogger.instance.warning('[Offline] ストリーム送出失敗: $e');
      }
      savedSessions++;
      debugPrint('[AISA Offline] セッション保存 (${combined.length}文字)');
    }

    // 同期完了後、処理済み.binファイルを自動削除（ストレージ節約＆再起動時の高速化）
    int deletedFiles = 0;
    for (final wal in diskWals) {
      try {
        final fullPath = await Wal.getFilePath(wal.filePath);
        if (fullPath != null) {
          final file = File(fullPath);
          if (await file.exists()) {
            await file.delete();
            deletedFiles++;
          }
        }
      } catch (e) {
        debugPrint('[AISA Offline] .bin削除失敗: $e');
      }
    }
    // WALリストからも除去して永続化
    try {
      await phoneSync.deleteAllSyncedWals();
    } catch (e) {
      debugPrint('[AISA Offline] WALリストクリーンアップ失敗: $e');
    }

    debugPrint('[AISA Offline] ${diskWals.length}チャンク → $savedSessions件保存 '
        '(API呼出=$totalApiCalls, スキップ=$skipCount, 削除=$deletedFiles)');
    AisaDebugLogger.instance.info(
        '[Offline] 完了: $savedSessions件保存 (API=$totalApiCalls スキップ=$skipCount 削除=$deletedFiles)');
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

      // 会話セッションの区切り: 5分以上のギャップ、または同時刻に前後する異常値、または別デバイス
      // ペンダントは装着中ずっと60秒ごとに録音するため緩い閾値だと数日分が結合されてしまう
      if (gap >= 0 && gap <= 300 && curr.device == prev.device) {
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
