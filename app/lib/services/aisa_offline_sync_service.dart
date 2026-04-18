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
import 'package:shared_preferences/shared_preferences.dart';

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

  /// ライブ優先のウォームアップ時間（アプリ起動直後）。
  /// アプリ起動〜BLE接続直後はライブ会話を優先させるため、
  /// この時間が経つまでオフライン同期のAPI呼び出しを保留する。
  /// Omiペンダント側の既存録音が大量にある場合にGroqレート枠を使い切り、
  /// ライブ文字起こしが最初の数分間まったく動かなくなる問題への対策。
  static const Duration _liveWarmupDuration = Duration(seconds: 120);

  /// 手動同期（SDカード転送）完了後のライブ優先期間。
  /// SDカード同期が完了すると大量のpending WALが一気に現れるため、
  /// この時間が経つまでオフライン側はGroq呼び出しを保留し、
  /// 同期直後の録音をライブ経路で確実に文字起こしさせる。
  /// ユーザー報告: 同期完了後の数分間、文字起こしが動かない問題に対応。
  static const Duration _postSyncWarmupDuration = Duration(seconds: 180);

  /// プロセス起動時刻（サービス初期化時に固定）
  final DateTime _serviceStartedAt = DateTime.now();

  /// 直近の手動同期（SDカード転送）完了時刻。
  /// SyncProvider から [notifyOfSyncCompletion] で設定される。
  DateTime? _lastSyncCompletedAt;

  /// 外部から同期中かどうかを確認するためのプロパティ（二重実行防止用）
  bool get isSyncing => _isSyncing;

  /// ウォームアップの起点時刻（起動時刻 または 直近同期完了時刻のうち新しい方）
  DateTime get _warmupStart {
    final sync = _lastSyncCompletedAt;
    if (sync != null && sync.isAfter(_serviceStartedAt)) return sync;
    return _serviceStartedAt;
  }

  /// ウォームアップの必要時間。
  /// - 同期後なら _postSyncWarmupDuration（180秒）
  /// - それ以外（起動直後）なら _liveWarmupDuration（120秒）
  Duration get _effectiveWarmupDuration {
    final sync = _lastSyncCompletedAt;
    if (sync != null && sync.isAfter(_serviceStartedAt)) {
      return _postSyncWarmupDuration;
    }
    return _liveWarmupDuration;
  }

  /// ウォームアップ期間が終了しているか（テスト・デバッグ用）
  bool get isWarmupComplete =>
      DateTime.now().difference(_warmupStart) >= _effectiveWarmupDuration;

  /// 手動同期（SDカード転送）が完了したことをSyncProviderから通知する。
  /// これによりオフライン同期側のウォームアップ基準時刻が更新され、
  /// 同期完了後の数分間ライブ文字起こしを優先させる。
  /// もしオフライン同期がすでに走っていた場合はキャンセルして、
  /// 新しいウォームアップ起点で再スタートさせる。
  void notifyOfSyncCompletion() {
    _lastSyncCompletedAt = DateTime.now();
    AisaDebugLogger.instance.info(
      '[Offline] 手動同期完了を記録 → 以降${_postSyncWarmupDuration.inSeconds}秒はライブ優先',
      context: {
        'at': _lastSyncCompletedAt!.toIso8601String(),
        'warmupSec': _postSyncWarmupDuration.inSeconds,
        'wasRunning': _isSyncing,
      },
    );
    // 走っている最中なら即キャンセル（新ウォームアップ起点で再開させる）
    if (_isSyncing) {
      _isCancelled = true;
      debugPrint('[AISA Offline] 同期完了通知 → 進行中オフライン同期をキャンセル');
    }
  }

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

    // 【ライブ優先ウォームアップ】
    // 起点: アプリ起動時刻 OR 直近の手動同期完了時刻のうち新しい方
    // 期間: 起動直後=120秒 / 同期完了後=180秒
    // Omiペンダントの既存録音が大量に存在する場合、即座にGroqを叩くと
    // ライブ側が429で窒息するため、この期間はライブ経路を優先させる。
    //
    // 【根本対策 2026-04-19】軽量ケースはウォームアップをスキップ
    //   旧仕様ではアプリ再起動ごとに _serviceStartedAt がリセットされ、120秒の
    //   ウォームアップが毎回走り直していた。短時間テスト (< 2分) では永久に
    //   オフライン同期が始まらないバグになっていた。
    //   少量 (≤ 5件) かつ 手動SDカード同期直後でない場合はスキップし、
    //   大量バックログ (6件以上) or SDカード同期直後のみ従来通り待機する。
    const warmupSkipThreshold = 5;
    final isPostManualSync =
        _lastSyncCompletedAt != null && _lastSyncCompletedAt!.isAfter(_serviceStartedAt);
    final needsWarmup = diskWals.length > warmupSkipThreshold || isPostManualSync;

    if (needsWarmup) {
      final warmupStart = _warmupStart;
      final warmupDuration = _effectiveWarmupDuration;
      final elapsed = DateTime.now().difference(warmupStart);
      if (elapsed < warmupDuration) {
        final remaining = warmupDuration - elapsed;
        final warmupKind = isPostManualSync ? '同期完了後' : '起動直後(大量)';
        AisaDebugLogger.instance.info(
          '[Offline] ウォームアップ待機($warmupKind): 残り${remaining.inSeconds}秒（ライブ優先）',
          context: {
            'kind': warmupKind,
            'remainingSec': remaining.inSeconds,
            'warmupStart': warmupStart.toIso8601String(),
            'walCount': diskWals.length,
          },
        );
        debugPrint('[AISA Offline] ウォームアップ待機($warmupKind): 残り${remaining.inSeconds}秒');
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
    } else {
      AisaDebugLogger.instance.info(
        '[Offline] 軽量処理 (${diskWals.length}件 ≤ $warmupSkipThreshold) → ウォームアップスキップ',
        context: {
          'walCount': diskWals.length,
          'threshold': warmupSkipThreshold,
        },
      );
      debugPrint('[AISA Offline] 軽量処理 (${diskWals.length}件) → ウォームアップスキップ');
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

    // 【バッチ処理】チャンクを結合せず1つずつ処理
    // 【根本対策 2026-04-18】旧設定 batchSize=20 では複数WAV結合で最大~20MBに
    //   達し、iOS の Whisper HTTP送信中にメモリ圧迫で OOM kill が頻発していた。
    //   また長尺バッチは Whisper のノイズ判定で全セグメント破棄されやすく、
    //   WALがまるごと「ノイズ扱い → 削除」されてデータ消失の原因にもなっていた。
    //   1チャンクずつ処理することでメモリ使用量を ~1MB に抑え、かつ
    //   個別チャンクごとに Whisper が会話を拾いやすくする。
    //   Groq free tier の 20 req/min 制限はバッチ間の 8秒 delay で回避する。
    const batchSize = 1; // 1チャンク（約60秒）ずつ個別にGroqへ送信

    // セッション分割（内部でtimerStart昇順ソート → 時系列順が保証される）
    final sessions = _groupWalsBySession(diskWals);
    int savedSessions = 0;
    int totalApiCalls = 0;
    int skipCount = 0;
    // 【根本対策 2026-04-18】書き起こしに成功したWAL IDを追跡。
    //   失敗したWALは「ノイズ判定」であってもファイル削除せず、後でリトライできるよう corrupted に戻す。
    final savedWalIds = <String>{};

    for (final sessionWals in sessions) {
      if (_isCancelled) break;

      final sessionTranscripts = <String>[];
      // 【根本対策 2026-04-18】このセッションで採用されたトランスクリプトを生んだWAL ID群。
      //   セッションが最終的に保存に成功した場合のみ、これらのWAL IDを savedWalIds に反映する。
      final sessionContributingWalIds = <String>[];

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
            // 【根本対策 2026-04-18】このバッチの WAL IDを記録（セッション保存時に削除対象）
            for (final w in batch) {
              sessionContributingWalIds.add(w.id);
            }
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
      // 【根本対策 2026-04-18】セッション保存成功 → このセッションの寄与WALを削除対象にマーク
      savedWalIds.addAll(sessionContributingWalIds);
      debugPrint('[AISA Offline] セッション保存 (${combined.length}文字)');
    }

    // 【根本対策 2026-04-18】同期完了後のクリーンアップ
    //   旧実装: diskWals すべてを無条件削除 → 「ノイズ判定」WALも永久消失していた。
    //   新実装:
    //     - 保存成功したWAL → ファイル削除 & リストから除去（従来通り）
    //     - 失敗したWAL (retry < 3) → ファイル残存 & status=corrupted（次回起動時に miss へ復帰）
    //     - 失敗したWAL (retry ≥ 3) → ファイル削除（永久に書き起こしできない音声の蓄積を防ぐ）
    final prefs = await SharedPreferences.getInstance();
    const retryKeyPrefix = 'aisa_offline_retry_';
    const maxRetries = 3;

    int deletedFiles = 0;
    int retainedFiles = 0;
    int discardedAfterMaxRetries = 0;

    for (final wal in diskWals) {
      bool shouldDeleteFile;

      if (savedWalIds.contains(wal.id)) {
        // 保存成功 → 削除
        shouldDeleteFile = true;
        await prefs.remove('$retryKeyPrefix${wal.id}');
      } else {
        // 保存失敗（ノイズ判定 or API失敗 or セッション0件）
        final retryKey = '$retryKeyPrefix${wal.id}';
        final prevRetries = prefs.getInt(retryKey) ?? 0;
        final newRetries = prevRetries + 1;

        if (newRetries >= maxRetries) {
          // リトライ上限到達 → 諦めて削除
          shouldDeleteFile = true;
          await prefs.remove(retryKey);
          discardedAfterMaxRetries++;
          AisaDebugLogger.instance.warning(
              '[Offline] リトライ上限(${newRetries}回)のため破棄: ${wal.id}');
        } else {
          // リトライ可能 → ファイル保持 & corruptedへ遷移（次回起動時 miss に戻して再試行）
          shouldDeleteFile = false;
          await prefs.setInt(retryKey, newRetries);
          wal.status = WalStatus.corrupted;
          retainedFiles++;
        }
      }

      if (shouldDeleteFile) {
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
    }

    // WALリストから status==synced のものだけ除去（corrupted は残る）。
    // deleteAllSyncedWals は内部で _saveWalsToFile を呼ぶため、
    // corrupted への status 変更もここで永続化される。
    try {
      await phoneSync.deleteAllSyncedWals();
    } catch (e) {
      debugPrint('[AISA Offline] WALリストクリーンアップ失敗: $e');
    }

    debugPrint('[AISA Offline] ${diskWals.length}チャンク → $savedSessions件保存 '
        '(API呼出=$totalApiCalls, スキップ=$skipCount, 削除=$deletedFiles, 保持=$retainedFiles, 諦め削除=$discardedAfterMaxRetries)');
    AisaDebugLogger.instance.info(
        '[Offline] 完了: $savedSessions件保存 (API=$totalApiCalls スキップ=$skipCount 削除=$deletedFiles 保持=$retainedFiles 諦め=$discardedAfterMaxRetries)');
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
