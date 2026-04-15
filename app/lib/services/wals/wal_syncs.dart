import 'dart:async';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/models/sync_state.dart';
import 'package:omi/services/aisa_offline_sync_service.dart';
import 'package:omi/services/connectivity_service.dart';
import 'package:omi/services/wals/flash_page_wal_sync.dart';
import 'package:omi/services/wals/local_wal_sync.dart';
import 'package:omi/services/wals/sdcard_wal_sync.dart';
import 'package:omi/services/wals/storage_sync.dart';
import 'package:omi/services/wals/wal.dart';
import 'package:omi/services/wals/wal_interfaces.dart';
import 'package:omi/utils/aisa_debug_logger.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';

class WalSyncs implements IWalSync {
  late LocalWalSyncImpl _phoneSync;
  LocalWalSyncImpl get phone => _phoneSync;

  late SDCardWalSyncImpl _sdcardSync;
  SDCardWalSyncImpl get sdcard => _sdcardSync;

  late FlashPageWalSyncImpl _flashPageSync;
  FlashPageWalSyncImpl get flashPage => _flashPageSync;

  late StorageSyncImpl _storageSync;
  StorageSyncImpl get storage => _storageSync;

  final IWalSyncListener listener;

  bool _isCancelled = false;

  WalSyncs(this.listener) {
    _phoneSync = LocalWalSyncImpl(listener);
    _sdcardSync = SDCardWalSyncImpl(listener);
    _flashPageSync = FlashPageWalSyncImpl(listener);
    _storageSync = StorageSyncImpl(listener);

    _sdcardSync.setLocalSync(_phoneSync);
    _flashPageSync.setLocalSync(_phoneSync);
    _storageSync.setLocalSync(_phoneSync);

    _sdcardSync.loadWifiCredentials();
  }

  @override
  Future deleteWal(Wal wal) async {
    await _phoneSync.deleteWal(wal);
    await _sdcardSync.deleteWal(wal);
    await _flashPageSync.deleteWal(wal);
    await _storageSync.deleteWal(wal);
  }

  @override
  Future<List<Wal>> getMissingWals() async {
    List<Wal> wals = [];
    wals.addAll(await _storageSync.getMissingWals());
    wals.addAll(await _sdcardSync.getMissingWals());
    wals.addAll(await _phoneSync.getMissingWals());
    wals.addAll(await _flashPageSync.getMissingWals());
    return wals;
  }

  Future<List<Wal>> getAllWals() async {
    List<Wal> wals = [];
    wals.addAll(await _storageSync.getMissingWals());
    wals.addAll(await _sdcardSync.getMissingWals());
    wals.addAll(await _phoneSync.getAllWals());
    wals.addAll(await _flashPageSync.getMissingWals());
    return wals;
  }

  Future<WalStats> getWalStats() async {
    final allWals = await getAllWals();
    int phoneFiles = 0;
    int sdcardFiles = 0;
    int fromSdcardFiles = 0;
    int limitlessFiles = 0;
    int fromFlashPageFiles = 0;
    int phoneSize = 0;
    int sdcardSize = 0;
    int syncedFiles = 0;
    int missedFiles = 0;

    for (final wal in allWals) {
      if (wal.storage == WalStorage.sdcard) {
        sdcardFiles++;
        sdcardSize += _estimateWalSize(wal);
      } else if (wal.storage == WalStorage.flashPage) {
        limitlessFiles++;
      } else {
        if (wal.originalStorage == WalStorage.sdcard) {
          fromSdcardFiles++;
        } else if (wal.originalStorage == WalStorage.flashPage) {
          fromFlashPageFiles++;
        } else {
          phoneFiles++;
        }
        phoneSize += _estimateWalSize(wal);
      }

      if (wal.status == WalStatus.synced) {
        syncedFiles++;
      } else if (wal.status == WalStatus.miss) {
        missedFiles++;
      }
    }

    return WalStats(
      totalFiles: allWals.length,
      phoneFiles: phoneFiles,
      sdcardFiles: sdcardFiles,
      fromSdcardFiles: fromSdcardFiles,
      limitlessFiles: limitlessFiles,
      fromFlashPageFiles: fromFlashPageFiles,
      phoneSize: phoneSize,
      sdcardSize: sdcardSize,
      syncedFiles: syncedFiles,
      missedFiles: missedFiles,
    );
  }

