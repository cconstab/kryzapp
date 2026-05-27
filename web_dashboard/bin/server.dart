import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:args/args.dart';
import 'package:at_client/at_client.dart' hide Response;
import 'package:at_onboarding_cli/at_onboarding_cli.dart' as cli;
import 'package:logging/logging.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:kryz_shared/kryz_shared.dart';

final _log = Logger('KryzWebDashboard');

// ── Connected WebSocket clients ───────────────────────────────────────────────
final _clients = <WebSocketChannel>{};
Map<String, dynamic>? _lastSyncStatus;
Map<String, dynamic>? _lastConfigPayload;

// ── atClient reference — set once authenticated ───────────────────────────────
AtClient? _atClient;

// ── In-memory history cache ───────────────────────────────────────────────────
// Sorted list of all stats accumulated since startup.
// Live readings are added directly; historical data fills in via background load.
final List<TransmitterStats> _historyCache = [];
bool _historyCacheLoading = false;
bool _cacheLoaded = false; // true after the initial full scan completes

// Keys whose values have been loaded into _historyCache (toString() of AtKey).
// Used by _pollNewKeys to find genuinely new keys without re-fetching old ones.
final Set<String> _scannedKeys = {};

/// Add a stats item to the in-memory cache (maintaining sort order).
/// Returns true if the item was actually inserted, false if it was a duplicate.
bool _cacheAdd(TransmitterStats stats) {
  // Expire items older than 7 days
  final cutoff7d = DateTime.now().subtract(const Duration(days: 7));
  _historyCache.removeWhere((s) => s.timestamp.isBefore(cutoff7d));
  // Skip exact duplicates (same transmitter, same timestamp).
  if (_historyCache.any((s) =>
      s.timestamp == stats.timestamp && s.transmitterId == stats.transmitterId))
    return false;
  final idx =
      _historyCache.indexWhere((s) => s.timestamp.isAfter(stats.timestamp));
  if (idx == -1) {
    _historyCache.add(stats);
  } else {
    _historyCache.insert(idx, stats);
  }
  return true;
}

/// Return the cache as a JSON list, filtered to the given cutoff.
List<Map<String, dynamic>> _cacheSnapshot(DateTime cutoff) => _historyCache
    .where((s) => s.timestamp.isAfter(cutoff))
    .map((s) => s.toJson())
    .toList();

/// Compact wire format (~65 bytes vs ~200 bytes full JSON — 3× smaller).
/// Field order in [v] matches the METRICS array order in the browser JS:
/// [modulation, swr, powerOut, powerRef, heatTemp, fanSpeed].
Map<String, dynamic> _compact(TransmitterStats s) => {
      't': s.timestamp.millisecondsSinceEpoch,
      'i': s.transmitterId,
      'v': [
        s.modulation,
        s.swr,
        s.powerOut,
        s.powerRef,
        s.heatTemp,
        s.fanSpeed
      ],
      's': s.status,
      if (s.alertLevel != null) 'a': s.alertLevel,
    };

List<Map<String, dynamic>> _compactSnapshot(DateTime cutoff) => _historyCache
    .where((s) => s.timestamp.isAfter(cutoff))
    .map(_compact)
    .toList();

/// Send [compact] readings to a single [client] in 100-item chunks, yielding
/// to the Dart event loop between chunks so live 'r' messages can interleave
/// in the TCP stream and the browser sees updates on slow links.
Future<void> _sendHistoryChunked(
    WebSocketChannel client, List<Map<String, dynamic>> compact) async {
  const chunkSize = 100;
  if (compact.isEmpty) {
    try {
      client.sink.add(
          jsonEncode({'type': 'history', 'data': <dynamic>[], 'final': true}));
    } catch (_) {
      _clients.remove(client);
    }
    return;
  }
  for (var i = 0; i < compact.length; i += chunkSize) {
    final end = i + chunkSize;
    final chunk =
        compact.sublist(i, end < compact.length ? end : compact.length);
    final isFinal = end >= compact.length;
    try {
      client.sink.add(
          jsonEncode({'type': 'history', 'data': chunk, 'final': isFinal}));
    } catch (_) {
      _clients.remove(client);
      return;
    }
    if (!isFinal) await Future.delayed(Duration.zero);
  }
}

/// Broadcast [compact] readings to all connected clients in 100-item chunks,
/// yielding between chunks so live 'r' messages can interleave in the stream.
Future<void> _broadcastHistoryChunked(
    List<Map<String, dynamic>> compact) async {
  if (_clients.isEmpty) return;
  const chunkSize = 100;
  if (compact.isEmpty) {
    _broadcast({'type': 'history', 'data': <dynamic>[], 'final': true});
    return;
  }
  for (var i = 0; i < compact.length; i += chunkSize) {
    final end = i + chunkSize;
    final chunk =
        compact.sublist(i, end < compact.length ? end : compact.length);
    final isFinal = end >= compact.length;
    _broadcast({'type': 'history', 'data': chunk, 'final': isFinal});
    if (!isFinal) await Future.delayed(Duration.zero);
  }
}

/// Load all historical stats from the local Hive store into [_historyCache].
///
/// Collects all items into a local list first (no per-item cache mutations
/// during the scan), then sorts + deduplicates + merges once at the end.
/// Broadcasts at most once every 5 seconds during the scan so charts start
/// filling quickly without flooding clients.
///
/// Protected by [_cacheLoaded]: once the initial scan completes this is a
/// no-op, preventing runaway re-scans from the periodic timer.
Future<void> _loadHistoryCached() async {
  if (_atClient == null || _historyCacheLoading || _cacheLoaded) return;
  _historyCacheLoading = true;
  try {
    final sw = Stopwatch()..start();
    final keys = await _atClient!.getAtKeys(regex: r'stats(5m|1h)?\.kryz@');
    _log.info(
        'History scan: ${keys.length} stats keys found in ${sw.elapsedMilliseconds}ms');
    final cutoff7d = DateTime.now().subtract(const Duration(days: 7));
    final incoming = <TransmitterStats>[];

    // Read keys one at a time and yield every 10 so the Dart macrotask event
    // queue (collection.updates callbacks, WS sends) runs between groups.
    // Future.wait(N) drains all completions as microtasks before ANY event
    // queue item runs — which silences live reading events for ~600 ms/batch.
    for (var i = 0; i < keys.length; i++) {
      _scannedKeys.add(keys[i].toString()); // record before fetching
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
      if (i % 10 == 9) await Future.delayed(Duration.zero);
    }
    await Future.delayed(Duration.zero); // final yield

    // Final merge: sort + deduplicate incoming against live readings in cache.
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
    sw.stop();
    _log.info(
        'History scan complete: ${_historyCache.length} readings in ${sw.elapsedMilliseconds}ms');
    // Broadcast the complete sorted dataset in chunks so live 'r' messages
    // can interleave between chunks on slow links.
    if (_clients.isNotEmpty) {
      await _broadcastHistoryChunked(_compactSnapshot(cutoff7d));
    }
  } catch (e) {
    _log.warning('_loadHistoryCached error: $e');
  } finally {
    _historyCacheLoading = false;
  }
}

