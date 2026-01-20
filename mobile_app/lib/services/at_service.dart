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
  bool _isProcessingNotification = false;
  StreamSubscription? _notificationSubscription;
  DateTime? _subscriptionStartTime; // Track when we started subscribing

  // Callback for received stats
  Function(TransmitterStats)? onStatsReceived;
  Function(Map<String, dynamic>)? onAlertReceived;

  bool get isInitialized => _isInitialized;
  String? get currentAtSign => _currentAtSign;
  AtClient? get atClient => _atClient;

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

      // Start listening for notifications
      _subscribeToNotifications();

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

    // Cancel notification subscription
    _notificationSubscription?.cancel();
    _notificationSubscription = null;

    notifyListeners();
  }

  /// Subscribe to incoming notifications
  ///
  /// This subscription remains open throughout the app lifecycle, including
  /// during data timeouts. This enables automatic recovery when the data
  /// stream resumes - the UI will automatically switch from the red timeout
  /// banner back to the green status card.
  void _subscribeToNotifications() {
    if (_atClient == null || _isDisposed) {
      logger.warning(
          'Cannot subscribe: ${_atClient == null ? "atClient is null" : "service is disposed"}');
      return;
    }

    logger.info('Subscribing to notifications (current data only)');

    // Mark the time we start subscribing - only accept notifications after this point
    _subscriptionStartTime = DateTime.now();
    logger.info(
        'Will only accept notifications newer than: $_subscriptionStartTime');

    try {
      // Subscribe to notifications - fetchOfflineNotifications=false ensures only new data
      _notificationSubscription = _atClient!.notificationService
          .subscribe(
        regex: '.*kryz',
        shouldDecrypt: true,
      )
          .handleError((error, stackTrace) {
        // Catch errors from the stream itself (e.g., during decryption)
        if (error.toString().contains('FileSystemException') ||
            error.toString().contains('File closed') ||
            error.toString().contains('exception in get')) {
          logger.warning(
              'File system error in notification decryption (database may be unavailable): $error');
          // Don't rethrow - just log and continue, keeping subscription alive
        } else {
          logger.severe('Unexpected error in notification stream: $error',
              error, stackTrace);
        }
      }).listen(
        (notification) {
          // Double-check not disposed before processing
          if (_isDisposed) {
            logger.fine(
                'Notification received but service is disposed, ignoring');
            return;
          }

          try {
            _handleNotification(notification);
          } catch (e, stackTrace) {
            // Catch any errors during notification handling to prevent stream closure
            if (e.toString().contains('FileSystemException') ||
                e.toString().contains('File closed')) {
              logger.warning(
                  'File system error during notification handling (app may be shutting down): $e');
            } else {
              logger.severe('Error handling notification: $e', e, stackTrace);
            }
          }
        },
        onError: (error, stackTrace) {
          // Handle stream errors gracefully
          if (error.toString().contains('FileSystemException') ||
              error.toString().contains('File closed') ||
              error.toString().contains('exception in get')) {
            logger.warning(
                'File system error in notification stream (likely app shutdown or database issue): $error');
          } else {
            logger.severe(
                'Notification stream error: $error', error, stackTrace);
          }
        },
        cancelOnError: false, // Keep subscription alive despite errors
      );
    } catch (e, stackTrace) {
      logger.severe(
          'Failed to create notification subscription: $e', e, stackTrace);
    }
  }

  /// Handle incoming notification
  void _handleNotification(AtNotification notification) {
    // Ignore notifications if service is disposed or already processing
    if (_isDisposed) {
      logger.fine('Ignoring notification after disposal');
      return;
    }

    // Filter out old notifications - only accept notifications created after subscription started
    if (_subscriptionStartTime != null) {
      final notificationTime =
          DateTime.fromMillisecondsSinceEpoch(notification.epochMillis);
      if (notificationTime.isBefore(_subscriptionStartTime!)) {
        logger.info(
            'Ignoring old notification from $notificationTime (before subscription at $_subscriptionStartTime)');
        return;
      }
    }

    if (_isProcessingNotification) {
      logger.fine('Already processing a notification, skipping this one');
      // Skip concurrent notifications to avoid database contention
      return;
    }

    _isProcessingNotification = true;

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

      // Check if this looks like encrypted data that failed to decrypt
      if (value.length > 100 && !value.startsWith('{')) {
        logger.warning(
            'Received encrypted notification - decryption may have failed due to database issue');
        logger.warning(
            'This can happen after timeout when database is temporarily unavailable');
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
      if (e.toString().contains('FileSystemException') ||
          e.toString().contains('File closed')) {
        logger.warning(
            'File system error handling notification (database may be closing): $e');
      } else if (e is FormatException) {
        logger.warning(
            'Failed to parse notification JSON - may be encrypted data: $e');
      } else {
        logger.severe('Failed to handle notification: $e', e, stackTrace);
      }
    } finally {
      _isProcessingNotification = false;
    }
  }

  /// Cleanup
  @override
  void dispose() {
    logger.info('Disposing AtService - cancelling notification subscription');
    _isDisposed = true;

    // Cancel subscription IMMEDIATELY to prevent processing notifications during shutdown
    _notificationSubscription?.cancel();
    _notificationSubscription = null;

    super.dispose();
  }
}
