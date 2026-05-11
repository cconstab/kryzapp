import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_charts/charts.dart';
import 'package:at_client/at_client.dart' show CItem;
import 'package:kryz_shared/kryz_shared.dart';
import '../providers/transmitter_provider.dart';

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
    required this.unit,
    required this.color,
    required this.extract,
    this.warningHigh,
    this.criticalHigh,
    this.warningLow,
    this.criticalLow,
    this.isAreaChart = false,
  });

  final String title;
  final String unit;
  final Color color;
  final double Function(TransmitterStats) extract;
  final double? warningHigh;
  final double? criticalHigh;
  final double? warningLow;
  final double? criticalLow;
  final bool isAreaChart;
}

const _metrics = [
  _MetricSpec(
    title: 'Power Out',
    unit: 'W',
    color: Color(0xFF2196F3),
    extract: _powerOut,
    warningLow: 80,
    criticalLow: 50,
  ),
  _MetricSpec(
    title: 'Power Reflected',
    unit: 'W',
    color: Color(0xFFE53935),
    extract: _powerRef,
    warningHigh: 10,
    criticalHigh: 20,
  ),
  _MetricSpec(
    title: 'SWR',
    unit: ':1',
    color: Color(0xFFFF9800),
    extract: _swr,
    warningHigh: 1.8,
    criticalHigh: 3.0,
  ),
  _MetricSpec(
    title: 'Modulation',
    unit: '%',
    color: Color(0xFF4CAF50),
    extract: _modulation,
    warningLow: 60,
    criticalLow: 50,
    warningHigh: 104,
    criticalHigh: 105,
  ),
  _MetricSpec(
    title: 'Heat Sink Temp',
    unit: '°C',
    color: Color(0xFFF44336),
    extract: _heatTemp,
    warningHigh: 75,
    criticalHigh: 90,
    isAreaChart: true,
  ),
  _MetricSpec(
    title: 'Fan Speed',
    unit: 'RPM',
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
        body: TabBarView(
          children: [
            for (final w in _Window.values) _MetricsTab(window: w),
          ],
        ),
      ),
    );
  }
}

class _MetricsTab extends StatelessWidget {
  const _MetricsTab({required this.window});

  final _Window window;

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<TransmitterProvider>(context, listen: false);

    if (!provider.hasCollection) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text(
                'Waiting for collection…\nMake sure the app is authenticated.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return StreamBuilder<List<CItem<TransmitterStats>>>(
      stream: provider.historyStream(window.duration),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final items = snapshot.data ?? [];
        final dataPoints = items.map((i) => i.obj).toList();

        if (dataPoints.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bar_chart,
                      size: 64, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(
                    'No data in the last ${window.label}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Readings are collected while the SNMP collector is running.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: _metrics.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) =>
              _MetricCard(spec: _metrics[i], data: dataPoints, window: window),
        );
      },
    );
  }
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
    final latest = data.isNotEmpty ? spec.extract(data.last) : null;
    final latestStr =
        latest != null ? '${latest.toStringAsFixed(1)} ${spec.unit}' : '—';

    // Build threshold plot bands
    final plotBands = <PlotBand>[
      if (spec.warningHigh != null && spec.criticalHigh != null)
        PlotBand(
          start: spec.warningHigh,
          end: spec.criticalHigh,
          color: Colors.orange.withOpacity(0.15),
        ),
      if (spec.criticalHigh != null)
        PlotBand(
          start: spec.criticalHigh,
          end: double.infinity,
          color: Colors.red.withOpacity(0.15),
        ),
      if (spec.warningLow != null && spec.criticalLow != null)
        PlotBand(
          start: spec.criticalLow,
          end: spec.warningLow,
          color: Colors.orange.withOpacity(0.15),
        ),
      if (spec.criticalLow != null)
        PlotBand(
          start: double.negativeInfinity,
          end: spec.criticalLow,
          color: Colors.red.withOpacity(0.15),
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
              color: spec.color.withOpacity(0.4),
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
                        color: spec.color,
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
                  majorGridLines: const MajorGridLines(width: 0),
                  axisLine: const AxisLine(width: 0),
                  dateFormat: _dateFormatFor(window),
                  intervalType: _intervalTypeFor(window),
                  interval: _intervalFor(window),
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
                tooltipBehavior: TooltipBehavior(
                  enable: true,
                  format: 'point.x\npoint.y ${spec.unit}',
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
        return DateFormat('HH:mm');
      case _Window.hour24:
        return DateFormat('HH:mm');
      case _Window.days7:
        return DateFormat('MM/dd HH:mm');
    }
  }

  DateTimeIntervalType _intervalTypeFor(_Window w) {
    switch (w) {
      case _Window.hour1:
        return DateTimeIntervalType.minutes;
      case _Window.hour6:
        return DateTimeIntervalType.hours;
      case _Window.hour24:
        return DateTimeIntervalType.hours;
      case _Window.days7:
        return DateTimeIntervalType.days;
    }
  }

  double _intervalFor(_Window w) {
    switch (w) {
      case _Window.hour1:
        return 10; // tick every 10 min
      case _Window.hour6:
        return 1; // tick every 1 h
      case _Window.hour24:
        return 4; // tick every 4 h
      case _Window.days7:
        return 1; // tick every 1 day
    }
  }
}
