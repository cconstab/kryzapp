import 'dart:math';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:kryz_shared/kryz_shared.dart';
import 'package:dart_snmp/dart_snmp.dart' as snmp;

final logger = Logger('SNMPService');

/// Service for collecting transmitter stats via SNMP
class SNMPService {
  final String host;
  final int port;
  final String community;
  final bool useSimulatedData;

  // KRYZ Transmitter SNMP OIDs
  static const String oidModulation = '1.3.6.1.4.1.28142.1.300.1025.291.0'; // Div Peak (%)
  static const String oidSWR = '1.3.6.1.4.1.28142.1.300.256.303.0'; // SWR
  static const String oidPowerOut = '1.3.6.1.4.1.28142.1.300.256.256.0'; // Power Out (Watts)
  static const String oidPowerRef = '1.3.6.1.4.1.28142.1.300.256.257.0'; // Power Ref (Watts)
  static const String oidHeatTemp = '1.3.6.1.4.1.28142.1.300.256.271.0'; // HeatSink Temp (°C)
  static const String oidFanSpeed = '1.3.6.1.4.1.28142.1.300.256.281.0'; // Fan Speed (RPM)

  final Random _random = Random();
  dynamic _session;

  SNMPService({
    required this.host,
    required this.port,
    required this.community,
    this.useSimulatedData = false,
  });

  /// Initialize SNMP session
  Future<void> initialize() async {
    if (!useSimulatedData) {
      try {
        logger.info('Initializing SNMP session for $host:$port with community: $community');

        // Create InternetAddress from host string
        final target = InternetAddress(host);

        // Create session with the target - dart_snmp 3.0.1 API
        _session = await snmp.Snmp.createSession(target, community: community, port: port);

        logger.info('SNMP session initialized successfully');
      } catch (e, stack) {
        logger.severe('Failed to initialize SNMP session: $e', e, stack);
        rethrow;
      }
    }
  }

  /// Collect transmitter statistics via SNMP
  Future<TransmitterStats> collectStats() async {
    if (useSimulatedData || _session == null) {
      logger.fine('Using simulated data');
      return _getSimulatedStats();
    }

    try {
      logger.fine('Collecting stats from $host:$port via SNMP');

      // Query all OIDs SYNCHRONOUSLY to avoid overloading SNMP server
      final modulation = await _queryOid(oidModulation, divisor: 1000);
      if (modulation == null) {
        logger.warning('Failed to get modulation value, skipping this collection cycle');
        throw Exception('SNMP query failed - no valid data');
      }

      final swr = await _queryOid(oidSWR, divisor: 1000);
      if (swr == null) {
        logger.warning('Failed to get SWR value, skipping this collection cycle');
        throw Exception('SNMP query failed - no valid data');
      }

      final powerOut = await _queryOid(oidPowerOut, divisor: 1000);
      if (powerOut == null) {
        logger.warning('Failed to get power out value, skipping this collection cycle');
        throw Exception('SNMP query failed - no valid data');
      }

      final powerRef = await _queryOid(oidPowerRef, divisor: 1000);
      if (powerRef == null) {
        logger.warning('Failed to get power ref value, skipping this collection cycle');
        throw Exception('SNMP query failed - no valid data');
      }

      final heatTemp = await _queryOid(oidHeatTemp, divisor: 1000);
      if (heatTemp == null) {
        logger.warning('Failed to get heat temp value, skipping this collection cycle');
        throw Exception('SNMP query failed - no valid data');
      }

      final fanSpeed = await _queryOid(oidFanSpeed, divisor: 1);
      if (fanSpeed == null) {
        logger.warning('Failed to get fan speed value, skipping this collection cycle');
        throw Exception('SNMP query failed - no valid data');
      }

      logger.info(
          'SNMP values - Mod: $modulation%, SWR: $swr, PwrOut: ${powerOut}W, PwrRef: ${powerRef}W, Temp: ${heatTemp}°C, Fan: ${fanSpeed}RPM');

      // Determine status and alert level
      String status = 'ON_AIR';
      String? alertLevel;

      if (heatTemp > 90.0 || swr > 3.0) {
        status = 'FAULT';
        alertLevel = 'critical';
      } else if (heatTemp > 75.0 || swr > 1.8) {
        alertLevel = 'warning';
      }

      return TransmitterStats(
        transmitterId: 'KRYZ-TX-001',
        timestamp: DateTime.now(),
        modulation: modulation,
        swr: swr,
        powerOut: powerOut,
        powerRef: powerRef,
        heatTemp: heatTemp,
        fanSpeed: fanSpeed,
        status: status,
        alertLevel: alertLevel,
      );
    } catch (e) {
      logger.warning('SNMP query failed - NOT sending data: $e');
      rethrow; // Don't send zeros, just skip this collection cycle
    }
  }

