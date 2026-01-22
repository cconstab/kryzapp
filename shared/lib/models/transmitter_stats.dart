/// Data model for transmitter statistics
class TransmitterStats {
  final String transmitterId;
  final String stationName; // Station name/call sign
  final DateTime timestamp;
  final double modulation; // Modulation percentage (%)
  final double swr; // Standing Wave Ratio
  final double powerOut; // Power Output (Watts)
  final double powerRef; // Power Reflected (Watts)
  final double heatTemp; // Heat Sink Temperature (°C)
  final double fanSpeed; // Fan Speed (RPM)
  final String status; // ON_AIR, STANDBY, FAULT
  final String? alertLevel; // Optional alert level

  TransmitterStats({
    required this.transmitterId,
    required this.stationName,
    required this.timestamp,
    required this.modulation,
    required this.swr,
    required this.powerOut,
    required this.powerRef,
    required this.heatTemp,
    required this.fanSpeed,
    required this.status,
    this.alertLevel,
  });

  /// Convert to JSON for atPlatform transmission
  Map<String, dynamic> toJson() {
    return {
      'transmitterId': transmitterId,
      'stationName': stationName,
      'timestamp': timestamp.toIso8601String(),
      'modulation': modulation,
      'swr': swr,
      'powerOut': powerOut,
      'powerRef': powerRef,
      'heatTemp': heatTemp,
      'fanSpeed': fanSpeed,
      'status': status,
      'alertLevel': alertLevel,
    };
  }

  /// Create from JSON received via atPlatform
  factory TransmitterStats.fromJson(Map<String, dynamic> json) {
    return TransmitterStats(
      transmitterId: json['transmitterId'] as String,
      stationName: json['stationName'] as String? ?? json['transmitterId'] as String, // Fallback to transmitterId
      timestamp: DateTime.parse(json['timestamp'] as String),
      modulation: (json['modulation'] as num).toDouble(),
      swr: (json['swr'] as num).toDouble(),
      powerOut: (json['powerOut'] as num).toDouble(),
      powerRef: (json['powerRef'] as num).toDouble(),
      heatTemp: (json['heatTemp'] as num).toDouble(),
      fanSpeed: (json['fanSpeed'] as num).toDouble(),
      status: json['status'] as String,
      alertLevel: json['alertLevel'] as String?,
    );
  }

  @override
  String toString() {
    return 'TransmitterStats(id: $transmitterId, powerOut: ${powerOut}W, powerRef: ${powerRef}W, '
        'swr: $swr, modulation: $modulation%, heatTemp: ${heatTemp}°C, fanSpeed: ${fanSpeed}RPM, status: $status)';
  }

  /// Check if transmitter is in healthy state
  bool get isHealthy {
    return status == 'ON_AIR' &&
        heatTemp < 80.0 && // Below 80°C
        swr < 2.0 && // SWR below 2:1
        powerOut > 0;
  }

  /// Calculate alert level: null (ok), 'warning', 'critical'
  String? calculateAlertLevel() {
    if (status == 'FAULT') return 'critical';
    if (heatTemp > 90.0) return 'critical';
    if (swr > 3.0) return 'critical';
    if (heatTemp > 75.0) return 'warning';
    if (swr > 1.8) return 'warning';
    return null;
  }
}
