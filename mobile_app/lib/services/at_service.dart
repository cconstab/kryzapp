import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:at_client_mobile/at_client_mobile.dart';
import 'package:at_onboarding_flutter/at_onboarding_flutter.dart';
import 'package:logging/logging.dart';
import 'package:kryz_shared/kryz_shared.dart';

final logger = Logger('AtService');

class AtService extends ChangeNotifier {
  AtClientService? _atClientService;
  AtClient? _atClient;
  String? _currentAtSign;
  bool _isInitialized = false;
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

      _atClientService = AtClientService();

      // Trigger onboarding
      await AtOnboarding.onboard(
        context: context,
        config: AtOnboardingConfig(
          atClientPreference: AtClientPreference()
            ..rootDomain = 'root.atsign.org'
            ..namespace = 'kryz'
            ..hiveStoragePath = 'storage'
            ..commitLogPath = 'storage/commitLog'
            ..isLocalStoreRequired = true,
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

    logger.info('Subscribing to notifications');

    _notificationSubscription = _atClient!.notificationService.subscribe(regex: '.*kryz').listen(
      (notification) {
        _handleNotification(notification);
      },
      onError: (error) {
        logger.severe('Notification stream error: $error');
      },
    );
  }

  /// Handle incoming notification
  void _handleNotification(AtNotification notification) {
    try {
      logger.info('Received notification: ${notification.key}');

      final key = notification.key;
      final value = notification.value;

      if (value == null) return;

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
      logger.severe('Failed to handle notification', e, stackTrace);
    }
  }

  /// Cleanup
  @override
  void dispose() {
    _notificationSubscription?.cancel();
    super.dispose();
  }
}
