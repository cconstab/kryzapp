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

/// Convert a [DashboardConfig] to the `{type:'config', data:{...}}` WS payload.
Map<String, dynamic> _configPayload(DashboardConfig cfg) {
  return {
    'type': 'config',
    'data': {
      'stationName': cfg.stationName,
      'thresholds': cfg.gauges.map((key, g) => MapEntry(key, {
        'unit':     g.unit,
        'warnHigh': g.warningHighThreshold,
        'critHigh': g.criticalHighThreshold,
        'warnLow':  g.warningLowThreshold,
        'critLow':  g.criticalLowThreshold,
      })),
    },
  };
}

// ── History broadcast ────────────────────────────────────────────────────────
// Tracked so we can detect out-of-order readings from sync.
DateTime? _latestBroadcastTime;

// Collection reference stored globally so sync events can push history.
AtCollection<TransmitterStats>? _statsCollection;

/// Push a fresh history batch (last [secs] seconds) to all WS clients.
/// Called after each successful sync and on out-of-order readings so charts
/// always show a monotone, sorted dataset.
Future<void> _pushHistoryAll(int secs) async {
  if (_statsCollection == null || _clients.isEmpty) return;
  try {
    final cutoff = DateTime.now().subtract(Duration(seconds: secs));
    final items = await _statsCollection!
        .query()
        .where((item) => item.obj.timestamp.isAfter(cutoff))
        .orderBy((item) => item.obj.timestamp)
        .get();
    final readings = items.map((i) => i.obj.toJson()).toList();
    _broadcast({'type': 'history', 'data': readings});
    _log.fine('Pushed ${readings.length} history readings to ${_clients.length} client(s)');
  } catch (e) {
    _log.warning('_pushHistoryAll error: $e');
  }
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
        abbr: 'a', mandatory: true, help: 'atSign for reading the collection')
    ..addOption('keys',
        abbr: 'k',
        help: 'Path to .atKeys file '
            '(default: ~/.atsign/keys/<atsign>_key.atKeys)')
    ..addOption('host',
        abbr: 'H', defaultsTo: 'localhost', help: 'HTTP server bind address')
    ..addOption('port', abbr: 'p', defaultsTo: '8080', help: 'HTTP server port')
    ..addFlag('help', negatable: false, help: 'Show usage');

  final args = parser.parse(arguments);
  if (args['help'] as bool) {
    print('KRYZ Web Dashboard Server\n\nUsage:\n${parser.usage}');
    exit(0);
  }

  final atSign = args['atsign'] as String;
  final keysPath = args['keys'] as String? ??
      '${Platform.environment['HOME'] ?? Platform.environment['USERPROFILE']}'
          '/.atsign/keys/${atSign}_key.atKeys';
  final bindHost = args['host'] as String;
  final port = int.parse(args['port'] as String);

  // ── Authenticate ─────────────────────────────────────────────────────────
  _log.info('Authenticating $atSign …');

  final pref = cli.AtOnboardingPreference()
    ..rootDomain = 'root.atsign.org'
    ..namespace = 'kryz'
    ..hiveStoragePath = '.atsign/storage/$atSign'
    ..commitLogPath = '.atsign/storage/$atSign/commitLog'
    ..atKeysFilePath = keysPath;

  final onboarding = cli.AtOnboardingServiceImpl(atSign, pref);
  if (!await onboarding.authenticate()) {
    _log.severe('Authentication failed for $atSign');
    exit(1);
  }

  final atClient = AtClientManager.getInstance().atClient;
  _log.info('Authenticated as $atSign');

  // ── Register sync progress listener ──────────────────────────────────────
  atClient.syncService.addProgressListener(_SyncProgressBroadcaster());

  // ── Load & watch DashboardConfig (thresholds) ───────────────────────────
  Future<void> loadAndBroadcastConfig() async {
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
        // Fall back to shared defaults so the page still shows correct thresholds.
        _lastConfigPayload = _configPayload(DashboardConfig.defaults());
        _log.info('No stored config found — using defaults');
      }
    } catch (e) {
      _lastConfigPayload = _configPayload(DashboardConfig.defaults());
      _log.warning('Could not load DashboardConfig: $e — using defaults');
    }
    _broadcast(_lastConfigPayload!);
  }

  await loadAndBroadcastConfig();

  // Re-broadcast whenever the config changes.
  atClient.notificationService
      .subscribe(regex: '.*kryz_dashboard_config.*', shouldDecrypt: true)
      .listen((_) async {
    _log.info('Config change notification received — reloading');
    await loadAndBroadcastConfig();
  });

  // ── Open the collection ───────────────────────────────────────────────────
  final collection = await atClient.collection<TransmitterStats>(
    'stats.kryz',
    const Duration(days: 7),
    fromJson: TransmitterStats.fromJson,
    typeTag: 'TransmitterStats',
  );
  _log.info('Collection opened (stats.kryz)');
  _statsCollection = collection;

  // Stream new readings to all connected WebSocket clients.
  // CItemUpdated carries only (owner, id) — fetch the item to get the domain obj.
  collection.updates.listen((event) async {
    final citem = await collection.getOrNull(event.id, event.owner);
    if (citem == null) return;
    final stats = citem.obj;
    _log.fine('New reading: ${stats.transmitterId} @ ${stats.timestamp}');

    // If this reading is older than the latest one we've already sent, it is a
    // historical item arriving out-of-order during a sync catch-up.  Push a
    // full sorted history snapshot instead of an individual point so charts
    // stay monotone and don't show zigzag lines.
    if (_latestBroadcastTime != null &&
        stats.timestamp.isBefore(_latestBroadcastTime!)) {
      _log.info('Out-of-order reading (${stats.timestamp}) — pushing full history refresh');
      await _pushHistoryAll(604800);
      return;
    }
    _latestBroadcastTime = stats.timestamp;
    _broadcast({'type': 'reading', 'data': stats.toJson()});
  });

  // ── HTTP + WebSocket server ───────────────────────────────────────────────
  final router = Router()
    // Serve the static dashboard HTML
    ..get('/', _serveIndex)
    ..get('/index.html', _serveIndex)
    // REST endpoint: historical readings for a given window (seconds)
    ..get('/history', (Request req) async {
      final windowSecs =
          int.tryParse(req.url.queryParameters['window'] ?? '') ?? 3600;
      final items = await collection
          .query()
          .where((item) => item.obj.timestamp
              .isAfter(DateTime.now().subtract(Duration(seconds: windowSecs))))
          .orderBy((item) => item.obj.timestamp)
          .get();
      final readings = items.map((i) => i.obj.toJson()).toList();
      return Response.ok(
        jsonEncode(readings),
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
        // Proactively push current history (7 day max) so the client gets
        // data without needing to wait for its own request to round-trip.
        // applyReadings in the browser filters to the user's selected window.
        if (_statsCollection != null) {
          _pushHistoryAll(604800).ignore();
        }

        // When client requests historical data it sends:
        //   {"action": "history", "window": <seconds>}
        ws.stream.listen(
          (msg) async {
            try {
              final cmd = jsonDecode(msg as String) as Map<String, dynamic>;
              if (cmd['action'] == 'history') {
                final secs = (cmd['window'] as num?)?.toInt() ?? 3600;
                final items = await collection
                    .query()
                    .where((item) => item.obj.timestamp.isAfter(
                        DateTime.now().subtract(Duration(seconds: secs))))
                    .orderBy((item) => item.obj.timestamp)
                    .get();
                final readings = items.map((i) => i.obj.toJson()).toList();
                ws.sink.add(jsonEncode({'type': 'history', 'data': readings}));
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
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(360px,1fr));gap:12px}
  .card{background:#1a1a1a;border-radius:8px;padding:12px}
  .card h2{font-size:.85rem;margin-bottom:8px;opacity:.7}
  canvas{width:100%!important;height:160px!important}
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
  .sync-bar{display:flex;gap:16px;align-items:center;font-size:.78rem;margin-bottom:10px;
    padding:6px 12px;background:#1a1a1a;border-radius:6px;flex-wrap:wrap}
  .sync-bar .lbl{font-weight:600;opacity:.9}
  .sync-bar span{white-space:nowrap;opacity:.75}
  .s-ok{color:#4CAF50!important;opacity:1!important}
  .s-behind{color:#FF9800!important;opacity:1!important}
  .s-syncing{color:#2196F3!important;opacity:1!important}
  .s-error{color:#E53935!important;opacity:1!important}
</style>
</head>
<body>
<h1>⚡ KRYZ Transmitter — Live Metrics</h1>
<div class="toolbar">
  <button data-w="3600"  class="active">1 h</button>
  <button data-w="21600"         >6 h</button>
  <button data-w="86400"         >24 h</button>
  <button data-w="604800"        >7 d</button>
  <span id="status">Connecting…</span>
</div>
<div class="sync-bar" id="syncBar">
  <span class="lbl">Sync</span>
  <span>Status: <b id="syncState">—</b></span>
  <span>Local: <b id="syncLocal">—</b></span>
  <span>Server: <b id="syncServer">—</b></span>
  <span id="syncDiff"></span>
  <span id="syncPending"></span>
</div>
<div class="meters" id="meters"></div>
<div class="grid" id="grid"></div>

<script>
const METRICS = [
  {key:'modulation',label:'Modulation',        unit:'%',   color:'#4CAF50', warnLow:60,  critLow:50,  warnHigh:104, critHigh:105},
  {key:'swr',       label:'SWR',               unit:':1',  color:'#FF9800',                           warnHigh:1.8, critHigh:3.0},
  {key:'powerOut',  label:'Power Out',          unit:'W',   color:'#2196F3', warnLow:80,  critLow:50},
  {key:'powerRef',  label:'Power Reflected',    unit:'W',   color:'#E53935',                           warnHigh:10,  critHigh:20},
  {key:'heatTemp',  label:'Heat Sink Temp',     unit:'°C',  color:'#F44336',                           warnHigh:75,  critHigh:90},
  {key:'fanSpeed',  label:'Fan Speed',          unit:'RPM', color:'#9C27B0'},
];

const charts = {};
let ws;
let currentWindow = 3600;

// ── Build meter cards (live readout) ─────────────────────────────────────
const metersEl = document.getElementById('meters');
for (const m of METRICS) {
  const el = document.createElement('div');
  el.className = 'meter m-idle';
  el.id = 'm_' + m.key;
  el.innerHTML = `<div class="m-label">${m.label}</div><div class="m-value" id="mv_${m.key}">—</div><div class="m-unit">${m.unit}</div>`;
  metersEl.appendChild(el);
}

function _meterClass(m, v) {
  if (v === null || v === undefined) return 'm-idle';
  if ((m.critHigh !== undefined && v >= m.critHigh) ||
      (m.critLow  !== undefined && v <= m.critLow))  return 'm-crit';
  if ((m.warnHigh !== undefined && v >= m.warnHigh) ||
      (m.warnLow  !== undefined && v <= m.warnLow))  return 'm-warn';
  return 'm-ok';
}

function updateMeters(r) {
  _lastReading = r;
  for (const m of METRICS) {
    const v = r[m.key];
    const el = document.getElementById('m_' + m.key);
    const cls = _meterClass(m, v);
    el.className = 'meter ' + cls;
    document.getElementById('mv_' + m.key).textContent =
      (v !== null && v !== undefined) ? (+v).toFixed(1) : '—';
  }
}

// ── Build chart cards ─────────────────────────────────────────────────────────
const grid = document.getElementById('grid');
for (const m of METRICS) {
  const card = document.createElement('div');
  card.className = 'card';
  card.innerHTML = `<h2>${m.label} (${m.unit})</h2><canvas id="c_${m.key}"></canvas>`;
  grid.appendChild(card);

  const ctx = document.getElementById(`c_${m.key}`).getContext('2d');
  charts[m.key] = new Chart(ctx, {
    type: 'line',
    data: {datasets:[{
      label: m.label,
      data: [],
      borderColor: m.color,
      backgroundColor: m.color + '22',
      borderWidth: 2,
      pointRadius: 0,
      tension: 0.2,
      fill: m.key === 'heatTemp',
      spanGaps: false,   // null points produce a visible gap in the line
    }]},
    options: {
      animation: false,
      responsive: true,
      maintainAspectRatio: false,
      interaction: {mode: 'index', intersect: false},
      scales: {
        x: {
          type: 'time',
          time: {
            displayFormats: {
              millisecond: 'HH:mm:ss',
              second:      'HH:mm:ss',
              minute:      'HH:mm',
              hour:        'HH:mm',
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
          grid: {color:'#333'},
          ticks: {color:'#aaa'},
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
    if (t.warnHigh !== undefined) m.warnHigh = t.warnHigh;
    if (t.critHigh !== undefined) m.critHigh = t.critHigh;
    if (t.warnLow  !== undefined) m.warnLow  = t.warnLow;
    if (t.critLow  !== undefined) m.critLow  = t.critLow;
  }
  // Refresh meter colours with current data if we already have a reading.
  if (_lastReading) updateMeters(_lastReading);
}


// Gap threshold = 3× the median inter-reading interval, derived from the data.
// Stored as a rolling ring buffer so it adapts when the poll interval changes
// without any code change.
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

// Inject {x, y:null} sentinels into a batch of history readings so Chart.js
// draws a visible break over outage periods.  Also seeds the ring buffer.
function injectGaps(readings, key) {
  if (readings.length < 2) {
    return readings.map(r => ({x: new Date(r.timestamp), y: r[key]}));
  }
  // Collect all intervals; seed the ring buffer with the most recent ones.
  const allMs = [];
  for (let i = 1; i < readings.length; i++) {
    const ms = new Date(readings[i].timestamp) - new Date(readings[i - 1].timestamp);
    if (ms > 0) allMs.push(ms);
  }
  for (const ms of allMs.slice(-_MAX_INTERVALS)) _addInterval(ms);
  const threshold = _gapThreshold(allMs);
  const result = [];
  for (let i = 0; i < readings.length; i++) {
    if (i > 0) {
      const ms = new Date(readings[i].timestamp) - new Date(readings[i - 1].timestamp);
      if (ms > threshold) {
        result.push({x: new Date(new Date(readings[i - 1].timestamp).getTime() + 1000), y: null});
      }
    }
    result.push({x: new Date(readings[i].timestamp), y: readings[i][key]});
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

function applyReadings(readings) {
  // Server may push up to 7 days; trim to the currently selected window
  // so the chart doesn't show more data than the user requested.
  const cutoff = Date.now() - currentWindow * 1000;
  const windowed = readings.filter(r => new Date(r.timestamp).getTime() >= cutoff);
  for (const m of METRICS) {
    const ds = charts[m.key].data.datasets[0];
    ds.data = injectGaps(windowed, m.key);
    charts[m.key].update('none');
  }
  if (windowed.length > 0) updateMeters(windowed[windowed.length - 1]);
}

function appendReading(r) {
  // Detect out-of-order: if this reading is older than the last real point on
  // any chart, a historical sync catch-up item snuck through.  Re-request the
  // full sorted history snapshot instead of appending, which would create a
  // zigzag line jumping into the past and back.
  const firstDs = charts[METRICS[0].key].data.datasets[0];
  const lastReal = firstDs.data.findLast(p => p.y !== null);
  if (lastReal && new Date(r.timestamp) < lastReal.x) {
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({action:'history', window: currentWindow}));
    }
    return;
  }

  // Normal in-order append with gap detection.
  let insertGap = false;
  if (lastReal) {
    const ms = new Date(r.timestamp) - lastReal.x;
    _addInterval(ms);
    insertGap = ms > _gapThreshold(_recentIntervals);
  }
  for (const m of METRICS) {
    const ds = charts[m.key].data.datasets[0];
    if (insertGap) {
      const lr = ds.data.findLast(p => p.y !== null);
      if (lr) ds.data.push({x: new Date(lr.x.getTime() + 1000), y: null});
    }
    ds.data.push({x: new Date(r.timestamp), y: r[m.key]});
    // Trim old points outside the current window
    const cutoff = Date.now() - currentWindow * 1000;
    while (ds.data.length && ds.data[0].x.getTime() < cutoff) ds.data.shift();
    charts[m.key].update('none');
  }
  updateMeters(r);
}

function connect() {
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  ws = new WebSocket(`${proto}://${location.host}/ws`);

  ws.addEventListener('open', () => {
    setStatus('Connected');
    // Request initial history for the current window
    ws.send(JSON.stringify({action:'history', window: currentWindow}));
  });

  ws.addEventListener('message', ev => {
    const msg = JSON.parse(ev.data);
    if (msg.type === 'history') applyReadings(msg.data);
    else if (msg.type === 'reading') appendReading(msg.data);
    else if (msg.type === 'sync') updateSync(msg.data);
    else if (msg.type === 'config') applyConfig(msg.data);
  });

  ws.addEventListener('close', () => {
    setStatus('Disconnected — reconnecting…');
    setTimeout(connect, 3000);
  });

  ws.addEventListener('error', () => ws.close());
}

connect();

// ── Time-window toolbar ───────────────────────────────────────────────────────
document.querySelectorAll('.toolbar button').forEach(btn => {
  btn.addEventListener('click', () => {
    document.querySelector('.toolbar button.active').classList.remove('active');
    btn.classList.add('active');
    currentWindow = parseInt(btn.dataset.w, 10);
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({action:'history', window: currentWindow}));
    }
  });
});
</script>
</body>
</html>
''';