  int _estimateWalSize(Wal wal) {
    int bytesPerSecond;
    switch (wal.codec) {
      case BleAudioCodec.opusFS320:
        bytesPerSecond = 16000;
      case BleAudioCodec.opus:
        bytesPerSecond = 8000;
        break;
      case BleAudioCodec.pcm16:
        bytesPerSecond = wal.sampleRate * 2 * wal.channel;
        break;
      case BleAudioCodec.pcm8:
        bytesPerSecond = wal.sampleRate * 1 * wal.channel;
        break;
      default:
        bytesPerSecond = 8000;
    }
    return bytesPerSecond * wal.seconds;
  }

  Future<void> deleteAllSyncedWals() async {
    await _phoneSync.deleteAllSyncedWals();
    await _sdcardSync.deleteAllSyncedWals();
    await _flashPageSync.deleteAllSyncedWals();
    await _storageSync.deleteAllSyncedWals();
  }

  Future<void> deleteAllPendingWals() async {
    await _phoneSync.deleteAllPendingWals();
    await _sdcardSync.deleteAllPendingWals();
    await _flashPageSync.deleteAllPendingWals();
    await _storageSync.deleteAllPendingWals();
  }

  @override
  void start() {
    _phoneSync.start();
    _sdcardSync.start();
    _flashPageSync.start();
    _storageSync.start();
  }

  @override
  Future stop() async {
    await _phoneSync.stop();
    await _sdcardSync.stop();
    await _flashPageSync.stop();
    await _storageSync.stop();
  }

