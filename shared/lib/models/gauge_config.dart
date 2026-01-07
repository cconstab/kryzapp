/// Configuration for gauge display settings
class GaugeConfig {
  final String metricName;
  final double minValue;
  final double maxValue;

  // High-side thresholds (for values that are bad when too high)
  final double? warningHighThreshold;
  final double? criticalHighThreshold;

  // Low-side thresholds (for values that are bad when too low)
  final double? warningLowThreshold;
  final double? criticalLowThreshold;

  final String unit;

  GaugeConfig({
    required this.metricName,
    required this.minValue,
    required this.maxValue,
    this.warningHighThreshold,
    this.criticalHighThreshold,
    this.warningLowThreshold,
    this.criticalLowThreshold,
    required this.unit,
  });

  Map<String, dynamic> toJson() => {
        'metricName': metricName,
        'minValue': minValue,
        'maxValue': maxValue,
        'warningHighThreshold': warningHighThreshold,
        'criticalHighThreshold': criticalHighThreshold,
        'warningLowThreshold': warningLowThreshold,
        'criticalLowThreshold': criticalLowThreshold,
        'unit': unit,
      };

  factory GaugeConfig.fromJson(Map<String, dynamic> json) => GaugeConfig(
        metricName: json['metricName'] as String,
        minValue: (json['minValue'] as num).toDouble(),
        maxValue: (json['maxValue'] as num).toDouble(),
        warningHighThreshold:
            json['warningHighThreshold'] != null ? (json['warningHighThreshold'] as num).toDouble() : null,
        criticalHighThreshold:
            json['criticalHighThreshold'] != null ? (json['criticalHighThreshold'] as num).toDouble() : null,
        warningLowThreshold:
            json['warningLowThreshold'] != null ? (json['warningLowThreshold'] as num).toDouble() : null,
        criticalLowThreshold:
            json['criticalLowThreshold'] != null ? (json['criticalLowThreshold'] as num).toDouble() : null,
        unit: json['unit'] as String,
      );

  GaugeConfig copyWith({
    String? metricName,
    double? minValue,
    double? maxValue,
    double? warningHighThreshold,
    double? criticalHighThreshold,
    double? warningLowThreshold,
    double? criticalLowThreshold,
    String? unit,
  }) {
    return GaugeConfig(
      metricName: metricName ?? this.metricName,
      minValue: minValue ?? this.minValue,
      maxValue: maxValue ?? this.maxValue,
      warningHighThreshold: warningHighThreshold ?? this.warningHighThreshold,
      criticalHighThreshold: criticalHighThreshold ?? this.criticalHighThreshold,
      warningLowThreshold: warningLowThreshold ?? this.warningLowThreshold,
      criticalLowThreshold: criticalLowThreshold ?? this.criticalLowThreshold,
      unit: unit ?? this.unit,
    );
  }

  /// Default configurations for all metrics
  static Map<String, GaugeConfig> getDefaults() {
    return {
      'modulation': GaugeConfig(
        metricName: 'modulation',
        minValue: 0.0,
        maxValue: 120.0,
        warningLowThreshold: 60.0,
        criticalLowThreshold: 50.0,
        warningHighThreshold: 104.0,
        criticalHighThreshold: 105.0,
        unit: '%',
      ),
      'swr': GaugeConfig(
        metricName: 'swr',
        minValue: 1.0,
        maxValue: 3.5,
        warningLowThreshold: null,
        criticalLowThreshold: null,
        warningHighThreshold: 2.0,
        criticalHighThreshold: 2.5,
        unit: ':1',
      ),
      'powerOut': GaugeConfig(
        metricName: 'powerOut',
        minValue: 0.0,
        maxValue: 20.0,
        warningLowThreshold: 8.0,
        criticalLowThreshold: 5.0,
        warningHighThreshold: 12.0,
        criticalHighThreshold: 15.0,
        unit: 'W',
      ),
      'powerRef': GaugeConfig(
        metricName: 'powerRef',
        minValue: 0.0,
        maxValue: 5.0,
        warningLowThreshold: null,
        criticalLowThreshold: null,
        warningHighThreshold: 1.0,
        criticalHighThreshold: 2.0,
        unit: 'W',
      ),
      'heatTemp': GaugeConfig(
        metricName: 'heatTemp',
        minValue: 0.0,
        maxValue: 100.0,
        warningLowThreshold: 15.0,
        criticalLowThreshold: 10.0,
        warningHighThreshold: 75.0,
        criticalHighThreshold: 90.0,
        unit: '°C',
      ),
      'fanSpeed': GaugeConfig(
        metricName: 'fanSpeed',
        minValue: 0.0,
        maxValue: 10000.0,
        warningLowThreshold: 6000.0,
        criticalLowThreshold: 4000.0,
        warningHighThreshold: 8000.0,
        criticalHighThreshold: 8500.0,
        unit: 'RPM',
      ),
    };
  }
}

/// Container for all gauge configurations
class DashboardConfig {
  final Map<String, GaugeConfig> gauges;

  DashboardConfig({required this.gauges});

  Map<String, dynamic> toJson() => {
        'gauges': gauges.map((key, value) => MapEntry(key, value.toJson())),
      };

  factory DashboardConfig.fromJson(Map<String, dynamic> json) {
    final gaugesJson = json['gauges'] as Map<String, dynamic>;
    final gauges = gaugesJson.map(
      (key, value) => MapEntry(key, GaugeConfig.fromJson(value as Map<String, dynamic>)),
    );
    return DashboardConfig(gauges: gauges);
  }

  factory DashboardConfig.defaults() {
    return DashboardConfig(gauges: GaugeConfig.getDefaults());
  }

  GaugeConfig getConfig(String metricName) {
    return gauges[metricName] ?? GaugeConfig.getDefaults()[metricName]!;
  }
}
