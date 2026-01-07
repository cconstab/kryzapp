import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';
import 'package:kryz_shared/kryz_shared.dart';

final logger = Logger('AtNotificationService');

/// Service for sending notifications via atPlatform
class AtNotificationService {
  final AtClient atClient;

  AtNotificationService({required this.atClient});

  /// Send transmitter stats to multiple receivers
  Future<void> sendTransmitterStats(
    TransmitterStats stats,
    List<String> receivers,
  ) async {
    final jsonData = jsonEncode(stats.toJson());

    for (final receiver in receivers) {
      try {
        await _sendNotification(
          receiver: receiver,
          key: NotificationKeys.transmitterStats,
          value: jsonData,
        );

        logger.fine('Sent stats to $receiver');
      } catch (e) {
        logger.warning('Failed to send to $receiver: $e');
      }
    }

    // If there's an alert, send a separate alert notification
    if (stats.alertLevel != null) {
      await _sendAlertNotification(stats, receivers);
    }
  }

  /// Send alert notification
  Future<void> _sendAlertNotification(
    TransmitterStats stats,
    List<String> receivers,
  ) async {
    final alertData = jsonEncode({
      'level': stats.alertLevel,
      'transmitterId': stats.transmitterId,
      'timestamp': stats.timestamp.toIso8601String(),
      'message': _getAlertMessage(stats),
    });

    for (final receiver in receivers) {
      try {
        await _sendNotification(
          receiver: receiver,
          key: NotificationKeys.alertNotification,
          value: alertData,
          priority: NotificationPriority.high,
        );
      } catch (e) {
        logger.warning('Failed to send alert to $receiver: $e');
      }
    }
  }

  /// Internal method to send a notification
  Future<void> _sendNotification({
    required String receiver,
    required String key,
    required String value,
    NotificationPriority priority = NotificationPriority.low,
  }) async {
    final atKey = AtKey()
      ..key = key
      ..namespace = atClient.getPreferences()!.namespace
      ..sharedWith = receiver
      ..metadata = (Metadata()
        ..isPublic = false
        ..isEncrypted = true // Tell atPlatform to encrypt the data
        ..ttl = 86400000); // 24 hours

    final notificationParams = NotificationParams.forUpdate(
      atKey,
      value: value,
    );

    await atClient.notificationService.notify(
      notificationParams,
      waitForFinalDeliveryStatus: false,
    );
  }

  String _getAlertMessage(TransmitterStats stats) {
    if (stats.status == 'FAULT') {
      return 'TRANSMITTER FAULT: ${stats.transmitterId}';
    }
    if (stats.heatTemp > 90.0) {
      return 'CRITICAL: Heat Sink Temperature ${stats.heatTemp}°C exceeds limit';
    }
    if (stats.swr > 3.0) {
      return 'CRITICAL: SWR ${stats.swr} exceeds safe limit';
    }
    if (stats.heatTemp > 75.0) {
      return 'WARNING: High heat sink temperature ${stats.heatTemp}°C';
    }
    if (stats.swr > 1.8) {
      return 'WARNING: Elevated SWR ${stats.swr}';
    }
    return 'Alert: Check transmitter status';
  }
}

enum NotificationPriority {
  low,
  medium,
  high,
}
