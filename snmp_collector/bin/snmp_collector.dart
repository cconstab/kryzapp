import 'dart:async';
import 'dart:io';
import 'package:args/args.dart';
import 'package:at_utils/at_logger.dart';
import 'package:logging/logging.dart';
import 'package:snmp_collector/collector/snmp_collector.dart';

void main(List<String> arguments) {
  runZonedGuarded(
    () => _run(arguments),
    (e, stackTrace) {
      // Any error that escapes all async zones (SDK internal, unhandled Future
      // rejection, etc.) lands here.  Log it and exit so the OS can restart.
      final logger = Logger('main');
      logger.severe(
          'Uncaught async error — exiting for OS restart', e, stackTrace);
      exit(1);
    },
  );
}

Future<void> _run(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('atsign',
        abbr: 'a', help: 'The @sign for this collector', mandatory: true)
    ..addOption('keys',
        abbr: 'k',
        help:
            'Path to the .atKeys file (default: ~/.atsign/keys/<atsign>_key.atKeys)')
    ..addOption('receivers',
        abbr: 'r',
        help: 'Comma-separated list of @signs to receive notifications',
        mandatory: true)
    ..addOption('host',
        abbr: 'h', help: 'SNMP host address', defaultsTo: '127.0.0.1')
    ..addOption('port', abbr: 'p', help: 'SNMP port', defaultsTo: '161')
    ..addOption('community',
        abbr: 'c', help: 'SNMP community string', defaultsTo: 'public')
    ..addOption('interval',
        abbr: 'i', help: 'Poll interval in seconds', defaultsTo: '2')
    ..addFlag('simulated',
        abbr: 's',
        help: 'Use simulated data instead of real SNMP queries',
        defaultsTo: false)
    ..addFlag('verbose',
        abbr: 'v',
        negatable: false,
        help: 'Enable verbose (FINE) logging; default is SEVERE only')
    ..addFlag('help', negatable: false, help: 'Show this help message');

  // Parse early so -v takes effect before any logging.
  // Re-parsed below inside the try block for full validation.
  final earlyArgs = parser.parse(arguments);
  final verbose = earlyArgs['verbose'] as bool;
  // SDK loggers use AtSignLogger which creates Logger.detached() instances —
  // they never propagate to root, so root level filtering cannot silence them.
  // The only effective control is AtSignLogger.root_level, which is read when
  // each SDK logger is constructed.  Set it BEFORE collector.initialize() so
  // all SDK loggers default to SEVERE in non-verbose mode.
  if (!verbose) {
    AtSignLogger.root_level = 'severe';
  } else {
    AtSignLogger.root_level = 'finest';
  }
  // Our own loggers use the standard hierarchy and reach root.
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    final minLevel = verbose ? Level.FINE : Level.SEVERE;
    if (record.level < minLevel) return;
    print('${record.level.name}: ${record.time}: ${record.message}');
    if (record.error != null) print('  Error: ${record.error}');
    if (record.stackTrace != null) print('  ${record.stackTrace}');
  });

  final logger = Logger('main');

  try {
    final args = earlyArgs;

    if (args['help'] as bool) {
      print('KRYZ SNMP Collector');
      print('');
      print('Usage:');
      print('  dart run bin/snmp_collector.dart [options]');
      print('');
      print('Options:');
      print(parser.usage);
      print('');
      print('Example:');
      print(
          '  dart run bin/snmp_collector.dart -a @snmp_collector -r @cconstab,@bob');
      print(
          '  dart run bin/snmp_collector.dart -a @snmp_collector -k .atsign/@snmp_collector_key.atKeys -r @cconstab,@bob');
      exit(0);
    }

    final atSign = args['atsign'] as String;
    final keysPath = args['keys'] as String? ??
        '${Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']}/.atsign/keys/${atSign}_key.atKeys';
    final receiversArg = args['receivers'] as String;
    final receivers = receiversArg
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final host = args['host'] as String;
    final port = int.parse(args['port'] as String);
    final community = args['community'] as String;
    final interval = int.parse(args['interval'] as String);
    final useSimulated = args['simulated'] as bool;

    logger.info('Starting KRYZ SNMP Collector');
    logger.info('@sign: $atSign');
    logger.info('Keys file: $keysPath');
    logger.info('SNMP host: $host:$port');
    logger.info('Data mode: ${useSimulated ? "SIMULATED" : "REAL SNMP"}');
    logger.info('Receivers: ${receivers.join(", ")}');

    // Create collector
    final collector = SNMPCollector(
      atSign: atSign,
      receivers: receivers,
      transmitterHost: host,
      transmitterPort: port,
      community: community,
      pollIntervalSeconds: interval,
      useSimulatedData: useSimulated,
    );

    // Initialize and authenticate
    await collector.initialize(keysPath);

    // Start collecting
    await collector.start();

    logger.info('Collector is running. Press Ctrl+C to stop.');

    // Handle shutdown gracefully
    ProcessSignal.sigint.watch().listen((signal) async {
      logger.info('Received shutdown signal');
      await collector.dispose();
      exit(0);
    });

    // Keep running
    await Future.delayed(Duration(days: 365));
  } catch (e, stackTrace) {
    logger.severe('Fatal error', e, stackTrace);
    print('');
    print('Usage:');
    print(parser.usage);
    exit(1);
  }
}
