import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:at_client/at_client.dart' show SyncProgress, SyncStatus;
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
  });

  final String title;
  final String
      configKey; // key into DashboardConfig / GaugeConfig.getDefaults()
  final Color color;
  final double Function(TransmitterStats) extract;
}

// EMA smoothing alpha for live raw readings.  Gives a ~39 s time constant at
// a 2 s poll interval, matching the visual smoothness of the 5-min tier data.
// The header value always shows the unsmoothed reading for accuracy.
const _kEmaAlpha = 0.05;

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

/// Returns the gap threshold for a given chart window.
///
/// With MRTG-style tiered storage the cache can contain a mix of raw (2 s),
/// 5-minute and 1-hour tier readings.  Using the median inter-reading
/// interval as the threshold fails because the dense raw tier dominates the
/// distribution and assigns a ~6 s threshold to everything, turning every
/// 5-minute gap between tier-2 points into a break in the line.
///
/// Instead we use a fixed threshold that is comfortably above the coarsest
/// tier resolution visible in each window but well below a real outage:
///
/// | Window | Coarsest tier | Threshold | Real gap detectable |
/// |--------|---------------|-----------|---------------------|
/// | 1 h    | raw (2 s)     | 10 min    | ≥ 10 min outage     |
/// | 6 h    | 5 min avg     | 10 min    | ≥ 10 min outage     |
/// | 24 h   | 5 min avg     | 10 min    | ≥ 10 min outage     |
/// | 7 d    | 1 hour avg    | 2 h       | ≥ 2 h outage        |
Duration _gapThresholdForWindow(_Window window) => switch (window) {
      _Window.hour1 => const Duration(minutes: 10),
      _Window.hour6 => const Duration(minutes: 10),
      _Window.hour24 => const Duration(minutes: 10),
      _Window.days7 => const Duration(hours: 2),
    };

