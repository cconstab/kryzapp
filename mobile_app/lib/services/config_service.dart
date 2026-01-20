import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:kryz_shared/kryz_shared.dart';
import 'package:logging/logging.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'dart:async';

final logger = Logger('ConfigService');

class ConfigService extends ChangeNotifier {
  static const String _atKeyName = 'kryz_dashboard_config';

  DashboardConfig? _currentConfig;
  AtClient? _atClient;
  StreamSubscription? _notificationSubscription;

  DashboardConfig get config => _currentConfig ?? DashboardConfig.defaults();

  @override
  void dispose() {
    _notificationSubscription?.cancel();
    super.dispose();
  }

  /// Initialize with AtClient for syncing
  void setAtClient(AtClient? atClient) {
    _atClient = atClient;
    
    // Subscribe to config notifications when connected
    if (_atClient != null) {
      _subscribeToConfigNotifications();
    } else {
      _unsubscribeFromNotifications();
    }
  }

  /// Subscribe to config update notifications
  void _subscribeToConfigNotifications() {
    _notificationSubscription?.cancel();

    if (_atClient == null) return;

    try {
      logger.info('Subscribing to configuration update notifications');
      
      _notificationSubscription = _atClient!.notificationService
          .subscribe(regex: '.*$_atKeyName.*', shouldDecrypt: true)
          .listen(
        (notification) async {
          try {
            logger.info('Received config update notification');
            
            // Reload the config from atProtocol
            final updatedConfig = await _loadFromAtProtocol();
            if (updatedConfig != null && _currentConfig != null) {
              // Check what changed
              if (updatedConfig.stationName != _currentConfig!.stationName) {
                logger.info('Station name updated: ${_currentConfig!.stationName} → ${updatedConfig.stationName}');
              }
              
              _currentConfig = updatedConfig;
              notifyListeners();
            }
          } catch (e) {
            logger.warning('Error handling config notification: $e');
          }
        },
        onError: (error) {
          logger.warning('Config notification stream error: $error');
        },
        cancelOnError: false,
      );
    } catch (e) {
      logger.severe('Failed to subscribe to config notifications: $e');
    }
  }

  /// Unsubscribe from notifications
  void _unsubscribeFromNotifications() {
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
  }

  /// Load configuration - from atProtocol if available, otherwise use defaults
  Future<void> loadConfig() async {
    try {
      // Try loading from atProtocol if connected
      if (_atClient != null) {
        final atConfig = await _loadFromAtProtocol();
        if (atConfig != null) {
          _currentConfig = atConfig;
          notifyListeners();
          return;
        }
      }

      // Use defaults if nothing saved yet
      _currentConfig = DashboardConfig.defaults();
      logger.info('Using default configuration');

      // Save defaults to atProtocol for next time
      if (_atClient != null) {
        await _saveToAtProtocol(_currentConfig!);
      }
      notifyListeners();
    } catch (e) {
      logger.severe('Failed to load configuration: $e');
      _currentConfig = DashboardConfig.defaults();
      notifyListeners();
    }
  }

  /// Save configuration to atProtocol
  Future<void> saveConfig(DashboardConfig config) async {
    try {
      _currentConfig = config;

      // Save to atProtocol if available
      if (_atClient != null) {
        await _saveToAtProtocol(config);
        logger.info('Configuration saved to atProtocol');
      } else {
        logger.info('Configuration cached (will sync when connected)');
      }
      notifyListeners();
    } catch (e) {
      logger.severe('Failed to save configuration: $e');
      rethrow;
    }
  }

  /// Save configuration to atProtocol
  Future<void> _saveToAtProtocol(DashboardConfig config) async {
    try {
      if (_atClient == null) return;

      final currentAtSign = _atClient!.getCurrentAtSign();
      if (currentAtSign == null) return;

      // Use a shared key (shared with ourselves) to trigger notifications
      final atKey = AtKey()
        ..key = _atKeyName
        ..sharedWith = currentAtSign // Share with ourselves to trigger notifications
        ..metadata = (Metadata()
          ..ttr = -1 // Never expire
          ..ccd = true); // Send notification on change

      final jsonString = jsonEncode(config.toJson());
      await _atClient!.put(atKey, jsonString);
    } catch (e) {
      logger.warning('Failed to save to atProtocol: $e');
      rethrow;
    }
  }

  /// Load configuration from atProtocol
  Future<DashboardConfig?> _loadFromAtProtocol() async {
    try {
      if (_atClient == null) return null;

      final currentAtSign = _atClient!.getCurrentAtSign();
      if (currentAtSign == null) return null;

      final atKey = AtKey()
        ..key = _atKeyName
        ..sharedWith = currentAtSign; // Match the save format

      final result = await _atClient!.get(atKey);
      if (result.value == null) return null;

      final jsonData = jsonDecode(result.value) as Map<String, dynamic>;
      return DashboardConfig.fromJson(jsonData);
    } catch (e) {
      logger.warning('Failed to load from atProtocol: $e');
      return null;
    }
  }

  /// Export configuration as JSON string (for manual backup)
  String exportConfigAsJson() {
    final jsonData = config.toJson();
    return const JsonEncoder.withIndent('  ').convert(jsonData);
  }

  /// Import configuration from JSON string (for manual restore)
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
  Future<void> updateGaugeConfig(
      String metricName, GaugeConfig newConfig) async {
    final gauges = Map<String, GaugeConfig>.from(config.gauges);
    gauges[metricName] = newConfig;
    final newDashboardConfig = DashboardConfig(
      gauges: gauges,
      stationName: config.stationName,
    );
    await saveConfig(newDashboardConfig);
  }

  /// Reset to default configuration
  Future<void> resetToDefaults() async {
    final defaultConfig = DashboardConfig.defaults();
    await saveConfig(defaultConfig);
  }
}