/// Convert a [DashboardConfig] to the `{type:'config', data:{...}}` WS payload.
Map<String, dynamic> _configPayload(DashboardConfig cfg) {
  return {
    'type': 'config',
    'data': {
      'stationName': cfg.stationName,
      'thresholds': cfg.gauges.map((key, g) => MapEntry(key, {
            'unit': g.unit,
            'minVal': g.minValue,
            'maxVal': g.maxValue,
            'warnHigh': g.warningHighThreshold,
            'critHigh': g.criticalHighThreshold,
            'warnLow': g.warningLowThreshold,
            'critLow': g.criticalLowThreshold,
          })),
    },
  };
}

/// Incremental poll for keys that appeared after the initial full scan.
///
/// Runs every 30 s once [_cacheLoaded] is true.  [getAtKeys] is fast (local
/// Hive list, no network).  Only the 1–2 NEW keys per poll need a `get()`,
/// so this is essentially free compared with the initial scan.  This is the
/// fallback that keeps realtime working even if [collection.updates] silently
/// stops firing (notification WebSocket drop, at_client edge case, etc.).
Future<void> _pollNewKeys() async {
  if (!_cacheLoaded || _atClient == null) return;
  try {
    final allKeys = await _atClient!.getAtKeys(regex: r'stats(5m|1h)?\.kryz@');
    final cutoff7d = DateTime.now().subtract(const Duration(days: 7));
    for (final k in allKeys) {
      final ks = k.toString();
      if (_scannedKeys.contains(ks)) continue;
      _scannedKeys.add(ks); // claim before fetch so concurrent polls skip it
      try {
        final val = await _atClient!.get(k);
        if (val.value == null) continue;
        final env = jsonDecode(val.value as String) as Map<String, dynamic>;
        if (env['type'] != 'TransmitterStats') continue;
        final stats =
            TransmitterStats.fromJson(env['obj'] as Map<String, dynamic>);
        if (!stats.timestamp.isAfter(cutoff7d)) continue;
        if (_cacheAdd(stats) && _clients.isNotEmpty) {
          _log.fine(
              'Poll new key: ${stats.transmitterId} @ ${stats.timestamp}');
          _broadcast({'type': 'r', 'data': _compact(stats)});
        }
      } catch (_) {}
    }
  } catch (e) {
    _log.warning('_pollNewKeys error: $e');
  }
}

// ── History broadcast ────────────────────────────────────────────────────────
// Tracked so we can detect out-of-order readings from sync.
DateTime? _latestBroadcastTime;

/// Push history to all connected clients (serves from cache; triggers a
/// background cache load only if the initial scan hasn't run yet).
Future<void> _pushHistoryAll(int secs) async {
  if (_clients.isEmpty) return;
  final cutoff = DateTime.now().subtract(Duration(seconds: secs));
  final compact = _compactSnapshot(cutoff);
  if (compact.isNotEmpty) {
    _log.info('History push: ${compact.length} readings (${secs}s window) '
        'to ${_clients.length} client(s)');
    await _broadcastHistoryChunked(compact);
  }
  // Trigger the initial load if it hasn't run yet (e.g. client connected
  // before auth completed) — but never re-run once _cacheLoaded is set.
  if (!_cacheLoaded && !_historyCacheLoading) _loadHistoryCached().ignore();
}

void _broadcast(Object message) {
  final encoded = message is String ? message : jsonEncode(message);
  for (final client in Set.of(_clients)) {
    try {
      client.sink.add(encoded);
    } catch (_) {
      _clients.remove(client);
    }
  }
}

// ── Entry point ───────────────────────────────────────────────────────────────

