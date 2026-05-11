import 'package:flutter/foundation.dart';
import 'package:at_client/at_client.dart' show AtCollection, CItem;
import 'package:kryz_shared/kryz_shared.dart';
import 'dart:async';

class TransmitterProvider extends ChangeNotifier {
  TransmitterStats? _currentStats;
  List<TransmitterStats> _history = [];
  Map<String, dynamic>? _latestAlert;
  Timer? _dataTimeoutTimer;
  bool _isDataStale = false;

  // Injected after authentication — used for historical queries in MetricsScreen
  AtCollection<TransmitterStats>? _collection;

  static const int maxHistoryLength = 100;
  static const Duration dataTimeout = Duration(minutes: 1);

  TransmitterStats? get currentStats => _currentStats;
  List<TransmitterStats> get history => _history;
  Map<String, dynamic>? get latestAlert => _latestAlert;
  bool get isDataStale => _isDataStale;
  bool get hasCollection => _collection != null;

  bool get hasData => _currentStats != null && !_isDataStale;
  bool get isHealthy => _currentStats?.isHealthy ?? false;
  String? get alertLevel => _currentStats?.alertLevel;

  /// Called by [DashboardScreen] once [AtService.onCollectionReady] fires.
  /// The collection is then available for historical queries via [historyStream]
  /// and [historySnapshot].
  void setCollection(AtCollection<TransmitterStats> collection) {
    _collection = collection;
    notifyListeners();
  }

  /// Live stream of readings within [window] from now, sorted oldest→newest.
  ///
  /// Uses the [AtCollection] query engine which performs incremental delta
  /// maintenance — each new collector reading triggers a single-item update,
  /// not a full re-scan.  Returns an empty stream if no collection is set yet.
  Stream<List<CItem<TransmitterStats>>> historyStream(Duration window) {
    if (_collection == null) return const Stream.empty();
    final cutoff = DateTime.now().subtract(window);
    return _collection!
        .query()
        .where((item) => item.obj.timestamp.isAfter(cutoff))
        .orderBy((item) => item.obj.timestamp)
        .watch();
  }

  /// One-shot snapshot of readings within [window] from now, sorted oldest→newest.
  Future<List<CItem<TransmitterStats>>> historySnapshot(Duration window) async {
    if (_collection == null) return [];
    final cutoff = DateTime.now().subtract(window);
    return _collection!
        .query()
        .where((item) => item.obj.timestamp.isAfter(cutoff))
        .orderBy((item) => item.obj.timestamp)
        .get();
  }

  /// Update with new stats from the collection's updates stream.
  ///
  /// This automatically clears the stale flag and resets the timeout timer,
  /// enabling automatic recovery when data resumes after a timeout.
  void updateStats(TransmitterStats stats) {
    _currentStats = stats;
    _isDataStale = false;

    _dataTimeoutTimer?.cancel();
    _dataTimeoutTimer = Timer(dataTimeout, _onDataTimeout);

    _history.insert(0, stats);
    if (_history.length > maxHistoryLength) {
      _history = _history.take(maxHistoryLength).toList();
    }

    notifyListeners();
  }

  void _onDataTimeout() {
    _isDataStale = true;
    _currentStats = null;

    updateAlert({
      'level': 'critical',
      'message':
          'No data received from transmitter for 1 minute. Connection may be lost.',
      'timestamp': DateTime.now().toIso8601String(),
    });

    notifyListeners();
  }

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

  void updateAlert(Map<String, dynamic> alert) {
    _latestAlert = alert;
    notifyListeners();
  }

  void clearAlert() {
    _latestAlert = null;
    notifyListeners();
  }

  /// Get stats history for a specific metric (from in-memory buffer).
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
