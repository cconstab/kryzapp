import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:at_client/at_client.dart' show AtCollection, AtClient;
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

  // ── In-memory history cache ─────────────────────────────────────────────────
  // Sorted oldest→newest, maintained by background loader + live updates.
  final List<TransmitterStats> _historyCache = [];
  bool _historyCacheLoading = false;
  bool _cacheLoaded = false;
  final _historyController =
      StreamController<List<TransmitterStats>>.broadcast();
  AtClient? _atClient;

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

  /// Insert [stats] into the sorted in-memory cache and push an update to the
  /// history stream.  Safe to call from any context (background loader or
  /// live-reading callback).
  void _cacheAdd(TransmitterStats stats) {
    final cutoff7d = DateTime.now().subtract(const Duration(days: 7));
    _historyCache.removeWhere((s) => s.timestamp.isBefore(cutoff7d));
    // Skip exact duplicates (same transmitter, same timestamp).
    if (_historyCache.any((s) =>
        s.timestamp == stats.timestamp &&
        s.transmitterId == stats.transmitterId)) return;
    final idx =
        _historyCache.indexWhere((s) => s.timestamp.isAfter(stats.timestamp));
    if (idx == -1) {
      _historyCache.add(stats);
    } else {
      _historyCache.insert(idx, stats);
    }
    // Push a snapshot to any open StreamBuilders.
    if (!_historyController.isClosed) {
      _historyController.add(List.unmodifiable(_historyCache));
    }
  }

  /// Background loader — reads all stats keys from Hive sequentially,
  /// collecting into a local list then merging in one pass at the end.
  ///
  /// Sequential reads with a yield every 10 keys ensures Flutter's event loop
  /// can fire collection.updates callbacks between groups.  Future.wait(N)
  /// drains as microtasks and blocks the event queue, silencing live events.
  ///
  /// Protected by [_cacheLoaded]: runs only once per app session.
  Future<void> _loadHistoryCached() async {
    if (_atClient == null || _historyCacheLoading || _cacheLoaded) return;
    _historyCacheLoading = true;
    try {
      final keys = await _atClient!.getAtKeys(regex: r'stats(1m|30m)?\.kryz@');
      final cutoff7d = DateTime.now().subtract(const Duration(days: 7));
      final incoming = <TransmitterStats>[];

      for (var i = 0; i < keys.length; i++) {
        try {
          final val = await _atClient!.get(keys[i]);
          if (val.value != null) {
            final env = jsonDecode(val.value as String) as Map<String, dynamic>;
            if (env['type'] == 'TransmitterStats') {
              final stats =
                  TransmitterStats.fromJson(env['obj'] as Map<String, dynamic>);
              if (stats.timestamp.isAfter(cutoff7d)) incoming.add(stats);
            }
          }
        } catch (_) {}
        // Yield every 10 keys: forces a macrotask boundary so live events fire.
        if (i % 10 == 9) {
          await Future.delayed(Duration.zero);
        }
      }
      await Future.delayed(Duration.zero); // final yield

      // Sort, deduplicate, merge with any live readings already in cache.
      incoming.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final seen = <String>{};
      final merged = <TransmitterStats>[];
      for (final s in [..._historyCache, ...incoming]) {
        if (!s.timestamp.isAfter(cutoff7d)) continue;
        final key = '${s.transmitterId}|${s.timestamp.microsecondsSinceEpoch}';
        if (seen.add(key)) merged.add(s);
      }
      merged.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      _historyCache
        ..clear()
        ..addAll(merged);

      _cacheLoaded = true;
      // Single emit with the complete, sorted dataset.
      if (!_historyController.isClosed) {
        _historyController.add(List.unmodifiable(_historyCache));
      }
    } catch (e) {
      debugPrint('TransmitterProvider._loadHistoryCached error: $e');
    } finally {
      _historyCacheLoading = false;
    }
  }

  /// Called by [DashboardScreen] once [AtService.onCollectionReady] fires.
  /// Passing [atClient] enables the background history loader.
  void setCollection(
      AtCollection<TransmitterStats> collection, AtClient atClient) {
    _collection = collection;
    _atClient = atClient;
    notifyListeners();
    // Start progressive background load — runs once; _cacheLoaded guards re-runs.
    if (!_cacheLoaded) _loadHistoryCached().ignore();
  }

  /// Stream of readings within [window] from now, sorted oldest→newest.
  ///
  /// Yields the current cache immediately so charts are populated on first
  /// build, then yields updated snapshots as the background loader fills in
  /// history and as live readings arrive via [updateStats].
  Stream<List<TransmitterStats>> historyStream(Duration window) async* {
    // Immediate snapshot (may be empty if collection not yet set or load just
    // started — the stream will push again as data arrives).
    final cutoff = DateTime.now().subtract(window);
    yield _historyCache.where((s) => s.timestamp.isAfter(cutoff)).toList();
    // Forward every cache update, re-filtering to the requested window.
    yield* _historyController.stream.map((all) {
      final c = DateTime.now().subtract(window);
      return all.where((s) => s.timestamp.isAfter(c)).toList();
    });
  }

  /// Update with new stats from the collection's updates stream.
  void updateStats(TransmitterStats stats) {
    _currentStats = stats;
    _isDataStale = false;

    _dataTimeoutTimer?.cancel();
    _dataTimeoutTimer = Timer(dataTimeout, _onDataTimeout);

    _history.insert(0, stats);
    if (_history.length > maxHistoryLength) {
      _history = _history.take(maxHistoryLength).toList();
    }

    // Add to the long-term history cache so charts include this reading.
    _cacheAdd(stats);

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
    _historyController.close();
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
