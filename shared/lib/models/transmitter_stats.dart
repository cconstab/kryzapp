/// Data model for transmitter statistics
class TransmitterStats {
  final String transmitterId;
  final DateTime timestamp;
  final double powerOutput; // Watts
  final double temperature; // Celsius
  final double vswr; // Voltage Standing Wave Ratio
  final double frequency; // MHz
  final String status; // ON_AIR, STANDBY, FAULT
  final Map<String, dynamic>? additionalMetrics;

  TransmitterStats({
    required this.transmitterId,
    required this.timestamp,
    required this.powerOutput,
    required this.temperature,
    required this.vswr,
    required this.frequency,
    required this.status,
    this.additionalMetrics,
  });

  /// Convert to JSON for atPlatform transmission
  Map<String, dynamic> toJson() {
    return {
      'transmitterId': transmitterId,
      'timestamp': timestamp.toIso8601String(),
      'powerOutput': powerOutput,
      'temperature': temperature,
      'vswr': vswr,
      'frequency': frequency,
      'status': status,
      'additionalMetrics': additionalMetrics,
    };
  }

  /// Create from JSON received via atPlatform
  factory TransmitterStats.fromJson(Map<String, dynamic> json) {
    return TransmitterStats(
      transmitterId: json['transmitterId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      powerOutput: (json['powerOutput'] as num).toDouble(),
      temperature: (json['temperature'] as num).toDouble(),
      vswr: (json['vswr'] as num).toDouble(),
      frequency: (json['frequency'] as num).toDouble(),
      status: json['status'] as String,
      additionalMetrics: json['additionalMetrics'] as Map<String, dynamic>?,
    );
  }

  @override
  String toString() {
    return 'TransmitterStats(id: $transmitterId, power: ${powerOutput}W, '
        'temp: ${temperature}°C, vswr: $vswr, freq: ${frequency}MHz, status: $status)';
  }

  /// Check if transmitter is in healthy state
  bool get isHealthy {
    return status == 'ON_AIR' &&
        temperature < 80.0 && // Below 80°C
        vswr < 2.0 && // VSWR below 2:1
        powerOutput > 0;
  }

  /// Get alert level: null (ok), 'warning', 'critical'
  String? get alertLevel {
    if (status == 'FAULT') return 'critical';
    if (temperature > 90.0) return 'critical';
    if (vswr > 3.0) return 'critical';
    if (temperature > 75.0) return 'warning';
    if (vswr > 1.8) return 'warning';
    return null;
  }
}
