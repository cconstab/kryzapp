import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:at_client/at_client.dart'
    show
        AtCollection,
        AtClient,
        CItem,
        EventSource,
        SyncProgress,
        SyncProgressListener,
        SyncStatus;
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

  // Keys already fetched (populated during initial scan + periodic poll).
  // Prevents duplicate fetches when _pollNewTierKeys() runs.
  AtCollection<TransmitterStats>? _fiveMinCollection;
  AtCollection<TransmitterStats>? _oneHourCollection;
  StreamSubscription<dynamic>? _fiveMinSub;
  StreamSubscription<dynamic>? _oneHourSub;
  SyncProgressListener? _syncListener;

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
      final keys = await _atClient!.getAtKeys(regex: r'stats\.kryz@');
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
    // Detach any previous listener if re-authenticated.
    if (_syncListener != null && _atClient != null) {
      _atClient!.syncService.removeProgressListener(_syncListener!);
    }
    _collection = collection;
    _atClient = atClient;
    notifyListeners();

    // Open the tier-2/3 collections and stream their items directly —
    // no getAtKeys regex scanning needed.
    _openTierCollections(atClient).ignore();

    // After each sync, call getItems() on both tier collections as a
    // fallback in case collection.updates silently drops an event.
    _syncListener = _ProviderSyncListener((progress) {
      if (progress.syncStatus == SyncStatus.success ||
          progress.syncStatus == SyncStatus.failure) {
        _refreshTierCollections().ignore();
      }
    });
    atClient.syncService.addProgressListener(_syncListener!);

    // Load raw-tier keys already in Hive (up to 10 min old).
    if (!_cacheLoaded) _loadHistoryCached().ignore();
  }

  /// Open the 5-minute and 1-hour tier collections, load existing items, and
  /// subscribe to their [updates] stream for incoming readings.
  Future<void> _openTierCollections(AtClient atClient) async {
    try {
      _fiveMinSub?.cancel();
      _oneHourSub?.cancel();

      _fiveMinCollection = await atClient.collection<TransmitterStats>(
        'stats5m.kryz',
        const Duration(hours: 26),
        fromJson: TransmitterStats.fromJson,
        typeTag: 'TransmitterStats',
        eventSource: EventSource.data,
      );

      _oneHourCollection = await atClient.collection<TransmitterStats>(
        'stats1h.kryz',
        const Duration(days: 8),
        fromJson: TransmitterStats.fromJson,
        typeTag: 'TransmitterStats',
        eventSource: EventSource.data,
      );

      // Load whatever Hive already has (may be empty on first run).
      await _refreshTierCollections();

      // Stream new items as they arrive — fires on Hive writes from sync.
      _fiveMinSub = _fiveMinCollection!.updates.listen(
        (event) async {
          final item =
              await _fiveMinCollection!.getOrNull(event.id, event.owner);
          if (item != null) _cacheAdd(item.obj);
        },
        onError: (Object e) =>
            debugPrint('TransmitterProvider: 5m updates error: $e'),
        cancelOnError: false,
      );

      _oneHourSub = _oneHourCollection!.updates.listen(
        (event) async {
          final item =
              await _oneHourCollection!.getOrNull(event.id, event.owner);
          if (item != null) _cacheAdd(item.obj);
        },
        onError: (Object e) =>
            debugPrint('TransmitterProvider: 1h updates error: $e'),
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('TransmitterProvider._openTierCollections error: $e');
    }
  }

  /// Re-read all items from the tier collections and merge into cache.
  /// [_cacheAdd] deduplicates by (transmitterId, timestamp) so calling
  /// this multiple times is safe and cheap.
  Future<void> _refreshTierCollections() async {
    try {
      if (_fiveMinCollection != null) {
        final items = await _fiveMinCollection!.getItems();
        for (final CItem<TransmitterStats> item in items) {
          _cacheAdd(item.obj);
        }
      }
      if (_oneHourCollection != null) {
        final items = await _oneHourCollection!.getItems();
        for (final CItem<TransmitterStats> item in items) {
          _cacheAdd(item.obj);
        }
      }
    } catch (e) {
      debugPrint('TransmitterProvider._refreshTierCollections error: $e');
    }
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
    _fiveMinSub?.cancel();
    _oneHourSub?.cancel();
    if (_syncListener != null && _atClient != null) {
      _atClient!.syncService.removeProgressListener(_syncListener!);
    }
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

// ── Private helper ────────────────────────────────────────────────────────────
class _ProviderSyncListener extends SyncProgressListener {
  _ProviderSyncListener(this._onProgress);
  final void Function(SyncProgress) _onProgress;

  @override
  void onSyncProgressEvent(SyncProgress syncProgress) =>
      _onProgress(syncProgress);
}
