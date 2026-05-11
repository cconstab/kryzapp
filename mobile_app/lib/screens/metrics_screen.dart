import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:at_client/at_client.dart' show CItem, SyncProgress, SyncStatus;
import 'package:kryz_shared/kryz_shared.dart';
import '../providers/transmitter_provider.dart';
import '../services/at_service.dart';
import '../services/config_service.dart';

/// Time windows shown as tabs.  The label is displayed in the TabBar;
/// the [duration] is passed to [TransmitterProvider.historyStream].
enum _Window {
  hour1('1 h', Duration(hours: 1)),
  hour6('6 h', Duration(hours: 6)),
  hour24('24 h', Duration(hours: 24)),
  days7('7 d', Duration(days: 7));

  const _Window(this.label, this.duration);
  final String label;
  final Duration duration;
}

/// Descriptor for one metric chart.
class _MetricSpec {
  const _MetricSpec({
    required this.title,
    required this.configKey,
    required this.color,
    required this.extract,
    this.isAreaChart = false,
  });

  final String title;
  final String
      configKey; // key into DashboardConfig / GaugeConfig.getDefaults()
  final Color color;
  final double Function(TransmitterStats) extract;
  final bool isAreaChart;
}

const _metrics = [
  _MetricSpec(
    title: 'Modulation',
    configKey: 'modulation',
    color: Color(0xFF4CAF50),
    extract: _modulation,
  ),
  _MetricSpec(
    title: 'SWR',
    configKey: 'swr',
    color: Color(0xFFFF9800),
    extract: _swr,
  ),
  _MetricSpec(
    title: 'Power Out',
    configKey: 'powerOut',
    color: Color(0xFF2196F3),
    extract: _powerOut,
  ),
  _MetricSpec(
    title: 'Power Reflected',
    configKey: 'powerRef',
    color: Color(0xFFE53935),
    extract: _powerRef,
  ),
  _MetricSpec(
    title: 'Heat Sink Temp',
    configKey: 'heatTemp',
    color: Color(0xFFF44336),
    extract: _heatTemp,
    isAreaChart: true,
  ),
  _MetricSpec(
    title: 'Fan Speed',
    configKey: 'fanSpeed',
    color: Color(0xFF9C27B0),
    extract: _fanSpeed,
  ),
];

// Top-level extraction functions so they can be used in const constructors
double _powerOut(TransmitterStats s) => s.powerOut;
double _powerRef(TransmitterStats s) => s.powerRef;
double _swr(TransmitterStats s) => s.swr;
double _modulation(TransmitterStats s) => s.modulation;
double _heatTemp(TransmitterStats s) => s.heatTemp;
double _fanSpeed(TransmitterStats s) => s.fanSpeed;

// ── Gap handling ─────────────────────────────────────────────────────────────

/// A chart data point that can be either a real reading or a gap sentinel.
/// When [value] is null, [SfCartesianChart] renders a visual break in the
/// series line (requires [EmptyPointMode.gap] on the series).
class _DataPoint {
  const _DataPoint(this.time, this.value);
  final DateTime time;
  final double? value; // null → gap sentinel
}

/// Computes the median inter-reading interval from [data], then uses 3× that
/// as the gap threshold.  This is fully adaptive: if the poll interval is
/// changed at runtime the threshold automatically follows without any code
/// change.
Duration _adaptiveGapThreshold(List<TransmitterStats> data) {
  if (data.length < 2) return const Duration(days: 999); // no gaps possible
  final ms = <int>[];
  for (var i = 1; i < data.length; i++) {
    final diff =
        data[i].timestamp.difference(data[i - 1].timestamp).inMilliseconds;
    if (diff > 0) ms.add(diff);
  }
  if (ms.isEmpty) return const Duration(days: 999);
  ms.sort();
  final medianMs = ms[ms.length ~/ 2];
  return Duration(milliseconds: medianMs * 3);
}

List<_DataPoint> _injectGaps(
  List<TransmitterStats> data,
  double Function(TransmitterStats) extract,
) {
  if (data.length < 2) {
    return data.map((s) => _DataPoint(s.timestamp, extract(s))).toList();
  }
  final threshold = _adaptiveGapThreshold(data);
  final result = <_DataPoint>[];
  for (var i = 0; i < data.length; i++) {
    if (i > 0) {
      final gap = data[i].timestamp.difference(data[i - 1].timestamp);
      if (gap > threshold) {
        // Null point one second after the last real point breaks the line.
        result.add(_DataPoint(
          data[i - 1].timestamp.add(const Duration(seconds: 1)),
          null,
        ));
      }
    }
    result.add(_DataPoint(data[i].timestamp, extract(data[i])));
  }
  return result;
}

