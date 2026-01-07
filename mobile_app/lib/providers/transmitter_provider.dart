import 'package:flutter/foundation.dart';
import 'package:kryz_shared/kryz_shared.dart';

class TransmitterProvider extends ChangeNotifier {
  TransmitterStats? _currentStats;
  List<TransmitterStats> _history = [];
  Map<String, dynamic>? _latestAlert;

  static const int maxHistoryLength = 100;

  TransmitterStats? get currentStats => _currentStats;
  List<TransmitterStats> get history => _history;
  Map<String, dynamic>? get latestAlert => _latestAlert;

  bool get hasData => _currentStats != null;
  bool get isHealthy => _currentStats?.isHealthy ?? false;
  String? get alertLevel => _currentStats?.alertLevel;

  /// Update with new stats from notification
  void updateStats(TransmitterStats stats) {
    _currentStats = stats;

    // Add to history
    _history.insert(0, stats);

    // Keep history limited
    if (_history.length > maxHistoryLength) {
      _history = _history.take(maxHistoryLength).toList();
    }

    notifyListeners();
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