void main(List<String> arguments) async {
  Logger.root.level = Level.INFO;
  Logger.root.onRecord.listen((r) =>
      print('${r.level.name}: ${r.time}: ${r.loggerName}: ${r.message}'));

  final parser = ArgParser()
    ..addOption('atsign',
        abbr: 'a', help: 'atSign for reading the collection (required)')
    ..addOption('keys',
        abbr: 'k',
        help: 'Path to .atKeys file '
            '(default: ~/.atsign/keys/<atsign>_key.atKeys)')
    ..addOption('host',
        abbr: 'H', defaultsTo: 'localhost', help: 'HTTP server bind address')
    ..addOption('port', abbr: 'p', defaultsTo: '8080', help: 'HTTP server port')
    ..addFlag('help', negatable: false, help: 'Show usage');

  ArgResults args;
  try {
    args = parser.parse(arguments);
  } on ArgParserException catch (e) {
    print('Error: ${e.message}\n\nUsage:\n${parser.usage}');
    exit(1);
  }
  if (args['help'] as bool) {
    print('KRYZ Web Dashboard Server\n\nUsage:\n${parser.usage}');
    exit(0);
  }
  if (!args.wasParsed('atsign')) {
    print('Error: --atsign (-a) is required.\n\nUsage:\n${parser.usage}');
    exit(1);
  }

  final atSign = args['atsign'] as String;
  final keysPath = args['keys'] as String? ??
      '${Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']}'
          '/.atsign/keys/${atSign}_key.atKeys';
  final bindHost = args['host'] as String;
  final port = int.parse(args['port'] as String);

  // ── HTTP + WebSocket server — start immediately so browser can connect ────
  final router = Router()
    // Serve the static dashboard HTML
    ..get('/', _serveIndex)
    ..get('/index.html', _serveIndex)
    // REST endpoint: historical readings for a given window (seconds)
    ..get('/history', (Request req) async {
      final windowSecs =
          int.tryParse(req.url.queryParameters['window'] ?? '') ?? 3600;
      final cutoff = DateTime.now().subtract(Duration(seconds: windowSecs));
      return Response.ok(
        jsonEncode(_cacheSnapshot(cutoff)),
        headers: {'content-type': 'application/json'},
      );
    })
    // WebSocket upgrade
    ..get(
      '/ws',
      webSocketHandler((WebSocketChannel ws) {
        _clients.add(ws);
        _log.info('WebSocket client connected (total: ${_clients.length})');

        // Send last known sync status + config immediately on connect.
        if (_lastSyncStatus != null) {
          ws.sink.add(jsonEncode(_lastSyncStatus));
        }
        if (_lastConfigPayload != null) {
          ws.sink.add(jsonEncode(_lastConfigPayload));
        }
        // Send whatever is already in the cache immediately (chunked so live
        // 'r' messages can interleave between chunks on slow links).
        final compact =
            _compactSnapshot(DateTime.now().subtract(const Duration(days: 7)));
        if (compact.isNotEmpty) {
          unawaited(_sendHistoryChunked(ws, compact));
          _log.info(
              'Sending ${compact.length} cached history items to new client (chunked)');
        }

        // When client requests historical data it sends:
        //   {"action": "history", "window": <seconds>}
        ws.stream.listen(
          (msg) async {
            try {
              final cmd = jsonDecode(msg as String) as Map<String, dynamic>;
              if (cmd['action'] == 'history') {
                final secs = (cmd['window'] as num?)?.toInt() ?? 3600;
                final cutoff = DateTime.now().subtract(Duration(seconds: secs));
                unawaited(_sendHistoryChunked(ws, _compactSnapshot(cutoff)));
              }
            } catch (e) {
              _log.warning('Bad WS message: $e');
            }
          },
          onDone: () {
            _clients.remove(ws);
            _log.info(
                'WebSocket client disconnected (total: ${_clients.length})');
          },
          onError: (e) => _clients.remove(ws),
          cancelOnError: false,
        );
      }),
    );

  final handler =
      const Pipeline().addMiddleware(logRequests()).addHandler(router.call);

  final server = await shelf_io.serve(handler, bindHost, port);
  _log.info(
      'Dashboard running at http://${server.address.host}:${server.port}');
  _log.info(
      'Open that URL in any browser — no atSign required in the browser.');

  // Safety-net: push 7-day history to all connected clients every 30 seconds.
  // This catches cases where sync completed AFTER the initial per-client push
  // (e.g., large initial sync on a fresh installation) and ensures historical
  // data appears within at most 30 seconds of sync completing.
  Timer.periodic(const Duration(seconds: 30), (_) {
    // Force a sync cycle so new readings arrive even if the notification
    // WebSocket connection has silently dropped.
    _atClient?.syncService.sync();
    if (_clients.isNotEmpty) {
      _pushHistoryAll(604800).ignore();
    }
    // After the initial scan, poll for any keys that arrived since the scan
    // completed.  This is the reliable realtime path — it works even when
    // collection.updates stops firing.
    _pollNewKeys().ignore();
  });

  // ── atProtocol init in background so HTTP server is immediately available ─
  unawaited(() async {
    _log.info('Authenticating $atSign …');
    final pref = cli.AtOnboardingPreference()
      ..rootDomain = 'root.atsign.org'
      ..namespace = 'kryz'
      ..hiveStoragePath = '.atsign/storage/$atSign'
      ..commitLogPath = '.atsign/storage/$atSign/commitLog'
      ..atKeysFilePath = keysPath
      ..fetchOfflineNotifications = false;

    final onboarding = cli.AtOnboardingServiceImpl(atSign, pref);
    if (!await onboarding.authenticate()) {
      _log.severe('Authentication failed for $atSign');
      exit(1);
    }
    _atClient = AtClientManager.getInstance().atClient;
    final atClient = _atClient!;
    _log.info('Authenticated as $atSign');

    atClient.syncService.addProgressListener(_SyncProgressBroadcaster());

    Future<void> loadAndBroadcastConfig() async {
      final previousJson =
          _lastConfigPayload != null ? jsonEncode(_lastConfigPayload) : null;
      try {
        final key = AtKey()
          ..key = 'kryz_dashboard_config'
          ..sharedWith = atSign;
        final result = await atClient.get(key);
        if (result.value != null) {
          final cfg = DashboardConfig.fromJson(
              jsonDecode(result.value as String) as Map<String, dynamic>);
          _lastConfigPayload = _configPayload(cfg);
          _log.info('DashboardConfig loaded from atProtocol');
        } else {
          _lastConfigPayload = _configPayload(DashboardConfig.defaults());
          _log.info('No stored config found — using defaults');
        }
      } catch (e) {
        _lastConfigPayload = _configPayload(DashboardConfig.defaults());
        _log.warning('Could not load DashboardConfig: $e — using defaults');
      }
      // Only broadcast when the config has actually changed.
      final newJson = jsonEncode(_lastConfigPayload);
      if (newJson != previousJson) {
        _log.info('Config changed — broadcasting to clients');
        _broadcast(_lastConfigPayload!);
      }
    }

    await loadAndBroadcastConfig();
    // Always send the config on first load regardless of change detection.
    if (_lastConfigPayload != null) _broadcast(_lastConfigPayload!);

    atClient.notificationService
        .subscribe(regex: '.*kryz_dashboard_config.*', shouldDecrypt: true)
        .listen((_) async {
      _log.info('Config change notification received — reloading');
      await loadAndBroadcastConfig();
    });

    // Periodic safety-net poll: re-check config every 5 minutes and
    // broadcast only if it changed (handles missed notifications).
    Timer.periodic(const Duration(minutes: 5), (_) async {
      await loadAndBroadcastConfig();
    });

    // Force the notification listener up before opening the collection so
    // the first event doesn't race the lazy startup inside subscribe().
    atClient.notificationService.startListening();

    final collection = await atClient.collection<TransmitterStats>(
      'stats.kryz',
      const Duration(days: 7),
      fromJson: TransmitterStats.fromJson,
      typeTag: 'TransmitterStats',
      eventSource: EventSource.data,
    );
    _log.info('Collection opened (stats.kryz)');

    // Start loading historical data into the cache in the background.
    // _loadHistoryCached() reads in batches and broadcasts partial results
    // progressively, so charts start showing data within seconds.
    _loadHistoryCached().ignore();

    collection.updates.listen(
      (event) async {
        final citem = await collection.getOrNull(event.id, event.owner);
        if (citem == null) return;
        final stats = citem.obj;
        _log.fine('New reading: ${stats.transmitterId} @ ${stats.timestamp}');
        // Always add to cache so it appears in history.
        _cacheAdd(stats);
        if (_latestBroadcastTime != null &&
            stats.timestamp.isBefore(_latestBroadcastTime!)) {
          _log.fine(
              'Out-of-order reading (${stats.timestamp}) — added to cache, skipping live broadcast');
          return;
        }
        _latestBroadcastTime = stats.timestamp;
        _broadcast({'type': 'r', 'data': _compact(stats)});
      },
      onError: (Object e, StackTrace st) {
        _log.warning('collection.updates error: $e\n$st');
      },
      cancelOnError: false,
    );
  }());

  // Clean shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    _log.info('Shutting down …');
    await server.close(force: true);
    exit(0);
  });
}

Response _serveIndex(Request _) {
  // Inline the HTML so the binary is self-contained (no separate web/ dir needed).
  return Response.ok(
    _dashboardHtml,
    headers: {'content-type': 'text/html; charset=utf-8'},
  );
}

