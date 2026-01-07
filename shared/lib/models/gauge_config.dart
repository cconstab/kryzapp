/// Configuration for gauge display settings
class GaugeConfig {
  final String metricName;
  final double minValue;
  final double maxValue;
  final double warningThreshold;
  final double criticalThreshold;
  final String unit;

  GaugeConfig({
    required this.metricName,
    required this.minValue,
    required this.maxValue,
    required this.warningThreshold,
    required this.criticalThreshold,
    required this.unit,
  });

  Map<String, dynamic> toJson() => {
        'metricName': metricName,
        'minValue': minValue,
        'maxValue': maxValue,
        'warningThreshold': warningThreshold,
        'criticalThreshold': criticalThreshold,
        'unit': unit,
      };

  factory GaugeConfig.fromJson(Map<String, dynamic> json) => GaugeConfig(
        metricName: json['metricName'] as String,
        minValue: (json['minValue'] as num).toDouble(),
        maxValue: (json['maxValue'] as num).toDouble(),
        warningThreshold: (json['warningThreshold'] as num).toDouble(),
        criticalThreshold: (json['criticalThreshold'] as num).toDouble(),
        unit: json['unit'] as String,
      );

  GaugeConfig copyWith({
    String? metricName,
    double? minValue,
    double? maxValue,
    double? warningThreshold,
    double? criticalThreshold,
    String? unit,
  }) {
    return GaugeConfig(
      metricName: metricName ?? this.metricName,
      minValue: minValue ?? this.minValue,
      maxValue: maxValue ?? this.maxValue,
      warningThreshold: warningThreshold ?? this.warningThreshold,
      criticalThreshold: criticalThreshold ?? this.criticalThreshold,
      unit: unit ?? this.unit,
    );
  }

  /// Default configurations for all metrics
  static Map<String, GaugeConfig> getDefaults() {
    return {
      'modulation': GaugeConfig(
        metricName: 'modulation',
        minValue: 0,
        maxValue: 100,
        warningThreshold: 95,
        criticalThreshold: 98,
        unit: '%',
      ),
      'swr': GaugeConfig(
        metricName: 'swr',
        minValue: 1.0,
        maxValue: 5.0,
        warningThreshold: 1.8,
        criticalThreshold: 3.0,
        unit: ':1',
      ),
      'powerOut': GaugeConfig(
        metricName: 'powerOut',
        minValue: 0,
        maxValue: 6000,
        warningThreshold: 5000,
        criticalThreshold: 5500,
        unit: 'W',
      ),
      'powerRef': GaugeConfig(
        metricName: 'powerRef',
        minValue: 0,
        maxValue: 200,
        warningThreshold: 100,
        criticalThreshold: 150,
        unit: 'W',
      ),
      'heatTemp': GaugeConfig(
        metricName: 'heatTemp',
        minValue: 0,
        maxValue: 120,
        warningThreshold: 75,
        criticalThreshold: 90,
        unit: '°C',
      ),
      'fanSpeed': GaugeConfig(
        metricName: 'fanSpeed',
        minValue: 0,
        maxValue: 5000,
        warningThreshold: 4000,
        criticalThreshold: 4500,
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