  @override
  Future<SyncLocalFilesResponse?> syncAll({
    IWalSyncProgressListener? progress,
    IWifiConnectionListener? connectionListener,
  }) async {
    _isCancelled = false;
    var resp = SyncLocalFilesResponse(newConversationIds: [], updatedConversationIds: []);

    final allMissing = await getMissingWals();
    DebugLogManager.logEvent('sync_started', {
      'totalMissingWals': allMissing.length,
      'sdcard': allMissing.where((w) => w.storage == WalStorage.sdcard).length,
      'flashPage': allMissing.where((w) => w.storage == WalStorage.flashPage).length,
      'phone': allMissing.where((w) => w.storage == WalStorage.disk || w.storage == WalStorage.mem).length,
    });

    // Phase 0: New multi-file storage sync (for new firmware with LittleFS)
    // Refresh file list from device via BLE (safe — not syncing yet)
    await _storageSync.refreshWalsFromDevice();
    final storageMissing = await _storageSync.getMissingWals();
    AisaDebugLogger.instance.info('[Sync] Phase 0: LittleFSファイル ${storageMissing.length}件検出');
    if (storageMissing.isNotEmpty) {
      Logger.debug("WalSyncs: Phase 0 - Downloading ${storageMissing.length} multi-file storage files to phone");
      DebugLogManager.logInfo('Sync Phase 0: Multi-file storage sync');
      AisaDebugLogger.instance.info('[Sync] Phase 0: BLEダウンロード開始 (${storageMissing.length}件)');
      progress?.onWalSyncedProgress(0.0, phase: SyncPhase.downloadingFromDevice);
      await _storageSync.syncAll(progress: progress);
      AisaDebugLogger.instance.info('[Sync] Phase 0: BLEダウンロード完了');
    }

    if (_isCancelled) {
      Logger.debug("WalSyncs: Cancelled after storage sync phase");
      return resp;
    }

    // Phase 1a: Download SD card data to phone (legacy firmware)
    Logger.debug("WalSyncs: Phase 1a - Downloading SD card data to phone");
    DebugLogManager.logInfo('Sync Phase 1a: Downloading SD card data to phone');
    progress?.onWalSyncedProgress(0.0, phase: SyncPhase.downloadingFromDevice);
    // AISA: setDevice()はasync voidのため、onDeviceConnectedと競合する場合がある。
    // ここで必ず最新のペンダントストレージ状態を取得し直す。
    await _sdcardSync.start();
    final missingSDCardWals = (await _sdcardSync.getMissingWals()).where((w) => w.status == WalStatus.miss).toList();
    final wifiSupported = await _sdcardSync.isWifiSyncSupported();
    AisaDebugLogger.instance.info('[Sync] Phase 1a: SDカードWAL ${missingSDCardWals.length}件, WiFi対応=$wifiSupported');

    bool usedWifi = false;
    if (missingSDCardWals.isNotEmpty) {
      final preferredMethod = SharedPreferencesUtil().preferredSyncMethod;

      if (preferredMethod == 'wifi' && wifiSupported) {
        usedWifi = true;
        AisaDebugLogger.instance.info('[Sync] Phase 1a: WiFi転送開始 (${missingSDCardWals.length}件)');
        DebugLogManager.logInfo('SD card sync using WiFi', {'walCount': missingSDCardWals.length});
        await _sdcardSync.syncWithWifi(progress: progress, connectionListener: connectionListener);
        AisaDebugLogger.instance.info('[Sync] Phase 1a: WiFi転送完了');
      } else {
        AisaDebugLogger.instance.info('[Sync] Phase 1a: BLE転送開始 (${missingSDCardWals.length}件, method=$preferredMethod)');
        DebugLogManager.logInfo('SD card sync using BLE', {'walCount': missingSDCardWals.length});
        await _sdcardSync.syncAll(progress: progress);
        AisaDebugLogger.instance.info('[Sync] Phase 1a: BLE転送完了');
      }
    }

    if (_isCancelled) {
      Logger.debug("WalSyncs: Cancelled after SD card phase");
      DebugLogManager.logWarning('Sync cancelled after SD card phase');
      return resp;
    }

    // Phase 1b: Download flash page data to phone
    Logger.debug("WalSyncs: Phase 1b - Downloading flash page data to phone");
    DebugLogManager.logInfo('Sync Phase 1b: Downloading flash page data to phone');
    // AISA: 同上 - 最新状態を取得してから同期
    await _flashPageSync.start();
    await _flashPageSync.syncAll(progress: progress);

    if (_isCancelled) {
      Logger.debug("WalSyncs: Cancelled after flash page phase");
      DebugLogManager.logWarning('Sync cancelled after flash page phase');
      return resp;
    }

    if (usedWifi) {
      Logger.debug("WalSyncs: Waiting for internet after WiFi transfer...");
      DebugLogManager.logInfo('Waiting for internet after WiFi transfer');
      progress?.onWalSyncedProgress(0.0, phase: SyncPhase.waitingForInternet);
      await _waitForInternet();
    }

    if (_isCancelled) {
      Logger.debug("WalSyncs: Cancelled after waiting for internet");
      DebugLogManager.logWarning('Sync cancelled while waiting for internet');
      return resp;
    }

    // AISA Phase: SDカード/FlashPageからダウンロード済みのWALをGroq Whisperで文字起こし
    // バックグラウンド実行: syncPendingWals内でWALをsynced即時マークするためPhase 2と競合しない
    Logger.debug("WalSyncs: AISA Phase - Transcribing downloaded WALs in background");
    DebugLogManager.logInfo('AISA Phase: Transcribing downloaded WALs');
    try {
      final allMissing = await _phoneSync.getMissingWals();
      final diskMissWals = allMissing
          .where((w) => w.storage == WalStorage.disk && w.status == WalStatus.miss)
          .toList();
      AisaDebugLogger.instance.info('[Sync] AISA Phase: 未処理WAL ${diskMissWals.length}件');
      if (diskMissWals.isNotEmpty && !AisaOfflineSyncService.instance.isSyncing) {
        Logger.debug("WalSyncs: AISA - ${diskMissWals.length}件のWALをバックグラウンドで文字起こし開始");
        AisaDebugLogger.instance.info('[Sync] AISA Phase: Groq文字起こしをバックグラウンドで開始 (${diskMissWals.length}件)');
        // バックグラウンド実行: syncPendingWals内で最初にWALをsyncedマークするため
        // Phase 2（Omiクラウド送信）と競合しない。Groq処理は同期完了後も継続する。
        // ignore: unawaited_futures
        AisaOfflineSyncService.instance.syncPendingWals(diskMissWals, _phoneSync);
      } else if (AisaOfflineSyncService.instance.isSyncing) {
        Logger.debug("WalSyncs: AISA - 既に文字起こし実行中のためスキップ");
        AisaDebugLogger.instance.info('[Sync] AISA Phase: 既に実行中のためスキップ');
      }
    } catch (e) {
      Logger.debug("WalSyncs: AISA phase error (continuing to Phase 2): $e");
    }

    if (_isCancelled) {
      Logger.debug("WalSyncs: Cancelled after AISA phase");
      return resp;
    }

    // Phase 2: Upload all phone files to cloud (includes SD card and flash page downloads)
    Logger.debug("WalSyncs: Phase 2 - Uploading phone files to cloud");
    DebugLogManager.logInfo('Sync Phase 2: Uploading phone files to cloud');
    progress?.onWalSyncedProgress(0.0, phase: SyncPhase.uploadingToCloud);
    var partialRes = await _phoneSync.syncAll(progress: progress);
    if (partialRes != null) {
      resp.newConversationIds.addAll(
        partialRes.newConversationIds.where((id) => !resp.newConversationIds.contains(id)),
      );
      resp.updatedConversationIds.addAll(
        partialRes.updatedConversationIds.where(
          (id) => !resp.updatedConversationIds.contains(id) && !resp.newConversationIds.contains(id),
        ),
      );
    }

    DebugLogManager.logEvent('sync_completed', {
      'newConversations': resp.newConversationIds.length,
      'updatedConversations': resp.updatedConversationIds.length,
    });

    return resp;
  }

