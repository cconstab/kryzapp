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
  final _historyController =
      StreamController<List<TransmitterStats>>.broadcast();

  // Live stream — emits individual new readings once history is fully loaded.
  // Chart widgets subscribe here for incremental appends so they don't need
  // to rebuild the full dataset on every 2-second raw reading.
  final _liveController = StreamController<TransmitterStats>.broadcast();

  // Set to true after the first _loadHistoryCached completes.  Until then,
  // every _cacheAdd emits a full snapshot via _historyController so charts
  // populate correctly during the initial catch-up sweep.
  bool _historyLoaded = false;

  // Progress of the current history load: null = idle, 0.0–1.0 = loading.
  // Uses a ValueNotifier so the progress bar can update cheaply without
  // triggering full widget-tree rebuilds via notifyListeners().
  final historyLoadProgress = ValueNotifier<double?>(null);

  AtClient? _atClient;

  // Tier collections — used only for the catch-up `getItems()` sweep that
  // runs after each sync.  Live updates arrive via the raw notification
  // subscriptions below: in at_client 3.12.0-rc.2 `AtCollection.updates` →
  // `getOrNull(id, owner)` round-trips fail for cached recipient-side keys
  // (the cached key carries a `cached:<receiver>:` two-segment prefix but
  // the lookup regex only tolerates one prefix segment), so charts would
  // sit empty until each sync rewrote keys in single-prefix form.  Raw
  // `notificationService.subscribe` delivers each new average in ms.
  AtCollection<TransmitterStats>? _fiveMinColl;
  AtCollection<TransmitterStats>? _oneHourColl;
  StreamSubscription<dynamic>? _fiveMinNotifSub;
  StreamSubscription<dynamic>? _oneHourNotifSub;
  SyncProgressListener? _syncListener;

  // Keys whose raw-tier values have been loaded into _historyCache
  // (toString() of AtKey).  Used by _pollNewRawKeys to find genuinely new
  // keys without re-fetching the entire 7-day history on every sync.
  final Set<String> _scannedKeys = {};

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

  /// Single-point updates for chart widgets to append incrementally.
  /// Only populated after the initial history load completes.
  Stream<TransmitterStats> get liveStream => _liveController.stream;

  /// Insert [stats] into the sorted in-memory cache and optionally emit an
  /// update.
  ///
  /// [live] — true for real-time single readings (raw 2-second stats from the
  ///   collector).  Once the initial history load is complete these are emitted
  ///   via [_liveController] so chart widgets can append a single point without
  ///   rebuilding the entire dataset.  Before history is loaded they fall back
  ///   to a full snapshot so the chart is not stuck empty.
  ///
  /// [broadcast] — false suppresses any emission; callers that process many
  ///   items in a loop (e.g. [_refreshTierCollections]) set this to false and
  ///   emit one snapshot at the end, avoiding N consecutive full-list broadcasts.
  void _cacheAdd(TransmitterStats stats,
      {bool live = false, bool broadcast = true}) {
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
    if (!broadcast) return;
    if (live && _historyLoaded) {
      // History is stable — emit just this point so charts append incrementally.
      if (!_liveController.isClosed) _liveController.add(stats);
    } else {
      // During initial load or tier catch-up: emit the full sorted snapshot.
      if (!_historyController.isClosed) {
        _historyController.add(List.unmodifiable(_historyCache));
      }
    }
  }

  /// Background loader — reads every cached stats key (raw / 5m / 1h tiers)
  /// from Hive sequentially, collecting into a local list then merging in
  /// one pass at the end.
  ///
  /// The regex matches all three namespaces in one scan and tolerates the
  /// `cached:` prefix the SDK adds to receiver-side notification copies.
  ///
  /// Sequential reads with a yield every 10 keys ensures Flutter's event
  /// loop can fire notification callbacks between groups.
  ///
  /// May be called multiple times (e.g. once on startup, then again after
  /// each sync completes) — `_historyCacheLoading` prevents overlapping
  /// runs and `_cacheAdd` deduplicates new readings against the existing
  /// cache, so repeat invocations are cheap and idempotent.
  Future<void> _loadHistoryCached() async {
    if (_atClient == null || _historyCacheLoading) return;
    _historyCacheLoading = true;
    historyLoadProgress.value = 0.0;
    try {
      // Matches:  [cached:][<receiver>:]<id>.stats[5m|1h].kryz@<sender>
      final keys = await _atClient!.getAtKeys(regex: r'stats(5m|1h)?\.kryz@');
      debugPrint('TransmitterProvider: history scan found ${keys.length} keys');
      if (keys.isNotEmpty) {
        debugPrint('  sample keys:');
        for (final k in keys.take(5)) {
          debugPrint('    ${k.toString()}');
        }
      }

      final cutoff7d = DateTime.now().subtract(const Duration(days: 7));
      final incoming = <TransmitterStats>[];
      var decoded = 0;
      var nullValue = 0;
      var decodeErr = 0;

      // Fetch keys in parallel batches to avoid hundreds of serial Hive
      // round-trips, which is the main cause of slow 7-day history loading.
      // A batch of 20 is large enough to amortise per-call overhead but small
      // enough that we yield between batches and live notifications still fire.
      const batchSize = 20;
      for (var i = 0; i < keys.length; i += batchSize) {
        final batch = keys.sublist(i, (i + batchSize).clamp(0, keys.length));
        // Record keys as scanned before fetching so _pollNewRawKeys skips them
        // even if the fetch fails.
        for (final k in batch) {
          _scannedKeys.add(k.toString());
        }
        final results = await Future.wait(
          batch.map((key) async {
            try {
              return await _atClient!.get(key);
            } catch (e) {
              return null;
            }
          }),
        );
        for (var j = 0; j < batch.length; j++) {
          final val = results[j];
          if (val == null) {
            decodeErr++;
            if (decodeErr <= 3) {
              debugPrint('  get error for ${batch[j]}');
            }
            continue;
          }
          if (val.value == null) {
            nullValue++;
          } else {
            try {
              final env =
                  jsonDecode(val.value as String) as Map<String, dynamic>;
              if (env['type'] == 'TransmitterStats') {
                final stats = TransmitterStats.fromJson(
                    env['obj'] as Map<String, dynamic>);
                decoded++;
                if (stats.timestamp.isAfter(cutoff7d)) incoming.add(stats);
              }
            } catch (e) {
              decodeErr++;
              if (decodeErr <= 3) {
                debugPrint('  decode error for ${batch[j]}: $e');
              }
            }
          }
        }
        // Yield between batches so live notification callbacks can fire.
        await Future.delayed(Duration.zero);
        // Report progress (clamp to avoid floating-point overshoot).
        historyLoadProgress.value =
            ((i + batchSize) / keys.length).clamp(0.0, 1.0);
      }

      debugPrint('TransmitterProvider: decoded=$decoded nullValue=$nullValue '
          'decodeErr=$decodeErr usable=${incoming.length} '
          '(cacheBefore=${_historyCache.length})');

      // Merge: keep existing cache entries (live) + incoming (historical),
      // dedup on (transmitterId, timestamp).
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

      debugPrint(
          'TransmitterProvider: historyCache now has ${_historyCache.length} entries');
      // Mark history as loaded before broadcasting so that any live readings
      // that arrive from here on are routed to _liveController instead of
      // triggering another full-snapshot broadcast.
      _historyLoaded = true;
      if (!_historyController.isClosed) {
        _historyController.add(List.unmodifiable(_historyCache));
      }
    } catch (e) {
      debugPrint('TransmitterProvider._loadHistoryCached error: $e');
    } finally {
      _historyCacheLoading = false;
      historyLoadProgress.value = null;
    }
  }

  /// Incremental poll for raw stats.kryz keys that appeared since the initial
  /// full scan — mirrors the server's _pollNewKeys logic.
  ///
  /// Called after each sync to pick up raw readings missed while the app was
  /// backgrounded (the notification stream may be suspended by the OS).
  /// [getAtKeys] is fast (local Hive index, no network); only genuinely new
  /// keys need a `get()`, so this is cheap compared with the full initial scan.
  Future<void> _pollNewRawKeys() async {
    if (_atClient == null) return;
    try {
      final allKeys =
          await _atClient!.getAtKeys(regex: r'stats\.kryz@');
      final cutoff7d = DateTime.now().subtract(const Duration(days: 7));
      bool added = false;
      for (final k in allKeys) {
        final ks = k.toString();
        if (_scannedKeys.contains(ks)) continue;
        _scannedKeys.add(ks); // claim before fetch so concurrent polls skip it
        try {
          final val = await _atClient!.get(k);
          if (val.value == null) continue;
          final env =
              jsonDecode(val.value as String) as Map<String, dynamic>;
          if (env['type'] != 'TransmitterStats') continue;
          final stats = TransmitterStats.fromJson(
              env['obj'] as Map<String, dynamic>);
          if (!stats.timestamp.isAfter(cutoff7d)) continue;
          _cacheAdd(stats, broadcast: false);
          added = true;
          debugPrint('TransmitterProvider: new raw key '
              '${stats.transmitterId} @ ${stats.timestamp}');
        } catch (_) {}
      }
      if (added && !_historyController.isClosed) {
        _historyController.add(List.unmodifiable(_historyCache));
      }
    } catch (e) {
      debugPrint('TransmitterProvider._pollNewRawKeys error: $e');
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

    // After each sync:
    //  1. _refreshTierCollections — fast getItems() sweep for new 5m/1h
    //     aggregate keys that the live notification stream may have missed.
    //  2. _pollNewRawKeys — fast incremental scan for raw stats.kryz keys
    //     that arrived while the app was backgrounded.  Only keys not yet in
    //     _scannedKeys are fetched, so this is essentially free once the
    //     initial full scan has completed.
    _syncListener = _ProviderSyncListener((progress) {
      if (progress.syncStatus == SyncStatus.success ||
          progress.syncStatus == SyncStatus.failure) {
        debugPrint('TransmitterProvider: sync ${progress.syncStatus} → '
            'refreshing tier collections + polling new raw keys');
        _refreshTierCollections().ignore();
        _pollNewRawKeys().ignore();
      }
    });
    atClient.syncService.addProgressListener(_syncListener!);

    // Initial Hive scan — picks up anything cached from prior sessions.
    _loadHistoryCached().ignore();
  }

  /// Open the 5-minute and 1-hour tier collections.  Live updates come
  /// from raw `notificationService.subscribe` streams; the collections
  /// themselves are kept only for the post-sync catch-up `getItems()`
  /// sweep in [_refreshTierCollections] (see class field doc for why).
  Future<void> _openTierCollections(AtClient atClient) async {
    try {
      _fiveMinNotifSub?.cancel();
      _oneHourNotifSub?.cancel();

      _fiveMinColl = await atClient.collection<TransmitterStats>(
        'stats5m.kryz',
        const Duration(hours: 26),
        fromJson: TransmitterStats.fromJson,
        typeTag: 'TransmitterStats',
        eventSource: EventSource.data,
      );

      _oneHourColl = await atClient.collection<TransmitterStats>(
        'stats1h.kryz',
        const Duration(days: 8),
        fromJson: TransmitterStats.fromJson,
        typeTag: 'TransmitterStats',
        eventSource: EventSource.data,
      );

      // Load whatever Hive already has (may be empty on first run).
      await _refreshTierCollections();

      // ── Raw notification subscriptions (live, ms-latency) ──────────────
      // Item key shape: `<receiver>:<itemId>.stats5m.kryz@<sender>`.
      atClient.notificationService.startListening();

      _fiveMinNotifSub = atClient.notificationService
          .subscribe(
        regex: r'.*\.stats5m\.kryz@.*',
        shouldDecrypt: true,
      )
          .handleError((Object e) {
        debugPrint('TransmitterProvider: 5m notif sub error: $e');
      }).listen(
        (n) => _handleTierNotification(n.value),
        cancelOnError: false,
      );

      _oneHourNotifSub = atClient.notificationService
          .subscribe(
        regex: r'.*\.stats1h\.kryz@.*',
        shouldDecrypt: true,
      )
          .handleError((Object e) {
        debugPrint('TransmitterProvider: 1h notif sub error: $e');
      }).listen(
        (n) => _handleTierNotification(n.value),
        cancelOnError: false,
      );
    } catch (e) {
      debugPrint('TransmitterProvider._openTierCollections error: $e');
    }
  }

  /// Decode an envelope-shaped notification value
  /// (`{"type":"TransmitterStats","obj":{...}}`) and add it to the cache.
  void _handleTierNotification(String? value) {
    try {
      if (value == null || value.isEmpty) return;
      if (!value.startsWith('{')) return; // not decrypted
      final env = jsonDecode(value) as Map<String, dynamic>;
      if (env['type'] != 'TransmitterStats') return;
      final stats =
          TransmitterStats.fromJson(env['obj'] as Map<String, dynamic>);
      _cacheAdd(stats);
    } catch (e) {
      debugPrint('TransmitterProvider._handleTierNotification error: $e');
    }
  }

  /// Full sweep of both tier collections — reads every item from Hive and
  /// merges into the cache.  [_cacheAdd] deduplicates so this is safe to
  /// call multiple times and won't produce duplicate chart points.
  ///
  /// All items are inserted with [broadcast:false] so that chart widgets
  /// receive a single full-snapshot update at the end instead of one
  /// snapshot per item (which could be hundreds of updates per sync cycle).
  Future<void> _refreshTierCollections() async {
    try {
      if (_fiveMinColl != null) {
        final items = await _fiveMinColl!.getItems();
        for (final CItem<TransmitterStats> item in items) {
          _cacheAdd(item.obj, broadcast: false);
        }
      }
      if (_oneHourColl != null) {
        final items = await _oneHourColl!.getItems();
        for (final CItem<TransmitterStats> item in items) {
          _cacheAdd(item.obj, broadcast: false);
        }
      }
      // One broadcast after all items are merged.
      if (!_historyController.isClosed) {
        _historyController.add(List.unmodifiable(_historyCache));
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
    // live:true routes this through _liveController once history is loaded,
    // so chart widgets can append just the new point incrementally.
    _cacheAdd(stats, live: true);

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
    _fiveMinNotifSub?.cancel();
    _oneHourNotifSub?.cancel();
    if (_syncListener != null && _atClient != null) {
      _atClient!.syncService.removeProgressListener(_syncListener!);
    }
    _historyController.close();
    _liveController.close();
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
