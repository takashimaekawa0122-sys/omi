import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/backend/schema/conversation.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/services/aisa_offline_sync_service.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/wals.dart';
import 'package:omi/utils/debug_log_manager.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/time_utils.dart';
import 'package:omi/models/sync_state.dart';
import 'package:omi/utils/audio_player_utils.dart';
import 'package:omi/utils/conversation_sync_utils.dart';
import 'package:omi/utils/waveform_utils.dart';

enum WalStatusFilter { pending, synced }

class SyncProvider extends ChangeNotifier implements IWalServiceListener, IWalSyncProgressListener {
  // Services
  final AudioPlayerUtils _audioPlayerUtils = AudioPlayerUtils.instance;

  // AISA: SDカード転送中に音声ストリーミングを止めるためCaptureProviderを保持
  CaptureProvider? _captureProvider;
  void setCaptureProvider(CaptureProvider? provider) { _captureProvider = provider; }

  // WAL management
  List<Wal> _allWals = [];
  List<Wal> get allWals => _allWals;
  bool _isLoadingWals = false;
  bool get isLoadingWals => _isLoadingWals;

  // Storage filter
  WalStorage? _storageFilter;
  WalStorage? get storageFilter => _storageFilter;

  // Status filter (used by SyncPage)
  WalStatusFilter _statusFilter = WalStatusFilter.pending;
  WalStatusFilter get statusFilter => _statusFilter;

  void setStatusFilter(WalStatusFilter filter) {
    _statusFilter = filter;
    notifyListeners();
  }

  List<Wal> get pendingWals =>
      _allWals.where((w) => w.status == WalStatus.miss || w.status == WalStatus.corrupted || w.isSyncing).toList();

  List<Wal> get syncedWals => _allWals.where((w) => w.status == WalStatus.synced).toList();

  List<Wal> get filteredByStatusWals {
    if (_statusFilter == WalStatusFilter.pending) {
      return pendingWals;
    }
    return syncedWals;
  }

  List<Wal> get filteredWals {
    if (_storageFilter == null) {
      return _allWals;
    }

    // SD Card filter: show WALs on SD card OR transferred from SD card
    if (_storageFilter == WalStorage.sdcard) {
      return _allWals
          .where((wal) => wal.storage == WalStorage.sdcard || wal.originalStorage == WalStorage.sdcard)
          .toList();
    }

    // Flash Page filter: show WALs on flash page OR transferred from flash page
    if (_storageFilter == WalStorage.flashPage) {
      return _allWals
          .where((wal) => wal.storage == WalStorage.flashPage || wal.originalStorage == WalStorage.flashPage)
          .toList();
    }

    // Phone filter: show WALs on phone that are NOT originally from SD card or flash page
    if (_storageFilter == WalStorage.disk || _storageFilter == WalStorage.mem) {
      return _allWals
          .where(
            (wal) =>
                (wal.storage == WalStorage.disk || wal.storage == WalStorage.mem) &&
                wal.originalStorage != WalStorage.sdcard &&
                wal.originalStorage != WalStorage.flashPage,
          )
          .toList();
    }

    // Other filters
    return _allWals.where((wal) => wal.storage == _storageFilter).toList();
  }

  // Sync state
  SyncState _syncState = const SyncState();
  SyncState get syncState => _syncState;

  // Track WAL processing progress
  int _totalWalsToProcess = 0;
  int _walsProcessedCount = 0;

  // Computed properties for backward compatibility
  List<Wal> get missingWals => _allWals.where((w) => w.status == WalStatus.miss).toList();
  int get missingWalsInSeconds =>
      missingWals.isEmpty ? 0 : missingWals.map((val) => val.seconds).reduce((a, b) => a + b);

  /// Missing WALs that are still on device storage (SD card or Limitless flash page)
  /// These are files that need to be downloaded from the hardware device
  List<Wal> get missingWalsOnDevice => _allWals
      .where((w) => w.status == WalStatus.miss && (w.storage == WalStorage.sdcard || w.storage == WalStorage.flashPage))
      .toList();