// ── Sync progress broadcaster ─────────────────────────────────────────────────
// Receives periodic sync events from at_client and pushes them to all connected
// WebSocket clients so the dashboard can show local vs server commit position.
class _SyncProgressBroadcaster extends SyncProgressListener {
  @override
  void onSyncProgressEvent(SyncProgress syncProgress) {
    _lastSyncStatus = {
      'type': 'sync',
      'data': {
        'status': syncProgress.syncStatus?.name,
        'localCommitId': syncProgress.localCommitId,
        'serverCommitId': syncProgress.serverCommitId,
        'pendingPushCount': syncProgress.pendingPushCount,
        'atSign': syncProgress.atSign,
        'message': syncProgress.message,
      },
    };
    _broadcast(_lastSyncStatus!);

    // After a successful sync, push fresh history to all connected clients.
    // This is the primary mechanism for delivering historical data that wasn't
    // yet in the local store when clients first connected.
    if (syncProgress.syncStatus == SyncStatus.success) {
      // Push the full 7-day window so clients on any time-window tab get
      // their data.  applyReadings in the browser filters to currentWindow.
      _pushHistoryAll(604800).ignore();
    }
  }
}

// ── Embedded dashboard HTML ───────────────────────────────────────────────────
// Chart.js is loaded from CDN.  The page connects to the /ws WebSocket and
// renders a live multi-metric dashboard.  Replace the CDN URL with a local
// copy for air-gapped deployments.