class MetricsScreen extends StatelessWidget {
  const MetricsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _Window.values.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Metrics History'),
          bottom: TabBar(
            tabs: [
              for (final w in _Window.values) Tab(text: w.label),
            ],
          ),
        ),
        body: Column(
          children: [
            Consumer<AtService>(
              builder: (context, atService, _) =>
                  _SyncStatusBar(sync: atService.latestSync),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  for (final w in _Window.values) _MetricsTab(window: w),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricsTab extends StatefulWidget {
  const _MetricsTab({required this.window});

  final _Window window;

  @override
  State<_MetricsTab> createState() => _MetricsTabState();
}

class _MetricsTabState extends State<_MetricsTab> {
  Stream<List<CItem<TransmitterStats>>>? _stream;
  TransmitterProvider? _provider;
  SyncProgress? _lastSync;

  void _rebuildStream(TransmitterProvider provider) {
    _provider = provider;
    _stream = provider.historyStream(widget.window.duration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final provider = Provider.of<TransmitterProvider>(context);
    final atService = Provider.of<AtService>(context);

    // Create stream the first time the collection is ready, or if the
    // provider instance changes (re-authentication).
    if (provider.hasCollection && (_provider != provider || _stream == null)) {
      _rebuildStream(provider);
    }

    // Recreate the stream after every successful sync so that historical
    // items that were just downloaded are immediately visible.  Without this
    // the watch() stream may not re-emit for items that arrived via sync.
    final sync = atService.latestSync;
    if (sync != null &&
        sync != _lastSync &&
        sync.syncStatus == SyncStatus.success &&
        provider.hasCollection) {
      _lastSync = sync;
      _rebuildStream(provider);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<CItem<TransmitterStats>>>(
      stream: _stream, // null while collection not yet ready → empty snapshot
      builder: (context, snapshot) {
        final dataPoints = (snapshot.data ?? []).map((i) => i.obj).toList();
        final isLoading = !snapshot.hasData;

        return Stack(
          children: [
            ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: _metrics.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _MetricCard(
                  spec: _metrics[i], data: dataPoints, window: widget.window),
            ),
            // Subtle banner shown while waiting for the first data.
            // Charts are visible behind it so the layout doesn't block.
            if (isLoading)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest
                        .withValues(alpha: 0.9),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('Syncing history…',
                            style: TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Returns green / orange / red depending on which threshold zone [value] sits in.
Color _alertColorFromConfig(double? value, GaugeConfig cfg) {
  if (value == null) return Colors.grey;
  if (cfg.criticalHighThreshold != null && value >= cfg.criticalHighThreshold!)
    return Colors.red;
  if (cfg.criticalLowThreshold != null && value <= cfg.criticalLowThreshold!)
    return Colors.red;
  if (cfg.warningHighThreshold != null && value >= cfg.warningHighThreshold!)
    return Colors.orange;
  if (cfg.warningLowThreshold != null && value <= cfg.warningLowThreshold!)
    return Colors.orange;
  return Colors.green;
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.spec,
    required this.data,
    required this.window,
  });

  final _MetricSpec spec;
  final List<TransmitterStats> data;
  final _Window window;

  @override
  Widget build(BuildContext context) {
    // Thresholds come from ConfigService (user-configurable, synced via atProtocol)
    // so they always match the gauge screen — no hardcoding here.
    final cfg = Provider.of<ConfigService>(context, listen: false)
        .config
        .getConfig(spec.configKey);

    final latest = data.isNotEmpty ? spec.extract(data.last) : null;
    final latestStr =
        latest != null ? '${latest.toStringAsFixed(1)} ${cfg.unit}' : '—';

    // Alert status for the current reading — drives card border + value colour.
    final alertColor = _alertColorFromConfig(latest, cfg);

    // Threshold lines: a 1.5 px line at each threshold value.
    // Only visible when the auto-scaled Y axis includes the threshold,
    // so they come into view as data approaches a limit.
    final plotBands = <PlotBand>[
      if (cfg.warningHighThreshold != null)
        PlotBand(
          start: cfg.warningHighThreshold,
          end: cfg.warningHighThreshold,
          borderColor: Colors.orange.withValues(alpha: 0.8),
          borderWidth: 1.5,
        ),
      if (cfg.criticalHighThreshold != null)
        PlotBand(
          start: cfg.criticalHighThreshold,
          end: cfg.criticalHighThreshold,
          borderColor: Colors.red.withValues(alpha: 0.8),
          borderWidth: 1.5,
        ),
      if (cfg.warningLowThreshold != null)
        PlotBand(
          start: cfg.warningLowThreshold,
          end: cfg.warningLowThreshold,
          borderColor: Colors.orange.withValues(alpha: 0.8),
          borderWidth: 1.5,
        ),
      if (cfg.criticalLowThreshold != null)
        PlotBand(
          start: cfg.criticalLowThreshold,
          end: cfg.criticalLowThreshold,
          borderColor: Colors.red.withValues(alpha: 0.8),
          borderWidth: 1.5,
        ),
    ];

    // Inject null sentinels at gaps so the chart shows a visible break
    // instead of a misleading diagonal line across the outage period.
    final points = _injectGaps(data, spec.extract);

    // Marker settings (disable for large datasets to keep rendering fast)
    final markerSettings = MarkerSettings(
      isVisible: data.length <= 60,
      height: 4,
      width: 4,
    );

    final series = spec.isAreaChart
        ? <CartesianSeries<_DataPoint, DateTime>>[
            AreaSeries<_DataPoint, DateTime>(
              dataSource: points,
              xValueMapper: (p, _) => p.time,
              yValueMapper: (p, _) => p.value,
              emptyPointSettings:
                  const EmptyPointSettings(mode: EmptyPointMode.gap),
              color: spec.color.withValues(alpha: 0.4),
              borderColor: spec.color,
              borderWidth: 2,
              markerSettings: markerSettings,
            ),
          ]
        : <CartesianSeries<_DataPoint, DateTime>>[
            LineSeries<_DataPoint, DateTime>(
              dataSource: points,
              xValueMapper: (p, _) => p.time,
              yValueMapper: (p, _) => p.value,
              emptyPointSettings:
                  const EmptyPointSettings(mode: EmptyPointMode.gap),
              color: spec.color,
              width: 2,
              markerSettings: markerSettings,
            ),
          ];

    return Card(
      shape: RoundedRectangleBorder(
        side: BorderSide(color: alertColor.withValues(alpha: 0.6), width: 1.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: spec.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    spec.title,
                    style: Theme.of(context)
                        .textTheme
                        .titleSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Text(
                  latestStr,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: alertColor,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            SizedBox(
              height: 160,
              child: SfCartesianChart(
                margin: EdgeInsets.zero,
                plotAreaBorderWidth: 0,
                primaryXAxis: DateTimeAxis(
                  isVisible: true,
                  majorGridLines: const MajorGridLines(
                      width: 0.3, color: Color(0x33888888)),
                  axisLine: const AxisLine(width: 0),
                  dateFormat: _dateFormatFor(window),
                  desiredIntervals: 5,
                  labelRotation: -35,
                  labelStyle: const TextStyle(fontSize: 9),
                ),
                primaryYAxis: NumericAxis(
                  isVisible: true,
                  plotBands: plotBands,
                  axisLine: const AxisLine(width: 0),
                  majorTickLines: const MajorTickLines(size: 0),
                  labelFormat: '{value}',
                  labelStyle: const TextStyle(fontSize: 9),
                ),
                crosshairBehavior: CrosshairBehavior(
                  enable: true,
                  activationMode: ActivationMode.singleTap,
                  lineType: CrosshairLineType.vertical,
                  shouldAlwaysShow: false,
                ),
                tooltipBehavior: TooltipBehavior(
                  enable: true,
                  header: spec.title,
                  format: 'point.x : point.y ${cfg.unit}',
                ),
                series: series,
              ),
            ),
          ],
        ),
      ),
    );
  }

  DateFormat _dateFormatFor(_Window w) {
    switch (w) {
      case _Window.hour1:
      case _Window.hour6:
      case _Window.hour24:
        return DateFormat('HH:mm');
      case _Window.days7:
        return DateFormat('MM/dd HH:mm');
    }
  }
}

// ── Sync status bar ───────────────────────────────────────────────────────────
class _SyncStatusBar extends StatelessWidget {
  const _SyncStatusBar({required this.sync});

  final SyncProgress? sync;

  @override
  Widget build(BuildContext context) {
    if (sync == null) return const SizedBox.shrink();

    final local = sync!.localCommitId;
    final server = sync!.serverCommitId;
    final pending = sync!.pendingPushCount ?? 0;
    final status = sync!.syncStatus;

    Color statusColor;
    String statusLabel;
    switch (status) {
      case SyncStatus.success:
        statusColor = Colors.green;
        statusLabel = 'synced';
        break;
      case SyncStatus.inProgress:
      case SyncStatus.started:
        statusColor = Colors.blue;
        statusLabel = 'syncing…';
        break;
      case SyncStatus.failure:
        statusColor = Colors.red;
        statusLabel = 'error';
        break;
      default:
        statusColor = Colors.grey;
        statusLabel = 'idle';
    }

    int? diff;
    if (local != null && server != null) diff = server - local;

    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.sync, size: 14, color: statusColor),
            const SizedBox(width: 6),
            Text(statusLabel,
                style: TextStyle(
                    fontSize: 11,
                    color: statusColor,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 12),
            Text('Local: ${local ?? '—'}',
                style: const TextStyle(fontSize: 11)),
            const SizedBox(width: 8),
            Text('Server: ${server ?? '—'}',
                style: const TextStyle(fontSize: 11)),
            if (diff != null) ...[
              const SizedBox(width: 8),
              Text(
                diff == 0 ? '✓ up to date' : '$diff behind',
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: diff == 0 ? Colors.green : Colors.orange),
              ),
            ],
            if (pending > 0) ...[
              const SizedBox(width: 8),
              Text('($pending pending)',
                  style: const TextStyle(fontSize: 11, color: Colors.orange)),
            ],
          ],
        ),
      ),
    );
  }
}