  // Backward compatibility getters
  bool get isSyncing => _syncState.isSyncing;
  bool get syncCompleted => _syncState.isCompleted;
  bool get isFetchingConversations => _syncState.isFetchingConversations;
  double get walsSyncedProgress => _syncState.progress;
  double? get syncSpeedKBps => _syncState.speedKBps;
  List<SyncedConversationPointer> get syncedConversationsPointers => _syncState.syncedConversations;
  String? get syncError => _syncState.errorMessage;
  Wal? get failedWal => _syncState.failedWal;
  SyncMethod? get currentSyncMethod => _syncState.syncMethod;

  // Flash page (Limitless) sync state
  bool get isFlashPageSyncing => _walService.getSyncs().isFlashPageSyncing;

  /// Get a WAL by ID from the current list
  Wal? getWalById(String walId) {
    try {
      return _allWals.firstWhere((w) => w.id == walId);
    } catch (e) {
      return null;
    }
  }

  // Audio playback delegates
  String? get currentPlayingWalId => _audioPlayerUtils.currentPlayingId;
  bool get isProcessingAudio => _audioPlayerUtils.isProcessingAudio;
  Duration get currentPosition => _audioPlayerUtils.currentPosition;
  Duration get totalDuration => _audioPlayerUtils.totalDuration;
  double get playbackProgress => _audioPlayerUtils.playbackProgress;

  IWalService get _walService => ServiceManager.instance().wal;

  SyncProvider() {
    _walService.subscribe(this, this);
    _audioPlayerUtils.addListener(_onAudioPlayerStateChanged);
    _initializeProvider();
  }

  void _initializeProvider() async {
    await refreshWals();
    // 起動時：前セッションでディスクに残ったWALを処理
    await _triggerAisaOfflineSyncIfNeeded();
  }

  bool _isAisaSyncing = false;
  bool _isAutoUploading = false;

  /// AISA Phase 2: ディスク上の未同期WALをGroq Whisperで文字起こしする
  /// 起動時 & WAL追加時（SDカードダウンロード完了後など）に呼ばれる
  /// 処理中に新チャンクが到着しても、完了後に再チェックして取りこぼしを防ぐ
  Future<void> _triggerAisaOfflineSyncIfNeeded() async {
    if (_isAisaSyncing) return;

    _isAisaSyncing = true;
    try {
      // 処理が完了してもまだ pending がある限りループ（チャンク逐次到着に対応）
      // 注: 呼び出し元（_initializeProvider / onWalUpdated）で既にrefreshWals()済み
      while (true) {
        final pendingWals = _allWals
            .where((w) => w.status == WalStatus.miss && w.storage == WalStorage.disk)
            .toList();
        if (pendingWals.isEmpty) break;

        Logger.debug('[AISA Offline] ${pendingWals.length}件のオフライン録音をGroq Whisperで処理');
        final phoneSync = _walService.getSyncs().phone as LocalWalSyncImpl;
        await AisaOfflineSyncService.instance.syncPendingWals(pendingWals, phoneSync);

        // 処理後に再取得してまだpendingが残っていないか確認
        await refreshWals();
      }
      Logger.debug('[AISA Offline] オフライン同期完了');
    } catch (e) {
      Logger.debug('[AISA Offline] オフライン同期エラー: $e');
    } finally {
      _isAisaSyncing = false;
    }
  }

  /// AISA同期を中断する（手動同期開始時など）
  void _cancelAisaSyncIfNeeded() {
    if (_isAisaSyncing) {
      Logger.debug('[AISA Offline] 手動同期開始のためAISA同期を中断');
      AisaOfflineSyncService.instance.cancelSync();
      _isAisaSyncing = false;
    }
  }

  /// Cancel auto-upload if running. Called before device-triggered sync.
  void _cancelAutoUploadIfNeeded() {
    if (_isAutoUploading) {
      Logger.debug('SyncProvider: Cancelling auto-upload for device sync');
      _walService.getSyncs().phone.cancelSync();
      _isAutoUploading = false;
    }
  }

  void _onAudioPlayerStateChanged() {
    notifyListeners();
  }

  void _updateSyncState(SyncState newState) {
    _syncState = newState;
    notifyListeners();
  }

  Future<void> refreshWals() async {
    _isLoadingWals = true;
    notifyListeners();

    _allWals = await _walService.getSyncs().getAllWals();
    Logger.debug('SyncProvider: Loaded ${_allWals.length} WALs (${missingWals.length} missing)');

    _isLoadingWals = false;
    notifyListeners();
  }

