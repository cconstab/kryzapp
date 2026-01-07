import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:at_client_mobile/at_client_mobile.dart';
import 'package:at_onboarding_flutter/at_onboarding_flutter.dart';
import 'package:logging/logging.dart';
import 'package:kryz_shared/kryz_shared.dart';

final logger = Logger('AtService');

class AtService extends ChangeNotifier {
  AtClient? _atClient;
  String? _currentAtSign;
  bool _isInitialized = false;
  bool _isDisposed = false;
  StreamSubscription? _notificationSubscription;

  // Callback for received stats
  Function(TransmitterStats)? onStatsReceived;
  Function(Map<String, dynamic>)? onAlertReceived;

  bool get isInitialized => _isInitialized;
  String? get currentAtSign => _currentAtSign;
  AtClient? get atClient => _atClient;

  /// Initialize atClient service
  Future<void> initialize(BuildContext context) async {
    try {
      logger.info('Initializing atClient service');

      // Trigger onboarding
      await AtOnboarding.onboard(
        context: context,
        config: AtOnboardingConfig(
          atClientPreference: AtClientPreference()
            ..rootDomain = 'root.atsign.org'
            ..namespace = 'kryz'
            ..hiveStoragePath = 'storage'
            ..commitLogPath = 'storage/commitLog'
            ..isLocalStoreRequired = true // Required for keys and auth
            ..fetchOfflineNotifications = false, // Only process new notifications, not history
          rootEnvironment: RootEnvironment.Production,
          domain: 'root.atsign.org',
        ),
      );

      // Get the current @sign from AtClientManager
      _currentAtSign = AtClientManager.getInstance().atClient.getCurrentAtSign();

      if (_currentAtSign == null) {
        logger.warning('Onboarding cancelled - no @sign selected');
        return;
      }

      logger.info('Onboarded with @sign: $_currentAtSign');

      // Get atClient instance
      _atClient = AtClientManager.getInstance().atClient;
      _isInitialized = true;

      // Start listening for notifications
      _subscribeToNotifications();

      notifyListeners();
    } catch (e, stackTrace) {
      logger.severe('Failed to initialize atClient', e, stackTrace);
      rethrow;
    }
  }

  /// Subscribe to incoming notifications
  void _subscribeToNotifications() {
    if (_atClient == null) return;

    logger.info('Subscribing to notifications (current data only)');

    // Subscribe to notifications - fetchOfflineNotifications=false ensures only new data
    _notificationSubscription = _atClient!.notificationService
        .subscribe(
          regex: '.*kryz',
          shouldDecrypt: true,
        )
        .listen(
      (notification) {
        try {
          _handleNotification(notification);
        } catch (e, stackTrace) {
          // Catch any errors during notification handling to prevent stream closure
          logger.severe('Error handling notification: $e', e, stackTrace);
        }
      },
      onError: (error, stackTrace) {
        // Handle stream errors gracefully
        if (error.toString().contains('FileSystemException') || error.toString().contains('File closed')) {
          logger.warning('File system error in notification stream (likely app shutdown): $error');
        } else {
          logger.severe('Notification stream error: $error', error, stackTrace);
        }
      },
      cancelOnError: false, // Keep subscription alive despite errors
    );
  }

  /// Handle incoming notification
  void _handleNotification(AtNotification notification) {
    // Ignore notifications if service is disposed
    if (_isDisposed) {
      logger.fine('Ignoring notification after disposal');
      return;
    }

    try {
      logger.info('Received notification: ${notification.key}');
      logger.fine(
          'Notification details - key: ${notification.key}, value: ${notification.value}, from: ${notification.from}');

      final key = notification.key;
      var value = notification.value;

      if (value == null || value.isEmpty) {
        logger.warning('Notification value is null or empty');
        return;
      }

      // The atPlatform handles encryption/decryption automatically
      // We should receive plain JSON here
      if (key.contains(NotificationKeys.transmitterStats)) {
        // Parse transmitter stats
        final Map<String, dynamic> jsonData = jsonDecode(value);
        final stats = TransmitterStats.fromJson(jsonData);

        logger.info('Received stats: $stats');
        onStatsReceived?.call(stats);
      } else if (key.contains(NotificationKeys.alertNotification)) {
        // Parse alert
        final Map<String, dynamic> alertData = jsonDecode(value);

        logger.warning('Received alert: $alertData');
        onAlertReceived?.call(alertData);
      }
    } catch (e, stackTrace) {
      logger.severe('Failed to handle notification: $e', e, stackTrace);
    }
  }

  /// Cleanup
  @override
  void dispose() {
    _isDisposed = true;
    _notificationSubscription?.cancel();
    super.dispose();
  }
}