const _dashboardHtml = r'''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>KRYZ Transmitter Dashboard</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4/dist/chart.umd.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chartjs-plugin-annotation@3/dist/chartjs-plugin-annotation.min.js"></script>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:system-ui,sans-serif;background:#111;color:#eee;padding:12px}
  h1{font-size:1.1rem;margin-bottom:10px;opacity:.8}
  .toolbar{display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;align-items:center}
  .toolbar button{
    padding:6px 14px;border:1px solid #555;border-radius:4px;
    background:#222;color:#eee;cursor:pointer;font-size:.85rem
  }
  .toolbar button.active{background:#2196F3;border-color:#2196F3}
  #status{margin-left:auto;font-size:.8rem;opacity:.6}
  .grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
  @media(max-width:640px){.grid{grid-template-columns:repeat(1,1fr)}}
  .card{background:#1a1a1a;border-radius:8px;padding:12px}
  .card h2{font-size:.85rem;margin-bottom:8px;opacity:.7}
  canvas{width:100%!important;height:100%!important}
  .chart-wrap{width:100%;aspect-ratio:200/120}
  .meters{display:grid;grid-template-columns:repeat(auto-fill,minmax(160px,1fr));gap:10px;margin-bottom:14px}
  .meter{
    background:#1a1a1a;border-radius:8px;padding:10px 14px;
    border:1.5px solid #333;display:flex;flex-direction:column;gap:4px
  }
  .meter .m-label{font-size:.72rem;opacity:.6;text-transform:uppercase;letter-spacing:.05em}
  .meter .m-value{font-size:1.6rem;font-weight:700;line-height:1}
  .meter .m-unit{font-size:.72rem;opacity:.5}
  .m-ok   {color:#4CAF50;border-color:#4CAF5066}
  .m-warn {color:#FF9800;border-color:#FF980066}
  .m-crit {color:#E53935;border-color:#E5393566}
  .m-idle {color:#aaa}
  .sync-bar{display:flex;gap:16px;align-items:center;font-size:.78rem;margin-top:10px;
    padding:6px 12px;background:#1a1a1a;border-radius:6px;flex-wrap:wrap;min-height:50px}
  .sync-bar .lbl{font-weight:600;opacity:.9}
  .sync-bar span{white-space:nowrap;opacity:.75}
  .s-ok{color:#4CAF50!important;opacity:1!important}
  .s-behind{color:#FF9800!important;opacity:1!important}
  .s-syncing{color:#2196F3!important;opacity:1!important}
  .s-error{color:#E53935!important;opacity:1!important}
  /* Tab navigation */
  .nav-tabs{display:flex;gap:4px}
  .nav-tab{padding:5px 14px;border:1px solid #555;border-radius:4px;background:#222;color:#eee;cursor:pointer;font-size:.82rem}
  .nav-tab.active{background:#2196F3;border-color:#2196F3;color:#fff}
  .last-time{font-size:.78rem;color:#aaa}
  /* Page sections */
  .page{display:none}
  .page.active{display:block}
  /* SVG gauge cards */
  .gauge-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px;margin-bottom:12px}
  @media(max-width:640px){.gauge-grid{grid-template-columns:repeat(2,1fr)}}
  .gauge-card{background:#1a1a1a;border-radius:8px;padding:10px 8px 4px;border:1.5px solid #333;text-align:center;transition:border-color .3s}
  .gauge-card .gc-title{font-size:.72rem;font-weight:600;opacity:.65;text-transform:uppercase;letter-spacing:.06em;margin-bottom:2px}
  .gc-readout{margin-top:-4px;text-align:center;line-height:1}
  .gc-value{font-size:1.8rem;font-weight:700}
  .gc-unit{font-size:.72rem;opacity:.5;margin-left:2px}
</style>
</head>
<body>
<div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:10px">
  <h1 style="margin:0;font-size:1.1rem;opacity:.8">&#x1F4FB; KRYZ Transmitter</h1>
  <div class="nav-tabs">
    <button class="nav-tab active" data-tab="gauges">Gauges</button>
    <button class="nav-tab" data-tab="charts">Charts</button>
  </div>
  <span id="lastTime" class="last-time"></span>
  <span id="status">Connecting…</span>
</div>
<div id="page-gauges" class="page active">
  <div class="gauge-grid" id="gaugeGrid"></div>
</div>
<div id="page-charts" class="page">
  <div class="toolbar">
    <button data-w="3600" class="active">1 h</button>
    <button data-w="21600">6 h</button>
    <button data-w="86400">24 h</button>
    <button data-w="604800">7 d</button>
  </div>
  <div class="grid" id="grid"></div>
</div>
<div class="sync-bar" id="syncBar">
  <span class="lbl">Sync</span>
  <span>Status: <b id="syncState">—</b></span>
  <span>Local: <b id="syncLocal">—</b></span>
  <span>Server: <b id="syncServer">—</b></span>
  <span id="syncDiff"></span>
  <span id="syncPending"></span>
</div>

<script>
const METRICS = [
  {key:'modulation',label:'Modulation',        unit:'%',   color:'#4CAF50', minVal:0,   maxVal:120,   warnLow:60,  critLow:50,  warnHigh:104, critHigh:105},
  {key:'swr',       label:'SWR',               unit:':1',  color:'#FF9800', minVal:1,   maxVal:3.5,                            warnHigh:1.8, critHigh:3.0},
  {key:'powerOut',  label:'Power Out',          unit:'W',   color:'#2196F3', minVal:0,   maxVal:20,    warnLow:8,   critLow:5},
  {key:'powerRef',  label:'Power Reflected',    unit:'W',   color:'#E53935', minVal:0,   maxVal:5,                              warnHigh:1.0, critHigh:2.0},
  {key:'heatTemp',  label:'Heat Sink Temp',     unit:'°C',  color:'#F44336', minVal:0,   maxVal:100,                            warnHigh:75,  critHigh:90},
  {key:'fanSpeed',  label:'Fan Speed',          unit:'RPM', color:'#9C27B0', minVal:0,   maxVal:10000},
];

const charts = {};
let ws;
let currentWindow = 3600;

// ── Pointer gauge system ──────────────────────────────────────────────────────
// Classic analog pointer (needle) gauges with spring-physics hysteresis.
// Each gauge has a semicircle arc with coloured zone bands and a thin needle
// that glides smoothly toward each new value with natural overshoot.

const _GCX = 100, _GCY = 103, _GR = 80, _GNL = 72;

// Map 0-1 fraction → needle rotation degrees (−90=left/min, +90=right/max).
function _pctToRot(pct) {
  return -90 + Math.max(0, Math.min(1, pct)) * 180;
}

// SVG arc-path string for a value sub-range [v1,v2] on metric m.
function _arcSegPath(v1, v2, m) {
  const p1 = Math.max(0, Math.min(1, (v1 - m.minVal) / (m.maxVal - m.minVal)));
  const p2 = Math.max(0, Math.min(1, (v2 - m.minVal) / (m.maxVal - m.minVal)));
  if (p2 <= p1 + 0.001) return '';
  const th1 = Math.PI * (1 - p1), th2 = Math.PI * (1 - p2);
  const x1 = (_GCX + _GR * Math.cos(th1)).toFixed(2);
  const y1 = (_GCY - _GR * Math.sin(th1)).toFixed(2);
  const x2 = (_GCX + _GR * Math.cos(th2)).toFixed(2);
  const y2 = (_GCY - _GR * Math.sin(th2)).toFixed(2);
  // The gauge is always a semicircle (180°), so no segment ever spans > 180°
  // of the full circle.  large-arc-flag must always be 0.
  return `M ${x1} ${y1} A ${_GR} ${_GR} 0 0 1 ${x2} ${y2}`;
}

// Build coloured zone-arc HTML for a metric (ok / warn / crit bands).
// Returns empty string when the metric has no thresholds.
function _buildZoneArcs(m) {
  const lo = m.minVal, hi = m.maxVal;
  const cL = m.critLow  !== undefined ? Math.max(lo, m.critLow)  : null;
  const wL = m.warnLow  !== undefined ? Math.max(lo, m.warnLow)  : null;
  const wH = m.warnHigh !== undefined ? Math.min(hi, m.warnHigh) : null;
  const cH = m.critHigh !== undefined ? Math.min(hi, m.critHigh) : null;
  if (cL === null && wL === null && wH === null && cH === null) return '';
  const sw = 'stroke-width="14" stroke-linecap="butt"';
  let s = '';
  if (cL !== null && cL > lo)
    s += `<path d="${_arcSegPath(lo, cL, m)}" fill="none" stroke="#E5393550" ${sw}/>`;
  if (wL !== null)
    s += `<path d="${_arcSegPath(cL ?? lo, wL, m)}" fill="none" stroke="#FF980050" ${sw}/>`;
  const okFrom = wL ?? cL ?? lo, okTo = wH ?? cH ?? hi;
  if (okTo > okFrom)
    s += `<path d="${_arcSegPath(okFrom, okTo, m)}" fill="none" stroke="#4CAF5050" ${sw}/>`;
  if (wH !== null)
    s += `<path d="${_arcSegPath(wH, cH ?? hi, m)}" fill="none" stroke="#FF980050" ${sw}/>`;
  if (cH !== null && cH < hi)
    s += `<path d="${_arcSegPath(cH, hi, m)}" fill="none" stroke="#E5393550" ${sw}/>`;
  return s;
}

// Rebuild zone arcs in-place after a config threshold change.
function _rebuildZoneArcs(m) {
  const g = document.getElementById('gz_' + m.key);
  if (g) g.innerHTML = _buildZoneArcs(m);
}

// Spring-physics animation loop.
// Low stiffness (k=0.04) + high damping (d=0.88) = slow, graceful glide
// with a gentle overshoot, like a heavy analog needle with mechanical inertia.
const _GAnim = {};
let _gAnimRaf = null;
function _runGaugeAnimation() {
  let anyMoving = false;
  for (const key in _GAnim) {
    const a = _GAnim[key];
    a.vel += (a.target - a.rot) * 0.028;
    a.vel *= 0.90;
    a.rot += a.vel;
    const needle = document.getElementById('gn_' + key);
    if (needle) needle.setAttribute('transform', `rotate(${a.rot.toFixed(2)}, ${_GCX}, ${_GCY})`);
    if (Math.abs(a.vel) > 0.02 || Math.abs(a.target - a.rot) > 0.05) anyMoving = true;
  }
  _gAnimRaf = anyMoving ? requestAnimationFrame(_runGaugeAnimation) : null;
}

function updateGauge(m, rawV) {
  if (rawV === null || rawV === undefined) return;
  const v = +rawV;
  const rot   = _pctToRot((v - m.minVal) / (m.maxVal - m.minVal));
  const color = _alertChartColor(m, v);
  if (!_GAnim[m.key]) {
    _GAnim[m.key] = {rot, vel: 0, target: rot};
    const n = document.getElementById('gn_' + m.key);
    if (n) n.setAttribute('transform', `rotate(${rot.toFixed(2)}, ${_GCX}, ${_GCY})`);
  } else {
    _GAnim[m.key].target = rot;
  }
  if (_gAnimRaf === null) _gAnimRaf = requestAnimationFrame(_runGaugeAnimation);
  const valEl = document.getElementById('gv_' + m.key);
  if (valEl) { valEl.textContent = v.toFixed(1); valEl.style.color = color; }
  const needle = document.getElementById('gn_' + m.key);
  if (needle) needle.setAttribute('stroke', color);
  document.getElementById('gc_' + m.key).style.borderColor = color + '99';
}

function _fmtGaugeTick(v) {
  if (Math.abs(v) >= 10000) return (v/1000).toFixed(0)+'k';
  if (Math.abs(v) >=  1000) return parseFloat((v/1000).toFixed(1))+'k';
  return parseFloat(v.toFixed(1)).toString();
}
function _updateGaugeTicks(m) {
  for (let i = 0; i <= 4; i++) {
    const el = document.getElementById('gt_'+m.key+'_'+i);
    if (el) el.textContent = _fmtGaugeTick(m.minVal + (m.maxVal - m.minVal) * i / 4);
  }
}
const gaugeGridEl = document.getElementById('gaugeGrid');
const _trackFull = `M ${_GCX-_GR} ${_GCY} A ${_GR} ${_GR} 0 0 1 ${_GCX+_GR} ${_GCY}`;
for (const m of METRICS) {
  const card = document.createElement('div');
  card.className = 'gauge-card';
  card.id = 'gc_' + m.key;
  // Radial tick marks at 0 %, 25 %, 50 %, 75 %, 100 % with value labels.
  let ticks = '';
  for (let i = 0; i <= 4; i++) {
    const th = Math.PI * (1 - i / 4);
    const ix = (_GCX + (_GR - 20) * Math.cos(th)).toFixed(1);
    const iy = (_GCY - (_GR - 20) * Math.sin(th)).toFixed(1);
    const ox = (_GCX + (_GR - 7)  * Math.cos(th)).toFixed(1);
    const oy = (_GCY - (_GR - 7)  * Math.sin(th)).toFixed(1);
    const lx = (_GCX + (_GR + 12) * Math.cos(th)).toFixed(1);
    const ly = (_GCY - (_GR + 12) * Math.sin(th)).toFixed(1);
    const anch = i === 0 ? 'start' : i === 4 ? 'end' : 'middle';
    const tv = _fmtGaugeTick(m.minVal + (m.maxVal - m.minVal) * i / 4);
    ticks += `<line x1="${ix}" y1="${iy}" x2="${ox}" y2="${oy}" stroke="#555" stroke-width="1.5"/>`;
    ticks += `<text id="gt_${m.key}_${i}" x="${lx}" y="${ly}" text-anchor="${anch}" dominant-baseline="middle" font-size="8" fill="#555">${tv}</text>`;
  }
  card.innerHTML = `
    <div class="gc-title">${m.label}</div>
    <svg viewBox="0 0 200 120" xmlns="http://www.w3.org/2000/svg">
      <path d="${_trackFull}" fill="none" stroke="#252525" stroke-width="14" stroke-linecap="butt"/>
      <g id="gz_${m.key}">${_buildZoneArcs(m)}</g>
      ${ticks}
      <line id="gn_${m.key}" x1="${_GCX}" y1="${_GCY}" x2="${_GCX}" y2="${_GCY-_GNL}"
            stroke="#777" stroke-width="2.5" stroke-linecap="round"
            transform="rotate(-90, ${_GCX}, ${_GCY})"/>
      <circle cx="${_GCX}" cy="${_GCY}" r="6" fill="#2a2a2a"/>
      <circle cx="${_GCX}" cy="${_GCY}" r="3.5" fill="#bbb"/>

    </svg>
    <div class="gc-readout">
      <span id="gv_${m.key}" class="gc-value">—</span><span class="gc-unit">${m.unit}</span>
    </div>`;
  gaugeGridEl.appendChild(card);
}

function _meterClass(m, v) {
  if (v === null || v === undefined) return 'm-idle';
  if ((m.critHigh !== undefined && v >= m.critHigh) ||
      (m.critLow  !== undefined && v <= m.critLow))  return 'm-crit';
  if ((m.warnHigh !== undefined && v >= m.warnHigh) ||
      (m.warnLow  !== undefined && v <= m.warnLow))  return 'm-warn';
  return 'm-ok';
}

// Returns the hex colour that matches the alert state for a metric value.
// Used to colour both meter cards and chart lines consistently.
// Returns Chart.js annotation objects for the threshold lines of a metric.
// Lines are thin and semi-transparent to avoid obscuring the chart data.
function _buildThresholdAnnotations(m) {
  const anns = {};
  if (m.warnHigh !== undefined) anns.wH = {
    type:'line', scaleID:'y', value:m.warnHigh,
    borderColor:'rgba(255,152,0,0.35)', borderWidth:1, borderDash:[4,4],
  };
  if (m.critHigh !== undefined) anns.cH = {
    type:'line', scaleID:'y', value:m.critHigh,
    borderColor:'rgba(229,57,53,0.35)', borderWidth:1, borderDash:[4,4],
  };
  if (m.warnLow !== undefined) anns.wL = {
    type:'line', scaleID:'y', value:m.warnLow,
    borderColor:'rgba(255,152,0,0.35)', borderWidth:1, borderDash:[4,4],
  };
  if (m.critLow !== undefined) anns.cL = {
    type:'line', scaleID:'y', value:m.critLow,
    borderColor:'rgba(229,57,53,0.35)', borderWidth:1, borderDash:[4,4],
  };
  return anns;
}

function _alertChartColor(m, v) {
  const cls = _meterClass(m, v);
  if (cls === 'm-crit') return '#E53935';
  if (cls === 'm-warn') return '#FF9800';
  if (cls === 'm-ok')   return '#4CAF50';
  return '#888';
}

function updateMeters(r) {
  _lastReading = r;
  for (const m of METRICS) {
    updateGauge(m, r[m.key]);
  }
  if (r.timestamp) {
    const ts = new Date(r.timestamp);
    const fmt = new Intl.DateTimeFormat(undefined, {
      month:'short', day:'numeric', hour:'2-digit', minute:'2-digit', second:'2-digit'
    });
    document.getElementById('lastTime').textContent = 'Last: ' + fmt.format(ts);
  }
}

// ── Build chart cards ─────────────────────────────────────────────────────────
const grid = document.getElementById('grid');
for (const m of METRICS) {
  const card = document.createElement('div');
  card.className = 'card';
  card.innerHTML = `<h2>${m.label} (${m.unit})</h2><div class="chart-wrap"><canvas id="c_${m.key}"></canvas></div>`;
  grid.appendChild(card);

  const ctx = document.getElementById(`c_${m.key}`).getContext('2d');
  charts[m.key] = new Chart(ctx, {
    type: 'line',
    data: {datasets:[{
      label: m.label,
      data: [],
      borderColor: '#888',        // fallback; segment overrides per data point
      backgroundColor: '#88888840', // fallback; segment overrides per data point
      borderWidth: 2,
      pointRadius: 0,
      tension: 0.2,
      fill: true,
      spanGaps: false,   // null points produce a visible gap in the line
      // Colour each segment by the alert state of the starting data point so
      // periods of warning/critical show orange/red in the historical fill.
      segment: {
        borderColor: ctx => {
          const y = ctx.p0.parsed.y;
          return y != null ? _alertChartColor(m, y) : undefined;
        },
        backgroundColor: ctx => {
          const y = ctx.p0.parsed.y;
          return y != null ? _alertChartColor(m, y) + '40' : undefined;
        },
      },
    }]},
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      interaction: {mode: 'index', intersect: false},
      layout: {padding: {top: 12}},
      scales: {
        x: {
          type: 'time',
          time: {
            displayFormats: {
              millisecond: 'HH:mm:ss',
              second:      'HH:mm:ss',
              minute:      'HH:mm',
              hour:        'MMM d HH:mm',
              day:         'MMM d',
              week:        'MMM d',
              month:       'MMM yyyy',
            },
            tooltipFormat: 'yyyy-MM-dd HH:mm:ss',
          },
          grid: {color:'#333'},
          ticks: {color:'#aaa', maxTicksLimit:6},
        },
        y: {
          min: m.minVal,
          max: m.maxVal,
          grid: {color:'#333'},
          ticks: {color:'#aaa', maxTicksLimit: 6},
        },
      },
      plugins: {
        legend: {display: false},
        tooltip: {
          mode: 'index',
          intersect: false,
          backgroundColor: 'rgba(0,0,0,0.85)',
          titleColor: '#fff',
          bodyColor: '#aaa',
        },
        annotation: {
          annotations: _buildThresholdAnnotations(m),
        },
      },
    },
  });
}

// ── Config ────────────────────────────────────────────────────────────────────
// Receives {stationName, thresholds:{powerOut:{unit,warnHigh,...}, ...}} from
// the server.  Updates METRICS entries so _meterClass uses the correct values.
let _lastReading = null;
function applyConfig(d) {
  if (!d || !d.thresholds) return;
  document.title = (d.stationName || 'KRYZ') + ' — Dashboard';
  for (const m of METRICS) {
    const t = d.thresholds[m.key];
    if (!t) continue;
    if (t.unit     !== undefined) m.unit     = t.unit;
    if (t.minVal !== undefined) {
      m.minVal = t.minVal;
      charts[m.key].options.scales.y.min = t.minVal;
      _updateGaugeTicks(m);
    }
    if (t.maxVal !== undefined) {
      m.maxVal = t.maxVal;
      charts[m.key].options.scales.y.max = t.maxVal;
      _updateGaugeTicks(m);
    }
    if (t.warnHigh !== undefined) m.warnHigh = t.warnHigh;
    if (t.critHigh !== undefined) m.critHigh = t.critHigh;
    if (t.warnLow  !== undefined) m.warnLow  = t.warnLow;
    if (t.critLow  !== undefined) m.critLow  = t.critLow;
    // Rebuild threshold annotations and gauge zone arcs from updated values.
    charts[m.key].options.plugins.annotation.annotations = _buildThresholdAnnotations(m);
    _rebuildZoneArcs(m);
    charts[m.key].update('none');
  }
  // Refresh meter colours with current data if we already have a reading.
  if (_lastReading) updateMeters(_lastReading);
}


// ── Gap detection ─────────────────────────────────────────────────────────────
// The cache mixes raw (2 s), 5-min and 1-hour tier data.  Using a dynamic
// median-based threshold fails because the dense raw tier dominates the
// distribution (median ≈ 2 s → threshold ≈ 6 s), turning every 5-min gap
// between 5-min-tier readings into a false "outage" break.
//
// Instead we use a fixed per-window threshold that mirrors the mobile app's
// _gapThresholdForWindow:
//   ≤ 24 h window → 10 min  (catches real outages; ignores raw-tier density)
//    > 24 h window → 2 h    (catches real outages in 1-hour-tier data)

// Rolling ring buffer — used ONLY for live appendReading gap detection.
const _recentIntervals = [];
const _MAX_INTERVALS = 30;

function _addInterval(ms) {
  if (ms <= 0) return;
  _recentIntervals.push(ms);
  if (_recentIntervals.length > _MAX_INTERVALS) _recentIntervals.shift();
}

function _gapThreshold(intervals) {
  if (intervals.length === 0) return Infinity;
  const sorted = [...intervals].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)] * 3;
}

// Fixed window-aware threshold for history batches (matches mobile app).
function _gapThresholdForWindow(windowSecs) {
  return (windowSecs <= 86400 ? 10 * 60 : 2 * 60 * 60) * 1000; // ms
}

// Inject {x, y:null} sentinels into a batch of history readings so Chart.js
// draws a visible break over real outage periods.
function injectGaps(readings, key, windowSecs) {
  const threshold = _gapThresholdForWindow(windowSecs ?? currentWindow);
  // Readings < 30 s apart are raw 2 s tier — apply EMA.
  // Readings ≥ 30 s apart are aggregated (5-min/1-hour) — use directly, re-seed.
  const RAW_TIER_MAX_MS = 30000;
  if (readings.length < 2) {
    return readings.map(r => ({x: new Date(r.timestamp), y: r[key]}));
  }
  const result = [];
  let ema;
  for (let i = 0; i < readings.length; i++) {
    const raw = readings[i][key];
    if (i === 0) {
      ema = raw;
    } else {
      const ms = new Date(readings[i].timestamp) - new Date(readings[i - 1].timestamp);
      if (ms > threshold) {
        // Real outage gap: insert null sentinel and re-seed EMA.
        result.push({x: new Date(new Date(readings[i - 1].timestamp).getTime() + 1000), y: null});
        ema = raw;
      } else if (ms < RAW_TIER_MAX_MS) {
        // Dense raw tier: apply EMA smoothing.
        ema = _EMA_ALPHA * raw + (1 - _EMA_ALPHA) * ema;
      } else {
        // Aggregated tier: keep averaged value, re-seed EMA.
        ema = raw;
      }
    }
    result.push({x: new Date(readings[i].timestamp), y: ema});
  }
  return result;
}

// ── WebSocket ─────────────────────────────────────────────────────────────────
function setStatus(msg) {
  document.getElementById('status').textContent = msg;
}

function updateSync(d) {
  const stateEl   = document.getElementById('syncState');
  const localEl   = document.getElementById('syncLocal');
  const serverEl  = document.getElementById('syncServer');
  const diffEl    = document.getElementById('syncDiff');
  const pendEl    = document.getElementById('syncPending');
  const status    = d.status ?? 'unknown';
  stateEl.textContent = status;
  stateEl.className   = status === 'success'   ? 's-ok'
                      : status === 'started' || status === 'inProgress' ? 's-syncing'
                      : status === 'failure'    ? 's-error' : '';
  localEl.textContent  = d.localCommitId  ?? '—';
  serverEl.textContent = d.serverCommitId ?? '—';
  if (typeof d.localCommitId === 'number' && typeof d.serverCommitId === 'number') {
    const diff = d.serverCommitId - d.localCommitId;
    diffEl.textContent = diff === 0 ? '✓ up to date' : `${diff} behind`;
    diffEl.className   = diff === 0 ? 's-ok' : 's-behind';
  } else {
    diffEl.textContent = '';
  }
  pendEl.textContent = (typeof d.pendingPushCount === 'number' && d.pendingPushCount > 0)
    ? `(${d.pendingPushCount} pending push)` : '';
  pendEl.className = (d.pendingPushCount > 0) ? 's-behind' : '';
}

function setChartWindow(windowSecs) {
  const now = Date.now();
  const min = now - windowSecs * 1000;
  for (const m of METRICS) {
    charts[m.key].options.scales.x.min = min;
    charts[m.key].options.scales.x.max = now;
    charts[m.key].update('none');
  }
}

// ── EMA smoothing for live readings ───────────────────────────────────────────────
// Alpha = 0.05 → ~39 s time constant at 2 s polling, matching the visual
// smoothness of 5-min tier data.  Seeded from the last history point so there
// is no jump at the history→live transition.
// The meter gauges always display the raw reading for accuracy.
const _ema = {};
const _EMA_ALPHA = 0.05;

// Buffer for chunked history messages (final:false) — flushed when final:true arrives.
let _histBuf = [];

// Expand compact wire format {t, i, v:[mod,swr,pOut,pRef,hTemp,fan], s, a?}
// back to the full named format that applyReadings/appendReading/updateMeters expect.
// Returns the reading unchanged if it is already in full format (backward compat).
// Ensure a timestamp string is always parsed as UTC.
// Dart's toIso8601String() omits the Z suffix for local DateTimes, which
// Chrome then treats as *local* time rather than UTC — causing a 7-hour
// (PDT) offset.  Appending 'Z' when absent makes the parse unambiguous.
function _normaliseTs(ts) {
  if (!ts) return ts;
  return /[Zz]|[+-]\d\d:?\d\d$/.test(ts) ? ts : ts + 'Z';
}

function _expandReading(r) {
  if (!Array.isArray(r.v)) {
    // Backward-compat: full-format reading — just normalise the timestamp.
    return Object.assign({}, r, {timestamp: _normaliseTs(r.timestamp)});
  }
  const [modulation, swr, powerOut, powerRef, heatTemp, fanSpeed] = r.v;
  return {
    timestamp: new Date(r.t).toISOString(), // epoch ms → always UTC with Z
    transmitterId: r.i,
    modulation, swr, powerOut, powerRef, heatTemp, fanSpeed,
    status: r.s, alertLevel: r.a ?? null,
  };
}

function applyReadings(readings) {
  // Server may push up to 7 days; trim to the currently selected window
  // so the chart doesn't show more data than the user requested.
  const now = Date.now();
  const cutoff = now - currentWindow * 1000;
  const windowed = readings.filter(r => new Date(r.timestamp).getTime() >= cutoff);
  // Never replace chart data with an empty set — this would erase live readings
  // that appendReading() added while the history scan was still running.
  if (windowed.length === 0) return;
  for (const m of METRICS) {
    const ds = charts[m.key].data.datasets[0];
    ds.data = injectGaps(windowed, m.key, currentWindow);
    // Seed EMA from the last real history point so live appends start smooth.
    const lastReal = ds.data.findLast(p => p.y !== null);
    if (lastReal) _ema[m.key] = lastReal.y;
    // Segment callbacks colour each segment automatically — no static update needed.
    charts[m.key].options.scales.x.min = cutoff;
    charts[m.key].options.scales.x.max = now;
    charts[m.key].update('none');
  }
  if (windowed.length > 0) updateMeters(windowed[windowed.length - 1]);
}

function appendReading(r) {
  const firstDs = charts[METRICS[0].key].data.datasets[0];
  const lastReal = firstDs.data.findLast(p => p.y !== null);

  // Out-of-order: reading is older than the latest chart point.
  // Silently drop it \u2014 the 30-second periodic history push will include it in a
  // correctly sorted snapshot.  Requesting a full refresh here caused the
  // chart to flicker and clear on every sync catch-up item.
  if (lastReal && new Date(r.timestamp) < lastReal.x) return;

  // Normal in-order append with gap detection.
  let insertGap = false;
  if (lastReal) {
    const ms = new Date(r.timestamp) - lastReal.x;
    _addInterval(ms);
    insertGap = ms > _gapThreshold(_recentIntervals);
  }
  const now = Date.now();
  const cutoff = now - currentWindow * 1000;
  for (const m of METRICS) {
    const ds = charts[m.key].data.datasets[0];
    const raw = r[m.key];
    // Apply EMA: smooth the live reading to match visual character of history.
    // Reset EMA to the raw value after a gap so the line starts clean.
    if (_ema[m.key] === undefined || insertGap) {
      _ema[m.key] = raw;
    } else {
      _ema[m.key] = _EMA_ALPHA * raw + (1 - _EMA_ALPHA) * _ema[m.key];
    }
    if (insertGap) {
      const lr = ds.data.findLast(p => p.y !== null);
      if (lr) ds.data.push({x: new Date(lr.x.getTime() + 1000), y: null});
    }
    ds.data.push({x: new Date(r.timestamp), y: _ema[m.key]});
    // Trim old points outside the current window
    while (ds.data.length && ds.data[0].x.getTime() < cutoff) ds.data.shift();
    // Segment callbacks colour each segment automatically — no static update needed.
    charts[m.key].options.scales.x.min = cutoff;
    charts[m.key].options.scales.x.max = now;
    charts[m.key].update('none');
  }
  updateMeters(r); // meters always show the raw reading
}

function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws`);

  ws.addEventListener('open', () => {
    setStatus('Connected');
    _histBuf = []; // fresh connection — discard any stale partial buffer
    // Request initial history for the current window
    ws.send(JSON.stringify({action:'history', window: currentWindow}));
  });

  ws.addEventListener('message', ev => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'history') {
      // Accumulate chunks; flush only when final:true (or flag absent = legacy single send).
      _histBuf.push(...msg.data.map(_expandReading));
      if (msg.final !== false) { applyReadings(_histBuf); _histBuf = []; }
    }
    else if (msg.type === 'r') appendReading(_expandReading(msg.data));
    else if (msg.type === 'reading') appendReading(msg.data); // backward compat
    else if (msg.type === 'sync') updateSync(msg.data);
    else if (msg.type === 'config') applyConfig(msg.data);
  });

  ws.addEventListener('close', () => {
    _histBuf = []; // discard any partial history on disconnect
    setStatus('Disconnected — reconnecting…');
    setTimeout(connect, 3000);
  });

  ws.addEventListener('error', () => ws.close());
}

connect();

// Set initial x-axis bounds immediately so charts show the correct time range
// before any data arrives from the server.
setChartWindow(currentWindow);

// ── Time-window toolbar ───────────────────────────────────────────────────────
document.querySelectorAll('.toolbar button').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelector('.toolbar button.active').classList.remove('active');
    btn.classList.add('active');
    currentWindow = parseInt(btn.dataset.w, 10);
    setChartWindow(currentWindow);
    if (ws && ws.readyState === WebSocket.OPEN) {
      _histBuf = []; // discard any partial history before requesting new window
      ws.send(JSON.stringify({action:'history', window: currentWindow}));
    }
  });
});

// ── Tab navigation ────────────────────────────────────────────────────────────
document.querySelectorAll('.nav-tab').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelectorAll('.nav-tab').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.page').forEach(p => p.classList.remove('active'));
    btn.classList.add('active');
    document.getElementById('page-' + btn.dataset.tab).classList.add('active');
    // Trigger chart resize when switching to charts tab so canvases fill correctly.
    if (btn.dataset.tab === 'charts') {
      for (const m of METRICS) charts[m.key].resize();
    }
  });
});
</script>
</body>
</html>
''';
