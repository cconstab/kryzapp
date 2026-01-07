import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:at_client/at_client.dart';
import 'package:at_chops/at_chops.dart';
import '../services/snmp_service.dart';
import '../services/at_notification_service.dart';

final logger = Logger('SNMPCollector');

class SNMPCollector {
  final String atSign;
  final List<String> receivers;
  final String transmitterHost;
  final int transmitterPort;
  final String community;
  final int pollIntervalSeconds;

  late AtClient atClient;
  late SNMPService snmpService;
  late AtNotificationService notificationService;

  Timer? _pollTimer;
  bool _isRunning = false;

  SNMPCollector({
    required this.atSign,
    required this.receivers,
    required this.transmitterHost,
    this.transmitterPort = 161,
    this.community = 'public',
    this.pollIntervalSeconds = 5,
  });

  /// Initialize atClient and authenticate
  Future<void> initialize() async {
    logger.info('Initializing SNMP Collector for $atSign');

    // Initialize atClient using onboarding service
    final atClientManager = await AtClientManager.getInstance().setCurrentAtSign(
      atSign,
      'kryz',
      AtClientPreference()
        ..rootDomain = 'root.atsign.org'
        ..namespace = 'kryz'
        ..hiveStoragePath = '.atsign/storage/$atSign'
        ..commitLogPath = '.atsign/storage/$atSign/commitLog'
        ..isLocalStoreRequired = true,
    );

    atClient = atClientManager.atClient;

    logger.info('atClient initialized successfully');

    // Initialize SNMP service
    snmpService = SNMPService(
      host: transmitterHost,
      port: transmitterPort,
      community: community,
    );

    // Initialize notification service
    notificationService = AtNotificationService(atClient: atClient);

    logger.info('Initialization complete');
  }

  /// Authenticate using .atKeys file
  Future<void> authenticate(String keysFilePath) async {
    logger.info('Authenticating $atSign');

    // Read keys file
    final keysFile = File(keysFilePath);
    if (!await keysFile.exists()) {
      throw Exception('Keys file not found: $keysFilePath');
    }

    final atKeysData = await keysFile.readAsString();
    final atKeysMap = jsonDecode(atKeysData) as Map<String, dynamic>;

    // Create AtChopsKeys from the atKeys file
    final atEncryptionKeyPair = AtEncryptionKeyPair.create(
      atKeysMap[AtConstants.atEncryptionPublicKey]!,
      atKeysMap[AtConstants.atEncryptionPrivateKey]!,
    );

    final atPkamKeyPair = AtPkamKeyPair.create(
      atKeysMap[AtConstants.atPkamPublicKey]!,
      atKeysMap[AtConstants.atPkamPrivateKey]!,
    );

    final selfEncryptionKey = atKeysMap[AtConstants.atEncryptionSelfKey]!;

    final atChopsKeys = AtChopsKeys.create(atEncryptionKeyPair, atPkamKeyPair);
    if (selfEncryptionKey != null) {
      atChopsKeys.selfEncryptionKey = AESKey(selfEncryptionKey);
    }

    final atChops = AtChopsImpl(atChopsKeys);
    atClient.atChops = atChops;

    logger.info('Authentication successful');
  }

  /// Start collecting and sending notifications
  Future<void> start() async {
    if (_isRunning) {
      logger.warning('Collector is already running');
      return;
    }

    logger.info('Starting SNMP collection (polling every ${pollIntervalSeconds}s)');
    _isRunning = true;

    // Initial collection
    await _collectAndNotify();

    // Set up periodic polling
    _pollTimer = Timer.periodic(
      Duration(seconds: pollIntervalSeconds),
      (_) => _collectAndNotify(),
    );
  }

  /// Stop collecting
  void stop() {
    logger.info('Stopping SNMP collection');
    _pollTimer?.cancel();
    _pollTimer = null;
    _isRunning = false;
  }

  /// Collect SNMP data and send notifications
  Future<void> _collectAndNotify() async {
    try {
      logger.fine('Collecting transmitter stats');

      // Collect stats from transmitter via SNMP
      final stats = await snmpService.collectStats();

      logger.info('Collected: $stats');

      // Check for alerts
      if (stats.alertLevel != null) {
        logger.warning('Alert detected: ${stats.alertLevel} - $stats');
      }

      // Send notifications to authorized receivers
      await notificationService.sendTransmitterStats(
        stats,
        receivers,
      );

      logger.fine('Notifications sent successfully');
    } catch (e, stackTrace) {
      logger.severe('Error collecting/sending data', e, stackTrace);
    }
  }

  /// Cleanup resources
  Future<void> dispose() async {
    stop();
    logger.info('Collector disposed');
  }
}
