import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:at_client/at_client.dart' show AtCollection;
import 'package:at_auth/at_auth.dart';
import 'package:logging/logging.dart';
import 'package:kryz_shared/kryz_shared.dart';

final logger = Logger('AtService');

class AtService extends ChangeNotifier {
  AtClient? _atClient;
  String? _currentAtSign;
  bool _isInitialized = false;
  bool _isDisposed = false;

  // Collection for persisted stats (replaces the old notification-based stats feed)
  AtCollection<TransmitterStats>? _statsCollection;
  StreamSubscription? _collectionSub;

  // Alert notifications remain on the notification service for immediate delivery
  StreamSubscription? _alertSubscription;

  // Callbacks wired up by DashboardScreen
  Function(TransmitterStats)? onStatsReceived;
  Function(Map<String, dynamic>)? onAlertReceived;
  Function(AtCollection<TransmitterStats>)? onCollectionReady;

  bool get isInitialized => _isInitialized;
  String? get currentAtSign => _currentAtSign;
  AtClient? get atClient => _atClient;

  /// Exposed so that [TransmitterProvider] can run historical queries.
  AtCollection<TransmitterStats>? get statsCollection => _statsCollection;

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

      notifyListeners();
    } catch (e, stackTrace) {
      logger.severe('Failed to initialize atClient', e, stackTrace);
      rethrow;
    }
  }

  /// Reset/logout - clear the current session
  void reset() {
    logger.info('Resetting AtService');
    _isInitialized = false;
    _currentAtSign = null;
    _atClient = null;
    _statsCollection = null;

    _collectionSub?.cancel();
    _collectionSub = null;

    _alertSubscription?.cancel();
    _alertSubscription = null;

    notifyListeners();
  }

  /// Open the [AtCollection<TransmitterStats>] and subscribe to:
  ///   1. New readings  → via [collection.updates] (replaces old notify-based stats)
  ///   2. Alert events  → still via [notificationService] for immediate delivery
  Future<void> _subscribeToCollection() async {
    if (_atClient == null || _isDisposed) {
      logger
          .warning('Cannot subscribe: atClient is null or service is disposed');
      return;
    }

    logger.info('Opening AtCollection<TransmitterStats> (stats.kryz)');

    try {
      _statsCollection = await _atClient!.collection<TransmitterStats>(
        'stats.kryz',
        const Duration(days: 7),
        fromJson: TransmitterStats.fromJson,
        typeTag: 'TransmitterStats',
      );

      logger.info('Collection opened — subscribing to updates stream');

      // Listen for new / updated readings written by the collector.
      // CItemUpdated carries (owner, id) only — fetch the item to get the obj.
      _collectionSub = _statsCollection!.updates.listen(
        (event) async {
          if (_isDisposed) return;
          try {
            final citem =
                await _statsCollection!.getOrNull(event.id, event.owner);
            if (citem == null) return;
            final stats = citem.obj;
            logger.info('Collection update: ${stats.transmitterId} '
                'powerOut=${stats.powerOut}W @ ${stats.timestamp}');
            onStatsReceived?.call(stats);
          } catch (e, st) {
            logger.severe('Error processing collection event', e, st);
          }
        },
        onError: (error, st) {
          logger.severe('Collection updates stream error', error, st);
        },
        cancelOnError: false,
      );

      // Notify the dashboard so it can pass the collection to TransmitterProvider
      if (_statsCollection != null) {
        onCollectionReady?.call(_statsCollection!);
      }

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

      logger.info('Collection + alert subscriptions active');
    } catch (e, st) {
      logger.severe('Failed to open collection or subscribe', e, st);
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

    _collectionSub?.cancel();
    _collectionSub = null;

    _alertSubscription?.cancel();
    _alertSubscription = null;

    super.dispose();
  }
}
