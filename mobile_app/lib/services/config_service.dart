import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:kryz_shared/kryz_shared.dart';
import 'package:logging/logging.dart';

final logger = Logger('ConfigService');

class ConfigService {
  static const String _configFileName = 'dashboard_config.json';
  DashboardConfig? _currentConfig;

  DashboardConfig get config => _currentConfig ?? DashboardConfig.defaults();

  /// Load configuration from file
  Future<void> loadConfig() async {
    try {
      final file = await _getConfigFile();

      if (await file.exists()) {
        final jsonString = await file.readAsString();
        final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
        _currentConfig = DashboardConfig.fromJson(jsonData);
        logger.info('Configuration loaded from file');
      } else {
        _currentConfig = DashboardConfig.defaults();
        await saveConfig(_currentConfig!);
        logger.info('Created default configuration');
      }
    } catch (e) {
      logger.severe('Failed to load configuration: $e');
      _currentConfig = DashboardConfig.defaults();
    }
  }

  /// Save configuration to file
  Future<void> saveConfig(DashboardConfig config) async {
    try {
      final file = await _getConfigFile();
      final jsonString = jsonEncode(config.toJson());
      await file.writeAsString(jsonString);
      _currentConfig = config;
      logger.info('Configuration saved to file');
    } catch (e) {
      logger.severe('Failed to save configuration: $e');
      rethrow;
    }
  }

  /// Export configuration as JSON string
  String exportConfigAsJson() {
    final jsonData = config.toJson();
    return const JsonEncoder.withIndent('  ').convert(jsonData);
  }

  /// Import configuration from JSON string
  Future<DashboardConfig> importConfigFromJson(String jsonString) async {
    try {
      final jsonData = jsonDecode(jsonString) as Map<String, dynamic>;
      final newConfig = DashboardConfig.fromJson(jsonData);
      await saveConfig(newConfig);
      return newConfig;
    } catch (e) {
      logger.severe('Failed to import configuration: $e');
      rethrow;
    }
  }

  /// Update a single gauge configuration
  Future<void> updateGaugeConfig(String metricName, GaugeConfig newConfig) async {
    final gauges = Map<String, GaugeConfig>.from(config.gauges);
    gauges[metricName] = newConfig;
    final newDashboardConfig = DashboardConfig(gauges: gauges);
    await saveConfig(newDashboardConfig);
  }

  /// Reset to default configuration
  Future<void> resetToDefaults() async {
    final defaultConfig = DashboardConfig.defaults();
    await saveConfig(defaultConfig);
  }

  /// Get configuration file
  Future<File> _getConfigFile() async {
    final directory = await getApplicationDocumentsDirectory();
    return File('${directory.path}/$_configFileName');
  }

  /// Get configuration file path for display
  Future<String> getConfigFilePath() async {
    final file = await _getConfigFile();
    return file.path;
  }
}
