import 'package:flutter/foundation.dart';
import 'package:kryz_shared/kryz_shared.dart';
import 'dart:async';

class TransmitterProvider extends ChangeNotifier {
  TransmitterStats? _currentStats;
  List<TransmitterStats> _history = [];
  Map<String, dynamic>? _latestAlert;
  Timer? _dataTimeoutTimer;
  bool _isDataStale = false;

  static const int maxHistoryLength = 100;
  static const Duration dataTimeout = Duration(minutes: 1);

  TransmitterStats? get currentStats => _currentStats;
  List<TransmitterStats> get history => _history;
  Map<String, dynamic>? get latestAlert => _latestAlert;
  bool get isDataStale => _isDataStale;

  bool get hasData => _currentStats != null && !_isDataStale;
  bool get isHealthy => _currentStats?.isHealthy ?? false;
  String? get alertLevel => _currentStats?.alertLevel;

  /// Update with new stats from notification
  void updateStats(TransmitterStats stats) {
    _currentStats = stats;
    _isDataStale = false;

    // Reset the timeout timer
    _dataTimeoutTimer?.cancel();
    _dataTimeoutTimer = Timer(dataTimeout, _onDataTimeout);

    // Add to history
    _history.insert(0, stats);

    // Keep history limited
    if (_history.length > maxHistoryLength) {
      _history = _history.take(maxHistoryLength).toList();
    }

    notifyListeners();
  }

  /// Called when no data received for timeout period
  void _onDataTimeout() {
    _isDataStale = true;
    _currentStats = null;

    // Raise an alert
    updateAlert({
      'level': 'critical',
      'message': 'No data received from transmitter for 1 minute. Connection may be lost.',
      'timestamp': DateTime.now().toIso8601String(),
    });

    notifyListeners();
  }

  /// Reset data (e.g., when connection lost)
  void resetData() {
    _dataTimeoutTimer?.cancel();
    _dataTimeoutTimer = null;
    _currentStats = null;
    _isDataStale = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _dataTimeoutTimer?.cancel();
    super.dispose();
  }

  /// Update alert notification
  void updateAlert(Map<String, dynamic> alert) {
    _latestAlert = alert;
    notifyListeners();
  }

  /// Clear alert
  void clearAlert() {
    _latestAlert = null;
    notifyListeners();
  }

  /// Get stats history for a specific metric
  List<double> getMetricHistory(String metric, {int limit = 20}) {
    final values = <double>[];

    for (final stats in _history.take(limit)) {
      switch (metric) {
        case 'modulation':
          values.add(stats.modulation);
          break;
        case 'swr':
          values.add(stats.swr);
          break;
        case 'powerOut':
          values.add(stats.powerOut);
          break;
        case 'powerRef':
          values.add(stats.powerRef);
          break;
        case 'heatTemp':
          values.add(stats.heatTemp);
          break;
        case 'fanSpeed':
          values.add(stats.fanSpeed);
          break;
      }
    }

    return values.reversed.toList();
  }
}
