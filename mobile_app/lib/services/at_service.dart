import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:at_auth/at_auth.dart';
import 'package:logging/logging.dart';
import 'package:kryz_shared/kryz_shared.dart';

final logger = Logger('AtService');

class AtService extends ChangeNotifier {
  AtClient? _atClient;
  String? _currentAtSign;
  bool _isInitialized = false;
  bool _isDisposed = false;

  // Collection for persisted stats (used only for historical queries / sync;
  // live stats arrive via the raw notification stream below — see comment in
  // _subscribeToCollection() for why we can't trust AtCollection.updates here).
  AtCollection<TransmitterStats>? _statsCollection;

  // Raw notification subscription for live stats — delivers each 2-second
  // reading within milliseconds of arrival (bypasses the AtCollection.updates
  // → getOrNull round-trip which currently fails for cached recipient-side
  // keys in at_client 3.12.0-rc.2).
  StreamSubscription? _statsNotifSub;

  // Alert notifications remain on the notification service for immediate delivery
  StreamSubscription? _alertSubscription;

  // Sync progress tracking
  SyncProgress? _latestSync;
  SyncProgressListener? _syncListener;
  Timer? _syncTimer;

  // Callbacks wired up by DashboardScreen
  Function(TransmitterStats)? onStatsReceived;
  Function(Map<String, dynamic>)? onAlertReceived;
  Function(AtCollection<TransmitterStats>)? onCollectionReady;

  bool get isInitialized => _isInitialized;
  String? get currentAtSign => _currentAtSign;
  AtClient? get atClient => _atClient;

  /// Exposed so that [TransmitterProvider] can run historical queries.
  AtCollection<TransmitterStats>? get statsCollection => _statsCollection;

  /// Latest sync progress event — null until the first sync cycle completes.
  SyncProgress? get latestSync => _latestSync;

  /// Initialize the service after successful authentication
  /// This should be called after PkamDialog.show() succeeds with AtClientPreference
  Future<void> initializeWithAuthResponse(
      AtAuthResponse response, AtClientPreference preference) async {
    try {
      logger.info('Initializing atClient service');

      // Get atSign from response
      _currentAtSign = response.atSign;

      if (_currentAtSign == null) {
        logger.warning('No atSign found in auth response');
        return;
      }

      logger.info('Setting current atSign in AtClientManager: $_currentAtSign');

      // Set the current atSign in AtClientManager - this initializes the AtClient
      // Pass AtChops and AtLookUp from the auth response to ensure proper initialization
      await AtClientManager.getInstance().setCurrentAtSign(
        _currentAtSign!,
        'kryz',
        preference,
        atChops: response.atChops,
        atLookUp: response.atLookUp,
      );

      // Get the initialized atClient instance
      _atClient = AtClientManager.getInstance().atClient;
      _isInitialized = true;

      logger.info('AtClient initialized successfully for $_currentAtSign');

      // Open the collection and start listening for new readings + alerts
      await _subscribeToCollection();

      // Register sync progress listener so the UI can show local vs server commit.
      _syncListener = _SyncListenerImpl((progress) {
        _latestSync = progress;
        notifyListeners();
      });
      _atClient!.syncService.addProgressListener(_syncListener!);

      notifyListeners();
    } catch (e, stackTrace) {
      logger.severe('Failed to initialize atClient', e, stackTrace);
      rethrow;
    }
  }

  /// Reset/logout - clear the current session
  void reset() {
    logger.info('Resetting AtService');
    // Remove sync listener before clearing atClient reference.
    if (_syncListener != null && _atClient != null) {
      _atClient!.syncService.removeProgressListener(_syncListener!);
      _syncListener = null;
    }
    _latestSync = null;
    _isInitialized = false;
    _currentAtSign = null;
    _atClient = null;
    _statsCollection = null;

    _statsNotifSub?.cancel();
    _statsNotifSub = null;

    _alertSubscription?.cancel();
    _alertSubscription = null;

    _syncTimer?.cancel();
    _syncTimer = null;

    notifyListeners();
  }

