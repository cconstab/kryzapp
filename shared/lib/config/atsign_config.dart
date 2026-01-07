/// Configuration for atPlatform connection
class AtSignConfig {
  final String atSign;
  final String namespace;
  final String? rootDomain;
  final int? rootPort;

  AtSignConfig({
    required this.atSign,
    this.namespace = 'kryz',
    this.rootDomain,
    this.rootPort,
  });

  /// Validate @sign format
  bool get isValid {
    return atSign.startsWith('@') && atSign.length > 1;
  }
}

/// Known @signs for the KRYZ system
class KryzAtSigns {
  static const String transmitter = '@kryz_transmitter';
  static const String collector = '@snmp_collector';
  static const String mobileApp = '@cconstab'; // Mobile app @sign
  static const String bob = '@bob';

  /// List of all @signs that are authorized to receive transmitter data
  static const List<String> authorizedReceivers = [
    mobileApp,
    bob,
  ];
}

/// atPlatform notification keys
class NotificationKeys {
  static const String transmitterStats = 'transmitter_stats';
  static const String alertNotification = 'alert';
  static const String statusUpdate = 'status_update';

  /// Build a full atKey identifier
  static String buildKey(String key, String namespace) {
    return '$key.$namespace';
  }
}