List<_DataPoint> _injectGaps(
  List<TransmitterStats> data,
  double Function(TransmitterStats) extract,
  _Window window,
) {
  if (data.length < 2) {
    return data.map((s) => _DataPoint(s.timestamp, extract(s))).toList();
  }
  final threshold = _gapThresholdForWindow(window);
  // Readings spaced < 30 s apart are raw 2 s tier — apply EMA to smooth them.
  // Readings spaced ≥ 30 s apart are aggregated (5-min/1-hour) — use their
  // value directly and re-seed the EMA so the smooth line continues cleanly
  // into the next dense raw section.
  const rawTierMaxInterval = Duration(seconds: 30);
  final result = <_DataPoint>[];
  double? ema;
  for (var i = 0; i < data.length; i++) {
    final raw = extract(data[i]);
    if (i == 0) {
      ema = raw;
    } else {
      final interval = data[i].timestamp.difference(data[i - 1].timestamp);
      if (interval > threshold) {
        // Real outage: insert null sentinel and re-seed EMA from the new reading.
        result.add(_DataPoint(
          data[i - 1].timestamp.add(const Duration(seconds: 1)),
          null,
        ));
        ema = raw;
      } else if (interval < rawTierMaxInterval) {
        // Dense raw tier: apply EMA smoothing.
        ema = _kEmaAlpha * raw + (1 - _kEmaAlpha) * ema!;
      } else {
        // Aggregated tier: keep the averaged value, re-seed EMA.
        ema = raw;
      }
    }
    result.add(_DataPoint(data[i].timestamp, ema));
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
  Stream<List<TransmitterStats>>? _stream;
  TransmitterProvider? _provider;

  void _rebuildStream(TransmitterProvider provider) {
    _provider = provider;
    _stream = provider.historyStream(widget.window.duration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // listen: false — we only want the provider reference, not a rebuild
    // subscription.  Rebuilding the stream on every notifyListeners() call
    // (which fires every 2 s with live readings) resets the StreamBuilder
    // snapshot to null, blanking the chart momentarily on each update.
    final provider = Provider.of<TransmitterProvider>(context, listen: false);

    // Create stream the first time the collection is ready, or if the
    // provider instance changes (re-authentication).
    if (provider.hasCollection && (_provider != provider || _stream == null)) {
      _rebuildStream(provider);
    }
  }

  @override
  void didUpdateWidget(_MetricsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.window != widget.window) {
      final provider = Provider.of<TransmitterProvider>(context, listen: false);
      if (provider.hasCollection) _rebuildStream(provider);
    }
  }

  void _ensureStream() {
    final provider = Provider.of<TransmitterProvider>(context, listen: false);
    if (provider.hasCollection && (_provider != provider || _stream == null)) {
      setState(() => _rebuildStream(provider));
    }
  }

  @override
  Widget build(BuildContext context) {
    // If the collection just became available (e.g. auth completed after
    // this widget was already built), create the stream now.  Using a
    // post-frame callback avoids calling setState during build.
    if (_stream == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureStream());
    }

    return StreamBuilder<List<TransmitterStats>>(
      stream: _stream, // null while collection not yet ready → empty snapshot
      builder: (context, snapshot) {
        final dataPoints = snapshot.data ?? [];
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

class _MetricCard extends StatefulWidget {
  const _MetricCard({
    required this.spec,
    required this.data,
    required this.window,
  });

  final _MetricSpec spec;
  final List<TransmitterStats> data;
  final _Window window;

  @override
  State<_MetricCard> createState() => _MetricCardState();
}

class _MetricCardState extends State<_MetricCard> with WidgetsBindingObserver {
  // Mutable chart data — mutated in place for incremental appends so that
  // Syncfusion can update only the changed points via [_ctrl.updateDataSource]
  // without rebuilding the full series.
  late List<_DataPoint> _chartPoints;
  ChartSeriesController? _ctrl;
  StreamSubscription<TransmitterStats>? _liveSub;

  // Axis bounds kept in state so they can be refreshed on each live point
  // without recomputing the full _injectGaps dataset.
  late DateTime _windowStart;
  late DateTime _windowEnd;

  // Most-recent metric value — updated cheaply on each live reading.
  double? _latestValue;

  // EMA state for live smoothing.  Seeded from the last history point in
  // _rebuildFull so there is no visual jump when live data begins appending.
  double? _ema;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rebuildFull(widget.data);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-subscribe whenever the provider instance changes (e.g. re-auth).
    _liveSub?.cancel();
    final provider = Provider.of<TransmitterProvider>(context, listen: false);
    _liveSub = provider.liveStream.listen(_onLivePoint);
  }

  @override
  void didUpdateWidget(_MetricCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebuild from the full data list whenever the window or the backing
    // dataset changes (triggered by historyStream bulk events: initial load,
    // sync completion, tier-collection refresh).  Live 2-second readings
    // arrive via _liveStream and are handled incrementally in _onLivePoint.
    if (oldWidget.window != widget.window ||
        !identical(oldWidget.data, widget.data)) {
      _rebuildFull(widget.data);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _liveSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // When the app returns to the foreground, rebuild from the current data
    // snapshot so the X-axis bounds are updated and any background-period gap
    // is rendered correctly.  The next historyStream emission (triggered by
    // the post-resume sync) will fill in any truly new tier data.
    if (state == AppLifecycleState.resumed) {
      setState(() => _rebuildFull(widget.data));
    }
  }

  // ── Data helpers ───────────────────────────────────────────────────────────

  /// Full rebuild of [_chartPoints] from [data].  Called on initial load and
  /// after bulk history events.  [_injectGaps] is only ever called here —
  /// live appends avoid it entirely.
  void _rebuildFull(List<TransmitterStats> data) {
    final now = DateTime.now();
    _windowStart = now.subtract(widget.window.duration);
    _windowEnd = now;
    // Re-filter with the same 'now' used for the axis bounds (same logic as
    // the old StatelessWidget build, prevents the "folds over itself" artifact).
    final windowed =
        data.where((s) => !s.timestamp.isBefore(_windowStart)).toList();
    _chartPoints = _injectGaps(windowed, widget.spec.extract, widget.window);
    _latestValue =
        windowed.isNotEmpty ? widget.spec.extract(windowed.last) : null;
    // Seed live EMA from the last *smoothed* chart point so appendReading
    // continues the line without a visible jump.
    _ema = _chartPoints
        .lastWhere((p) => p.value != null,
            orElse: () => _DataPoint(_windowStart, null))
        .value;
  }

  /// Incremental live-append handler.  Called every ~2 seconds for each new
  /// raw reading.  Old data points are immutable so we only need to:
  ///   1. Trim the oldest points that have scrolled outside the window.
  ///   2. Possibly insert a gap sentinel if a break in the data is detected.
  ///   3. Append the new point.
  /// Then tell Syncfusion exactly which indexes changed so it can update the
  /// canvas without re-rendering the entire series.
  void _onLivePoint(TransmitterStats stats) {
    final now = DateTime.now();
    final cutoff = now.subtract(widget.window.duration);

    // Drop points outside the current window.
    if (stats.timestamp.isBefore(cutoff)) return;

    // Drop out-of-order readings (e.g. a delayed notification arriving after
    // a more recent one has already been appended).  They will appear on the
    // next full rebuild triggered by the tier-notification or sync cycle.
    final lastReal = _chartPoints.lastWhere((p) => p.value != null,
        orElse: () => _DataPoint(cutoff, null));
    if (lastReal.value != null && stats.timestamp.isBefore(lastReal.time)) {
      return;
    }

    // ── Trim expired points from the front ──────────────────────────────────
    int trimCount = 0;
    while (trimCount < _chartPoints.length &&
        _chartPoints[trimCount].time.isBefore(cutoff)) {
      trimCount++;
    }
    final removedIndexes =
        trimCount > 0 ? List.generate(trimCount, (i) => i) : <int>[];
    if (trimCount > 0) _chartPoints.removeRange(0, trimCount);

    // ── Append new point (with gap sentinel if needed) ──────────────────────
    final toAdd = <_DataPoint>[];
    final lastNonNull = _chartPoints.lastWhere((p) => p.value != null,
        orElse: () => _DataPoint(cutoff, null));
    if (lastNonNull.value != null) {
      final gap = stats.timestamp.difference(lastNonNull.time);
      if (gap > _gapThresholdForWindow(widget.window)) {
        // Gap sentinel also resets the EMA so the smoothed line starts fresh
        // from the new reading rather than interpolating across the outage.
        _ema = null;
        toAdd.add(
            _DataPoint(lastNonNull.time.add(const Duration(seconds: 1)), null));
      }
    }
    final raw = widget.spec.extract(stats);
    _ema = _ema != null ? _kEmaAlpha * raw + (1 - _kEmaAlpha) * _ema! : raw;
    toAdd.add(_DataPoint(stats.timestamp, _ema));

    final addedStartIdx = _chartPoints.length;
    _chartPoints.addAll(toAdd);
    final addedIndexes = List.generate(toAdd.length, (i) => addedStartIdx + i);

    _latestValue = raw; // header shows the actual reading, not the EMA

    // Update axis bounds and header value (setState); tell Syncfusion about
    // the changed data indexes (updateDataSource — no full re-render).
    setState(() {
      _windowStart = cutoff;
      _windowEnd = now;
    });
    _ctrl?.updateDataSource(
      addedDataIndexes: addedIndexes.isEmpty ? null : addedIndexes,
      removedDataIndexes: removedIndexes.isEmpty ? null : removedIndexes,
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Thresholds come from ConfigService (user-configurable, synced via atProtocol)
    // so they always match the gauge screen — no hardcoding here.
    final cfg = Provider.of<ConfigService>(context, listen: false)
        .config
        .getConfig(widget.spec.configKey);

    final latestStr = _latestValue != null
        ? '${_latestValue!.toStringAsFixed(1)} ${cfg.unit}'
        : '—';

    // Alert status for the current reading — drives card border + value colour.
    final alertColor = _alertColorFromConfig(_latestValue, cfg);

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

    // Marker settings — always hidden; line charts look cleaner without dots
    // and the tooltip shows exact values on tap.
    const markerSettings = MarkerSettings(isVisible: false);

    // All charts use AreaSeries.  The border and fill colour follow the
    // alert state (green/orange/red) so the chart matches the gauge screen.
    final series = <CartesianSeries<_DataPoint, DateTime>>[
      AreaSeries<_DataPoint, DateTime>(
        dataSource: _chartPoints,
        xValueMapper: (p, _) => p.time,
        yValueMapper: (p, _) => p.value,
        emptyPointSettings: const EmptyPointSettings(mode: EmptyPointMode.gap),
        color: alertColor.withValues(alpha: 0.25),
        borderColor: alertColor,
        borderWidth: 2,
        markerSettings: markerSettings,
        onRendererCreated: (ctrl) => _ctrl = ctrl,
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
                Expanded(
                  child: Text(
                    widget.spec.title,
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
                  minimum: _windowStart,
                  maximum: _windowEnd,
                  majorGridLines: const MajorGridLines(
                      width: 0.3, color: Color(0x33888888)),
                  axisLine: const AxisLine(width: 0),
                  dateFormat: _dateFormatFor(widget.window),
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
                  activationMode: ActivationMode.longPress,
                  lineType: CrosshairLineType.vertical,
                  shouldAlwaysShow: false,
                ),
                tooltipBehavior: TooltipBehavior(
                  enable: true,
                  activationMode: ActivationMode.longPress,
                  header: widget.spec.title,
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