  @override
  Future<SyncLocalFilesResponse?> syncWal({
    required Wal wal,
    IWalSyncProgressListener? progress,
    IWifiConnectionListener? connectionListener,
  }) async {
    if (wal.storage == WalStorage.sdcard) {
      progress?.onWalSyncedProgress(0.0, phase: SyncPhase.downloadingFromDevice);
      final preferredMethod = SharedPreferencesUtil().preferredSyncMethod;
      final wifiSupported = await _sdcardSync.isWifiSyncSupported();

      if (preferredMethod == 'wifi' && wifiSupported) {
        return await _sdcardSync.syncWithWifi(progress: progress, connectionListener: connectionListener);
      } else {
        return _sdcardSync.syncWal(wal: wal, progress: progress);
      }
    } else if (wal.storage == WalStorage.flashPage) {
      progress?.onWalSyncedProgress(0.0, phase: SyncPhase.downloadingFromDevice);
      return _flashPageSync.syncWal(wal: wal, progress: progress);
    } else {
      progress?.onWalSyncedProgress(0.0, phase: SyncPhase.uploadingToCloud);
      return _phoneSync.syncWal(wal: wal, progress: progress);
    }
  }

  @override
  void cancelSync() {
    _isCancelled = true;
    _storageSync.cancelSync();
    _sdcardSync.cancelSync();
    _flashPageSync.cancelSync();
    _phoneSync.cancelSync();
  }

  bool get isStorageSyncing => _storageSync.isSyncing;

  double get storageSpeedKBps => _storageSync.currentSpeedKBps;

  bool get isSdCardSyncing => _sdcardSync.isSyncing;

  double get sdCardSpeedKBps => _sdcardSync.currentSpeedKBps;

  bool get isFlashPageSyncing => _flashPageSync.isSyncing;

  /// Get conversation IDs accumulated so far from completed upload batches.
  /// Returns null if no sync is in progress or no batches have completed.
  SyncLocalFilesResponse? get accumulatedResponse => _phoneSync.accumulatedResponse;

  /// Wait for internet connectivity to be restored (e.g. after WiFi transfer).
  /// Polls every 2 seconds, gives up after 60 seconds.
  /// WiFi同期後にペンダントのAPからスマホのWiFiに戻るまで最大60秒待機する
  /// （iOS のWiFi切り替えは環境によっては30秒以上かかる場合がある）
  Future<void> _waitForInternet() async {
    final connectivity = ConnectivityService();
    for (int i = 0; i < 30; i++) {
      if (connectivity.isConnected) {
        Logger.debug("WalSyncs: Internet available after ${i * 2}s");
        DebugLogManager.logInfo('Internet restored after ${i * 2}s');
        return;
      }
      await Future.delayed(const Duration(seconds: 2));
    }
    Logger.debug("WalSyncs: Internet not available after 60s, proceeding anyway");
    DebugLogManager.logWarning('Internet not available after 60s - WiFi復帰に時間がかかっています。クラウド同期が失敗する場合は手動で再同期してください。');
  }
}
