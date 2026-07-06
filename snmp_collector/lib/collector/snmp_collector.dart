import 'dart:async';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:at_client/at_client.dart';
import 'package:at_onboarding_cli/at_onboarding_cli.dart' as cli;
import '../services/snmp_service.dart';
import '../services/at_collection_service.dart';
import '../services/at_notification_service.dart';

final logger = Logger('SNMPCollector');

class SNMPCollector {
  final String atSign;
  final List<String> receivers;
  final String transmitterHost;
  final int transmitterPort;
  final String community;
  final int pollIntervalSeconds;
  final bool useSimulatedData;

  late AtClient atClient;
  late SNMPService snmpService;

  /// Writes every reading to the atCollection (persisted, end-to-end encrypted).
  late AtCollectionService collectionService;

  /// Sends urgent alert notifications (separate from the stats collection).
  late AtNotificationService alertService;

  Timer? _pollTimer;
  bool _isRunning = false;

  SNMPCollector({
    required this.atSign,
    required this.receivers,
    required this.transmitterHost,
    this.transmitterPort = 161,
    this.community = 'public',
    this.pollIntervalSeconds = 2,
    this.useSimulatedData = true,
  });

  /// Initialize and authenticate using at_onboarding_cli
  Future<void> initialize(String keysFilePath) async {
    logger.info('Initializing SNMP Collector for $atSign');

    // Check if keys file exists
    final keysFile = File(keysFilePath);
    if (!await keysFile.exists()) {
      throw Exception('Keys file not found: $keysFilePath');
    }

    // Set up atOnboarding preferences
    final atOnboardingPreference = cli.AtOnboardingPreference()
      ..rootDomain = 'root.atsign.org'
      ..namespace = 'kryz'
      ..hiveStoragePath = '.atsign/storage/$atSign'
      ..commitLogPath = '.atsign/storage/$atSign/commitLog'
      ..atKeysFilePath = keysFilePath
      // Without this the SDK fetches all pending offline notifications from
      // the atServer after auth — that network round-trip can block indefinitely
      // and prevent authenticate() from returning.
      ..fetchOfflineNotifications = false;

    // Use at_onboarding_cli to onboard
    final atOnboarding = cli.AtOnboardingServiceImpl(
      atSign,
      atOnboardingPreference,
    );

    final result = await atOnboarding.authenticate();
    if (!result) {
      throw Exception('Authentication failed for $atSign');
    }

    // Get the authenticated atClient
    atClient = AtClientManager.getInstance().atClient;

    logger.info('atClient initialised and authenticated successfully');

    // Convert receiver strings → Atsign objects for the collection API
    final receiverAtsigns = receivers.map((r) => r.toAtsign()).toSet();

    // Initialise collection service (stats are persisted here, not notified)
    collectionService = AtCollectionService(
      atClient: atClient,
      receivers: receiverAtsigns,
    );
    logger.info('Opening tiered collections…');
    await collectionService.initialize();
    logger.info('Tiered collections ready');

    // Switch to remote-only writes AFTER collections are opened.
    // Setting this before collection init resets the client namespace to ''
    // (AtClientPreference() defaults) and may trigger a reconnect that
    // deadlocks during startup.  Collections are opened with default
    // (local-first) settings; subsequent writes use remote-only so each
    // reading is pushed to the atServer without waiting for the sync timer.
    atClient.setPreferences(
        AtClientPreference()..remoteLocalPref = RemoteLocalPref.remoteOnly);
    logger.info('Remote-only write mode enabled');

    // Initialise alert service (urgent alerts still use notification API)
    alertService = AtNotificationService(atClient: atClient);

    // Initialise SNMP service
    snmpService = SNMPService(
      host: transmitterHost,
      port: transmitterPort,
      community: community,
      useSimulatedData: useSimulatedData,
    );

    if (!useSimulatedData) {
      await snmpService.initialize();
      logger.info('SNMP session initialised for real data collection');
    } else {
      logger.info('Using simulated SNMP data');
    }

    logger.info('Initialisation complete');
  }

  /// Start collecting and writing to the atCollection
  Future<void> start() async {
    if (_isRunning) {
      logger.warning('Collector is already running');
      return;
    }

    logger.info(
        'Starting SNMP collection (polling every ${pollIntervalSeconds}s)');
    _isRunning = true;

    // Initial collection
    await _collectAndPersist();

    // Set up periodic polling.
    // _isBusy prevents a new cycle from starting while the previous async
    // write is still in flight (e.g. when the atServer is slow to respond).
    // Without this guard, timed-out writes pile up concurrently and can
    // exhaust the SDK connection pool.
    bool _isBusy = false;
    _pollTimer = Timer.periodic(
      Duration(seconds: pollIntervalSeconds),
      (_) async {
        if (_isBusy) {
          logger.warning(
              'Previous collection cycle still running — skipping tick');
          return;
        }
        _isBusy = true;
        try {
          await _collectAndPersist();
        } finally {
          _isBusy = false;
        }
      },
    );
  }

  /// Stop collecting
  void stop() {
    logger.info('Stopping SNMP collection');
    _pollTimer?.cancel();
    _pollTimer = null;
    _isRunning = false;
  }

  /// Collect SNMP data, persist to collection, and send alert notification if needed.
  Future<void> _collectAndPersist() async {
    try {
      logger.fine('Collecting transmitter stats');

      final stats = await snmpService.collectStats();

      logger.info('Collected: $stats');

      // Write reading to AtCollection — this is the primary data path.
      // The SDK handles encryption, sync, and delivery to all receivers.
      await collectionService.appendReading(stats);

      // If an alert condition exists, also send an urgent notification so
      // the mobile app can display an immediate modal without waiting for sync.
      if (stats.alertLevel != null) {
        logger.warning(
            'Alert detected: ${stats.alertLevel} — sending notification');
        await alertService.sendAlert(stats, receivers);
      }

      logger.fine('Reading persisted successfully');
    } on TypeError catch (e, stackTrace) {
      // SDK internal type error (e.g. at_client getKeys returning a scalar
      // instead of a List). This is unrecoverable for this run — exit so the
      // OS / Docker / launchd can restart the process cleanly.
      logger.severe(
          'Fatal SDK TypeError — exiting for OS restart', e, stackTrace);
      exit(1);
    } catch (e, stackTrace) {
      logger.severe('Error collecting/persisting data', e, stackTrace);
    }
  }

  /// Cleanup resources
  Future<void> dispose() async {
    stop();
    logger.info('Collector disposed');
  }
}