  Future<WalStats> getWalStats() async {
    return await _walService.getSyncs().getWalStats();
  }

  Future<void> deleteWal(Wal wal) async {
    await _walService.getSyncs().deleteWal(wal);
    await refreshWals();
  }

  Future<void> deleteAllSyncedWals() async {
    await _walService.getSyncs().deleteAllSyncedWals();
    await refreshWals();
  }

  Future<void> deleteAllPendingWals() async {
    await _walService.getSyncs().deleteAllPendingWals();
    await refreshWals();
  }

  Future<void> syncWals({IWifiConnectionListener? connectionListener}) async {
    _cancelAutoUploadIfNeeded();
    _cancelAisaSyncIfNeeded(); // AISA同期中なら中断してから手動同期を開始
    _updateSyncState(_syncState.toIdle());
    _totalWalsToProcess = missingWals.length;
    _walsProcessedCount = 0;

    // AISA: SDカード転送中はBLE帯域を占有するため、全BLE通知を停止する。
    // stopStreamDeviceRecording()はDartのStreamをキャンセルするだけで
    // ネイティブのBLE subscribeは解除されない。そのためペンダントが音声データを
    // 送り続けBLE帯域が圧迫され「デバイスが応答しません」が発生していた。
    final wasStreaming = _captureProvider != null;
    if (wasStreaming) {
      Logger.debug('[AISA] SDカード同期前に音声ストリーミングを停止');
      await _captureProvider!.stopStreamDeviceRecording();
    }

    final deviceId = SharedPreferencesUtil().btDevice.id;

    // BLE通知を一時停止してファイル転送専用に帯域を確保するヘルパー
    Future<void> pauseBleNotifications() async {
      if (deviceId.isEmpty) return;
      try {
        final connection = await ServiceManager.instance().device.ensureConnection(deviceId);
        if (connection != null) {
          final transport = connection.transport;
          // NativeBleTransportかどうかをruntimeTypeで確認してからdynamicキャスト
          // 注: `transport is dynamic` は常にtrueのため使わない
          if (transport.runtimeType.toString().contains('NativeBle')) {
            await (transport as dynamic).pauseAllNotifications();
            Logger.debug('[AISA] BLE通知全解除完了');
          }
        }
      } catch (e) {
        Logger.debug('[AISA] pauseAllNotifications failed (non-critical): $e');
      }
      // ペンダントが通知停止を処理する時間を確保
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // ネイティブBLE通知を明示的に全解除（帯域をファイル転送専用に確保）
    await pauseBleNotifications();

    try {
      // AISA: 転送失敗時は最大3回まで自動リトライ（storageOffsetが保持されるため途中再開可能）
      const maxRetries = 3;
      for (int attempt = 1; attempt <= maxRetries; attempt++) {
        final isLastAttempt = attempt == maxRetries;

        if (attempt > 1) {
          Logger.debug('[AISA] SDカード転送リトライ $attempt/$maxRetries (5秒後)');
          await Future.delayed(const Duration(seconds: 5));
          // WALリストを最新化してから再試行
          await refreshWals();
          _totalWalsToProcess = missingWals.length;
          _walsProcessedCount = 0;
          // BLE通知を再度一時停止（前回の失敗でリストアされている可能性があるため）
          await pauseBleNotifications();
          // 再試行前にSyncing状態にリセット
          _updateSyncState(_syncState.toSyncing());
        }

        final succeeded = await _performSync(
          operation: () => _walService.getSyncs().syncAll(progress: this, connectionListener: connectionListener),
          context: 'sync all WALs (attempt $attempt/$maxRetries)',
          isLastAttempt: isLastAttempt,
        );

        if (succeeded || isLastAttempt) break;

        Logger.debug('[AISA] 転送失敗 → リトライします (attempt $attempt/$maxRetries)');
      }
    } finally {
      if (wasStreaming) {
        Logger.debug('[AISA] SDカード同期後に音声ストリーミングを再開');
        await _captureProvider!.streamDeviceRecording();
      }
    }
  }

  /// AISA自動同期用：WiFi対応デバイスならWiFiで、非対応ならBLEでSDカードデータをダウンロードする
  /// WiFiはBLEより100〜1000倍高速（BLE: 1〜10KB/s → WiFi: 1MB/s以上）
  /// デバイス接続時・アプリ起動時に自動呼び出しされる
  Future<void> syncWalsViaBle() async {
    final previousMethod = SharedPreferencesUtil().preferredSyncMethod;
    // WiFi対応デバイスならWiFiを優先（BLEは低速すぎて長時間録音に耐えられない）
    final wifiSupported = await _walService.getSyncs().sdcard.isWifiSyncSupported();
    SharedPreferencesUtil().preferredSyncMethod = wifiSupported ? 'wifi' : 'ble';
    Logger.debug('[AISA] 自動同期: ${wifiSupported ? "WiFi" : "BLE"}モードで開始');
    try {
      await syncWals();
    } finally {
      // 同期後に元の設定を復元（ユーザーの選択を変更しない）
      SharedPreferencesUtil().preferredSyncMethod = previousMethod;
    }
  }

  Future<void> syncWal(Wal wal, {IWifiConnectionListener? connectionListener}) async {
    _cancelAutoUploadIfNeeded();
    _updateSyncState(_syncState.toIdle());
    await _performSync(
      operation: () => _walService.getSyncs().syncWal(wal: wal, progress: this, connectionListener: connectionListener),
      context: 'sync WAL ${wal.id}',
      failedWal: wal,
      isLastAttempt: true, // Single WAL sync: always show error on failure
    );
  }

  /// Performs a single sync attempt.
  /// Returns true on success, false on failure.
  /// Only updates error state on failure if [isLastAttempt] is true,
  /// so retry loops can call this without showing transient error states to the user.
  Future<bool> _performSync({
    required Future<SyncLocalFilesResponse?> Function() operation,
    required String context,
    Wal? failedWal,
    bool isLastAttempt = true,
  }) async {
    try {
      _updateSyncState(_syncState.toSyncing());

      // Check for SD card WALs - if present, log two-phase sync
      final sdCardWals = missingWals.where((w) => w.storage == WalStorage.sdcard).toList();
      if (sdCardWals.isNotEmpty) {
        Logger.debug('SyncProvider: Two-phase sync - ${sdCardWals.length} SD card files will be downloaded first');
      }

      DebugLogManager.logInfo('SyncProvider: starting $context', {
        'totalMissing': missingWals.length,
        'sdCardWals': sdCardWals.length,
        'deviceWals': missingWalsOnDevice.length,
      });

      final result = await operation();

      // If sync was cancelled while awaiting, don't override the cancel state.
      // cancelSync() already processed any partial conversation results.
      if (!_syncState.isSyncing && _syncState.status != SyncStatus.fetchingConversations) {
        return true; // Treat cancel as "done" so caller doesn't retry
      }

      if (result != null && _hasConversationResults(result)) {
        Logger.debug(
          'SyncProvider: $context returned ${result.newConversationIds.length} new, ${result.updatedConversationIds.length} updated conversations',
        );
        DebugLogManager.logInfo('SyncProvider: $context succeeded', {
          'newConversations': result.newConversationIds.length,
          'updatedConversations': result.updatedConversationIds.length,
        });
        await _processConversationResults(result);
      } else {
        DebugLogManager.logInfo('SyncProvider: $context completed with no new conversations');
        _updateSyncState(_syncState.toCompleted(conversations: []));
      }
      return true;
    } catch (e) {
      final errorMessage = _formatSyncError(e, failedWal);
      Logger.debug('SyncProvider: Error in $context: $errorMessage');
      DebugLogManager.logError(e, null, 'SyncProvider: $context failed: $errorMessage', {
        if (failedWal != null) 'walId': failedWal.id,
        if (failedWal != null) 'walStorage': failedWal.storage.toString(),
      });
      // Only show error state on the final attempt to avoid flickering during retries
      if (isLastAttempt) {
        _updateSyncState(_syncState.toError(message: errorMessage, failedWal: failedWal));
      }
      return false;
    }
  }

  bool _hasConversationResults(SyncLocalFilesResponse result) {
    return result.newConversationIds.isNotEmpty || result.updatedConversationIds.isNotEmpty;
  }

  String _formatSyncError(dynamic error, Wal? wal) {
    var baseMessage = error.toString().replaceAll('Exception: ', '').replaceAll('WifiSyncException: ', '');

    // Convert technical WiFi errors to user-friendly messages
    if (baseMessage.toLowerCase().contains('internal error') ||
        baseMessage.toLowerCase().contains('invalidpacketlength') ||
        baseMessage.toLowerCase().contains('packet length')) {
      baseMessage = 'Failed to enable WiFi on device';
    } else if (baseMessage.toLowerCase().contains('wifi') && baseMessage.toLowerCase().contains('setup')) {
      baseMessage = 'Failed to enable WiFi on device';
    } else if (baseMessage.toLowerCase().contains('tcp') || baseMessage.toLowerCase().contains('socket')) {
      baseMessage = 'Connection interrupted';
    } else if (baseMessage.toLowerCase().contains('timeout')) {
      baseMessage = 'Device did not respond';
    } else if (baseMessage.toLowerCase().contains('could not be processed')) {
      baseMessage = 'Audio file could not be processed';
    } else if (baseMessage.toLowerCase().contains('too large')) {
      baseMessage = 'Recording is too large to upload';
    } else if (baseMessage.toLowerCase().contains('temporarily unavailable')) {
      baseMessage = 'Server is temporarily unavailable. Try again later';
    } else if (baseMessage.toLowerCase().contains('upload failed')) {
      baseMessage = 'Upload failed. Check your connection and try again';
    }

    if (wal != null) {
      final walInfo = '${secondsToHumanReadable(wal.seconds)} (${wal.codec.toFormattedString()})';
      final source = wal.storage == WalStorage.sdcard ? 'SD card' : 'phone';
      return 'Failed to process $source audio file $walInfo: $baseMessage';
    }

    return baseMessage;
  }

  Future<void> retrySync() async {
    final failedWal = _syncState.failedWal;
    if (failedWal != null) {
      await syncWal(failedWal);
    } else {
      await syncWals();
    }
  }

  void clearSyncResult() {
    _updateSyncState(_syncState.toIdle());
  }

  void setStorageFilter(WalStorage? filter) {
    _storageFilter = filter;
    notifyListeners();
  }

  void clearStorageFilter() {
    _storageFilter = null;
    notifyListeners();
  }

  Future<void> _processConversationResults(SyncLocalFilesResponse result) async {
    _updateSyncState(_syncState.toFetchingConversations());
    final conversations = await ConversationSyncUtils.processConversationIds(
      newConversationIds: result.newConversationIds,
      updatedConversationIds: result.updatedConversationIds,
    );
    _updateSyncState(_syncState.toCompleted(conversations: conversations));
    // Refresh WAL list so home screen cloud icon updates (clears synced WALs)
    await refreshWals();
  }

  // Audio playback delegate methods
  bool isWalPlaying(String walId) => _audioPlayerUtils.isPlaying(walId);
  bool canPlayOrShareWal(Wal wal) => _audioPlayerUtils.canPlayOrShare(wal);

  Future<void> toggleWalPlayback(Wal wal) async {
    await _audioPlayerUtils.togglePlayback(wal);
  }

  Future<void> shareWalAsWav(Wal wal) async {
    await _audioPlayerUtils.shareAsAudio(wal);
  }

  Future<void> seekToPosition(Duration position) async {
    await _audioPlayerUtils.seekToPosition(position);
  }

  Future<void> skipForward({Duration duration = const Duration(seconds: 10)}) async {
    await _audioPlayerUtils.skipForward(duration: duration);
  }

  Future<void> skipBackward({Duration duration = const Duration(seconds: 10)}) async {
    await _audioPlayerUtils.skipBackward(duration: duration);
  }

  Future<List<double>?> getWaveformForWal(String walId) async {
    final wal = _allWals.firstWhere((w) => w.id == walId, orElse: () => throw Exception('WAL not found'));

    String? wavFilePath = _audioPlayerUtils.getCachedAudioPath(walId);
    if (wavFilePath == null && canPlayOrShareWal(wal)) {
      wavFilePath = await _audioPlayerUtils.ensureAudioFileExists(wal);
    }

    return await compute(_generateWaveformInBackground, {'walId': walId, 'wavFilePath': wavFilePath});
  }

  static Future<List<double>?> _generateWaveformInBackground(Map<String, dynamic> params) async {
    final String walId = params['walId'];
    final String? wavFilePath = params['wavFilePath'];

    return await WaveformUtils.generateWaveform(walId, wavFilePath);
  }

  @override
  void onWalUpdated() async {
    await refreshWals();
    // AISA同期が既に実行中の場合はwhileループが新WALを拾うので追加呼び出し不要
    if (!_isAisaSyncing) {
      _triggerAisaOfflineSyncIfNeeded(); // fire-and-forget（処理中ならフラグで即リターン）
    }
  }

  @override
  void onWalSynced(Wal wal, {ServerConversation? conversation}) async {
    await refreshWals();

    // Update progress based on WALs synced if we're currently syncing
    if (_syncState.isSyncing) {
      _walsProcessedCount++;
      // If device download created new WALs, total grows dynamically
      final currentMissing = _allWals.where((w) => w.status == WalStatus.miss).length;
      final newTotal = _walsProcessedCount + currentMissing;
      if (newTotal > _totalWalsToProcess) {
        _totalWalsToProcess = newTotal;
      }
      final walProgress = walBasedProgress;
      _updateSyncState(_syncState.toSyncing(progress: walProgress));
    }
  }

  @override
  void onStatusChanged(WalServiceStatus status) {
    Logger.debug('SyncProvider: WAL service status changed to $status');
  }

  @override
  void onWalSyncedProgress(double percentage,
      {double? speedKBps,
      SyncPhase? phase,
      int? currentFile,
      int? totalFiles,
      int? uploadedBytes,
      int? totalBytesToUpload}) {
    if (_syncState.isSyncing) {
      _updateSyncState(_syncState.toSyncing(
          progress: percentage,
          speedKBps: speedKBps,
          phase: phase,
          currentFile: currentFile,
          totalFiles: totalFiles,
          uploadedBytes: uploadedBytes,
          totalBytesToUpload: totalBytesToUpload));
    }
  }

  /// Cancel ongoing sync operation.
  /// If batches already completed, immediately shows their conversation results.
  void cancelSync() {
    DebugLogManager.logWarning('SyncProvider: user cancelled sync');
    // Grab accumulated results before cancelling
    final partialResults = _walService.getSyncs().accumulatedResponse;
    _walService.getSyncs().cancelSync();
    // Immediately clear isSyncing on all loaded WALs so UI updates right away
    for (final wal in _allWals) {
      wal.isSyncing = false;
      wal.syncStartedAt = null;
      wal.syncEtaSeconds = null;
    }
    // If batches already completed with conversations, show them immediately
    if (partialResults != null && _hasConversationResults(partialResults)) {
      _processConversationResults(partialResults);
    } else {
      _updateSyncState(_syncState.toIdle());
    }
  }

  /// Transfer a single WAL from device storage (SD card or flash page) to phone storage
  Future<void> transferWalToPhone(Wal wal, {IWifiConnectionListener? connectionListener}) async {
    if (wal.storage != WalStorage.sdcard && wal.storage != WalStorage.flashPage) {
      throw Exception('This recording is already on phone');
    }

    // Set sync state to syncing so progress updates are processed
    _updateSyncState(_syncState.toSyncing());

    try {
      await _walService.getSyncs().syncWal(wal: wal, progress: this, connectionListener: connectionListener);
      await refreshWals();
      _updateSyncState(_syncState.toIdle());
    } catch (e) {
      await refreshWals();
      _updateSyncState(_syncState.toIdle());
      rethrow;
    }
  }

  /// Check if SD card sync is in progress
  bool get isSdCardSyncing => _walService.getSyncs().isSdCardSyncing;

  // Calculate progress based on WALs synced
  double get walBasedProgress {
    if (_totalWalsToProcess == 0) return 0.0;
    return (_walsProcessedCount / _totalWalsToProcess).clamp(0.0, 1.0);
  }

  // Get the number of WALs processed
  int get processedWalsCount => _walsProcessedCount;

  // Get the total WALs to process
  int get initialMissingWalsCount => _totalWalsToProcess;

  @override
  void dispose() {
    _audioPlayerUtils.removeListener(_onAudioPlayerStateChanged);
    WaveformUtils.clearCache();
    _walService.unsubscribe(this);
    super.dispose();
  }
}