  /// Open the [AtCollection<TransmitterStats>] and subscribe to:
  ///   1. New readings  → via raw `notificationService.subscribe` so each
  ///      2-second push from the collector updates the gauge within ms.
  ///   2. Alert events  → still via [notificationService] for immediate delivery
  ///
  /// Why not [AtCollection.updates]?  In at_client 3.12.0-rc.2 the SDK
  /// stores received notifications under a `cached:<receiver>:<id>.<ns>@<sender>`
  /// key (two `:` prefix segments), but `AtCollection.getOrNull(id, owner)`
  /// builds a regex that only tolerates one prefix segment
  /// (`^(?!local:)(?:[^:]*:)?<id>\.<ns>@<sender>`).  That means the
  /// `CItemUpdated` event fires but the immediate `getOrNull` call returns
  /// null — so gauges stay stuck until sync rewrites the key in
  /// single-prefix form (typically ~30 s later).  Bypassing AtCollection
  /// and reading `n.value` directly delivers the same envelope JSON the
  /// publisher wrote (`{type:'TransmitterStats', obj:{...}}`) instantly.
  Future<void> _subscribeToCollection() async {
    if (_atClient == null || _isDisposed) {
      logger
          .warning('Cannot subscribe: atClient is null or service is disposed');
      return;
    }

    logger.info('Opening AtCollection<TransmitterStats> (stats.kryz)');

    try {
      // startListening ensures the notification service is up before we
      // subscribe to its event stream.
      _atClient!.notificationService.startListening();

      // Open the collection so that history queries (getItems / getAtKeys)
      // and future sync writes have a typed entry point — but DON'T listen
      // to its `updates` stream (see method docstring above).
      _statsCollection = await _atClient!.collection<TransmitterStats>(
        'stats.kryz',
        const Duration(minutes: 10),
        fromJson: TransmitterStats.fromJson,
        typeTag: 'TransmitterStats',
        eventSource: EventSource.notifs,
      );

      logger.info(
          'Collection opened — subscribing to raw stats notifications');

      // Match every notification whose key is a stats.kryz collection item.
      // Shape: `<receiver>:<itemId>.stats.kryz@<sender>` — the leading `.`
      // before `stats` excludes `stats5m.kryz` / `stats1h.kryz` (which the
      // TransmitterProvider subscribes to separately for chart tiers).
      _statsNotifSub = _atClient!.notificationService
          .subscribe(
        regex: r'.*\.stats\.kryz@.*',
        shouldDecrypt: true,
      )
          .handleError((error) {
        logger.warning('Stats notification subscription error: $error');
      }).listen(
        (notification) {
          if (_isDisposed) return;
          _handleStatsNotification(notification);
        },
        cancelOnError: false,
      );

      // Notify the dashboard so it can pass the collection to TransmitterProvider
      if (_statsCollection != null) {
        onCollectionReady?.call(_statsCollection!);
      }

      // Trigger an immediate sync to pull any pending data from the atServer,
      // then keep syncing every 30 s as a catch-up safety net for missed
      // notifications (e.g. after the app comes back from background).  Live
      // updates do NOT depend on this timer anymore — they arrive via the
      // notification stream above.
      _atClient!.syncService.sync();
      _syncTimer?.cancel();
      _syncTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!_isDisposed) _atClient?.syncService.sync();
      });

      // Alert notifications still travel via the notification service so the
      // mobile UI can pop up a modal immediately, without waiting for sync.
      _alertSubscription = _atClient!.notificationService
          .subscribe(
        regex: '.*${NotificationKeys.alertNotification}.*kryz',
        shouldDecrypt: true,
      )
          .handleError((error) {
        logger.warning('Alert subscription error: $error');
      }).listen(
        (notification) {
          if (_isDisposed) return;
          _handleAlertNotification(notification);
        },
        cancelOnError: false,
      );

      logger.info('Stats + alert notification subscriptions active');
    } catch (e, st) {
      logger.severe('Failed to open collection or subscribe', e, st);
    }
  }

  /// Parse a stats collection notification and forward the decoded
  /// [TransmitterStats] to the dashboard.  Notification `value` is the
  /// decrypted envelope JSON that [AtCollection.create] originally wrote:
  /// `{"type":"TransmitterStats","obj":{...}}`.
  void _handleStatsNotification(AtNotification notification) {
    try {
      final value = notification.value;
      if (value == null || value.isEmpty) return;
      if (!value.startsWith('{')) {
        logger.warning(
            'Stats notification value not decrypted, skipping (key=${notification.key})');
        return;
      }
      final env = jsonDecode(value) as Map<String, dynamic>;
      if (env['type'] != 'TransmitterStats') return;
      final stats =
          TransmitterStats.fromJson(env['obj'] as Map<String, dynamic>);
      logger.fine('Notif → ${stats.transmitterId} '
          'powerOut=${stats.powerOut}W @ ${stats.timestamp}');
      onStatsReceived?.call(stats);
    } catch (e, st) {
      logger.severe('Failed to parse stats notification', e, st);
    }
  }

  /// Handle incoming alert notifications (stats travel via collection instead).
  void _handleAlertNotification(AtNotification notification) {
    try {
      final value = notification.value;
      if (value == null || value.isEmpty) return;

      if (!value.startsWith('{')) {
        logger
            .warning('Alert notification value appears un-decrypted, skipping');
        return;
      }

      final alertData = jsonDecode(value) as Map<String, dynamic>;
      logger.warning('Received alert: $alertData');
      onAlertReceived?.call(alertData);
    } catch (e, st) {
      logger.severe('Failed to parse alert notification', e, st);
    }
  }

  /// Cleanup
  @override
  void dispose() {
    logger.info('Disposing AtService');
    _isDisposed = true;

    if (_syncListener != null && _atClient != null) {
      _atClient!.syncService.removeProgressListener(_syncListener!);
      _syncListener = null;
    }

    _statsNotifSub?.cancel();
    _statsNotifSub = null;

    _alertSubscription?.cancel();
    _alertSubscription = null;

    _syncTimer?.cancel();
    _syncTimer = null;

    super.dispose();
  }
}

// ── Private helper ────────────────────────────────────────────────────────────
class _SyncListenerImpl extends SyncProgressListener {
  _SyncListenerImpl(this._onProgress);
  final void Function(SyncProgress) _onProgress;

  @override
  void onSyncProgressEvent(SyncProgress syncProgress) =>
      _onProgress(syncProgress);
}