  /// Query a single SNMP OID and return the value as double, or null if failed
  Future<double?> _queryOid(String oid, {int divisor = 1}) async {
    try {
      final oidObj = snmp.Oid.fromString(oid);
      final message = await _session.get(oidObj);

      if (message.pdu.error.value != 0) {
        logger.warning('SNMP error for OID $oid: ${message.pdu.error}');
        return null; // Return null instead of 0.0 to indicate failure
      }

      final varbind = message.pdu.varbinds.first;

      // Extract the integer value from the varbind
      int intValue = 0;

      if (varbind.value is int) {
        intValue = varbind.value as int;
      } else if (varbind.value is BigInt) {
        intValue = (varbind.value as BigInt).toInt();
      } else {
        logger.warning('Unexpected value type for OID $oid: ${varbind.value.runtimeType}');
        return null; // Return null instead of 0.0 to indicate failure
      }

      final result = intValue / divisor;
      logger.fine('OID $oid = $intValue (raw) / $divisor = $result');
      return result;
    } catch (e) {
      logger.severe('Failed to query OID $oid: $e');
      return null; // Return null instead of 0.0 to indicate failure
    }
  }

  /// Generate simulated stats for testing without actual SNMP device
  TransmitterStats _getSimulatedStats() {
    final now = DateTime.now();
    final random = _random.nextInt(100);

    // Simulate realistic KRYZ transmitter values matching real measurements
    final modulation = 75.0 + (random % 20); // 75-95% (normal range 60-100%)
    final swr = 1.05 + (random % 10) / 100; // 1.05-1.15 (good range, warn >1.5, error >2.0)
    final powerOut = 4500.0 + (random % 1000); // 4500-5500W (typical FM transmitter)
    final powerRef = 20.0 + (random % 30); // 20-50W (reflected power, should be low)
    final heatTemp = 50.0 + (random % 20); // 50-70°C (normal operating temp)
    final fanSpeed = 3000.0 + (random % 500); // 3000-3500 RPM (normal cooling)

    // Determine status and alert level based on realistic thresholds
    String status = 'ON_AIR';
    String? alertLevel;

    // Critical conditions
    if (heatTemp > 85.0 || swr > 2.0 || modulation < 50.0 || modulation > 105.0) {
      status = 'FAULT';
      alertLevel = 'critical';
    }
    // Warning conditions
    else if (heatTemp > 75.0 || swr > 1.5 || modulation < 60.0 || modulation > 100.0 || fanSpeed < 2500.0) {
      alertLevel = 'warning';
    }

    return TransmitterStats(
      transmitterId: 'KRYZ-TX-001',
      timestamp: now,
      modulation: modulation,
      swr: swr,
      powerOut: powerOut,
      powerRef: powerRef,
      heatTemp: heatTemp,
      fanSpeed: fanSpeed,
      status: status,
      alertLevel: alertLevel,
    );
  }

  /// Close SNMP session
  void dispose() {
    _session?.close();
    _session = null;
  }
}
