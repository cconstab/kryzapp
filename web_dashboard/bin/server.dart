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

  // ── Open the collection ───────────────────────────────────────────────────
  final collection = await atClient.collection<TransmitterStats>(
    'stats.kryz',
    const Duration(days: 7),
    fromJson: TransmitterStats.fromJson,
    typeTag: 'TransmitterStats',
  );
  _log.info('Collection opened (stats.kryz)');

  // Stream new readings to all connected WebSocket clients.
  // CItemUpdated carries only (owner, id) — fetch the item to get the domain obj.
  collection.updates.listen((event) async {
    final citem = await collection.getOrNull(event.id, event.owner);
    if (citem == null) return;
    final stats = citem.obj;
    _log.fine('New reading: ${stats.transmitterId} @ ${stats.timestamp}');
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
<div class="grid" id="grid"></div>

<script>
const METRICS = [
  {key:'powerOut',  label:'Power Out (W)',       color:'#2196F3'},
  {key:'powerRef',  label:'Power Reflected (W)',  color:'#E53935'},
  {key:'swr',       label:'SWR (:1)',              color:'#FF9800'},
  {key:'modulation',label:'Modulation (%)',        color:'#4CAF50'},
  {key:'heatTemp',  label:'Heat Sink Temp (°C)',   color:'#F44336'},
  {key:'fanSpeed',  label:'Fan Speed (RPM)',        color:'#9C27B0'},
];

const charts = {};
let ws;
let currentWindow = 3600;

// ── Build chart cards ─────────────────────────────────────────────────────────
const grid = document.getElementById('grid');
for (const m of METRICS) {
  const card = document.createElement('div');
  card.className = 'card';
  card.innerHTML = `<h2>${m.label}</h2><canvas id="c_${m.key}"></canvas>`;
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
      scales: {
        x: {
          type: 'time',
          grid: {color:'#333'},
          ticks: {color:'#aaa', maxTicksLimit:6},
        },
        y: {
          grid: {color:'#333'},
          ticks: {color:'#aaa'},
        },
      },
      plugins: {legend:{display:false}},
    },
  });
}

// ── Gap detection ─────────────────────────────────────────────────────────────
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

function applyReadings(readings) {
  for (const m of METRICS) {
    const ds = charts[m.key].data.datasets[0];
    ds.data = injectGaps(readings, m.key);
    charts[m.key].update('none');
  }
}

function appendReading(r) {
  // Measure the interval once from the first metric (all share the same
  // timestamps) and decide whether to insert a gap sentinel.
  const firstDs = charts[METRICS[0].key].data.datasets[0];
  const lastReal = firstDs.data.findLast(p => p.y !== null);
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
