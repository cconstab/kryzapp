import 'dart:convert';
import 'package:at_client/at_client.dart';
import 'package:logging/logging.dart';
import 'package:kryz_shared/kryz_shared.dart';

final logger = Logger('AtNotificationService');

/// Sends critical alert notifications via atPlatform.
///
/// Stats are now persisted via [AtCollectionService]; this service is
/// retained only for the alert path so the mobile app can display an
/// immediate modal without waiting for a sync round-trip.
class AtNotificationService {
  final AtClient atClient;

  AtNotificationService({required this.atClient});

  /// Send an alert notification for [stats] to every receiver in [receivers].
  /// Only called when [stats.alertLevel] is non-null.
  Future<void> sendAlert(
    TransmitterStats stats,
    List<String> receivers,
  ) async {
    final alertData = jsonEncode({
      'level': stats.alertLevel,
      'transmitterId': stats.transmitterId,
      'timestamp': stats.timestamp.toIso8601String(),
      'message': _buildAlertMessage(stats),
    });

    for (final receiver in receivers) {
      try {
        final atKey = AtKey()
          ..key = NotificationKeys.alertNotification
          ..namespace = atClient.getPreferences()!.namespace
          ..sharedWith = receiver
          ..metadata = (Metadata()
            ..isPublic = false
            ..isEncrypted = true
            ..ttl = 300000); // 5 minutes — alerts are urgent but short-lived

        await atClient.notificationService.notify(
          NotificationParams.forUpdate(atKey, value: alertData),
          waitForFinalDeliveryStatus: false,
        );

        logger.fine('Alert sent to $receiver: ${stats.alertLevel}');
      } catch (e) {
        logger.warning('Failed to send alert to $receiver: $e');
      }
    }
  }

  String _buildAlertMessage(TransmitterStats stats) {
    if (stats.status == 'FAULT')
      return 'TRANSMITTER FAULT: ${stats.transmitterId}';
    if (stats.heatTemp > 90.0)
      return 'CRITICAL: Heat Sink Temperature ${stats.heatTemp}°C exceeds limit';
    if (stats.swr > 3.0) return 'CRITICAL: SWR ${stats.swr} exceeds safe limit';
    if (stats.heatTemp > 75.0)
      return 'WARNING: High heat sink temperature ${stats.heatTemp}°C';
    if (stats.swr > 1.8) return 'WARNING: Elevated SWR ${stats.swr}';
    return 'Alert: Check transmitter status';
  }
}
