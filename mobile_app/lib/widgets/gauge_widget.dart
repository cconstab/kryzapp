import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';

class GaugeWidget extends StatelessWidget {
  final String title;
  final double value;
  final double min;
  final double max;
  final String unit;
  final double? warningThreshold;
  final double? criticalThreshold;
  final bool showPointer;

  const GaugeWidget({
    Key? key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    this.warningThreshold,
    this.criticalThreshold,
    this.showPointer = false,
  }) : super(key: key);

  Color _getValueColor() {
    if (criticalThreshold != null && value >= criticalThreshold!) {
      return Colors.red;
    }
    if (warningThreshold != null && value >= warningThreshold!) {
      return Colors.orange;
    }
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SfRadialGauge(
              axes: <RadialAxis>[
                RadialAxis(
                  minimum: min,
                  maximum: max,
                  showLabels: true,
                  showTicks: true,
                  ranges: _buildRanges(),
                  pointers: <GaugePointer>[
                    NeedlePointer(
                      value: value,
                      enableAnimation: true,
                      animationDuration: 500,
                      needleColor: _getValueColor(),
                    ),
                  ],
                  annotations: <GaugeAnnotation>[
                    GaugeAnnotation(
                      widget: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            value.toStringAsFixed(1),
                            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: _getValueColor()),
                          ),
                          Text(unit, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                      angle: 90,
                      positionFactor: 0.5,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<GaugeRange> _buildRanges() {
    final ranges = <GaugeRange>[];

    if (warningThreshold == null && criticalThreshold == null) {
      // No thresholds, single green range
      ranges.add(GaugeRange(startValue: min, endValue: max, color: Colors.green.withOpacity(0.3)));
    } else {
      // Build ranges based on thresholds
      double start = min;

      if (warningThreshold != null) {
        ranges.add(GaugeRange(startValue: start, endValue: warningThreshold!, color: Colors.green.withOpacity(0.3)));
        start = warningThreshold!;
      }

      if (criticalThreshold != null) {
        ranges.add(GaugeRange(startValue: start, endValue: criticalThreshold!, color: Colors.orange.withOpacity(0.3)));

        ranges.add(GaugeRange(startValue: criticalThreshold!, endValue: max, color: Colors.red.withOpacity(0.3)));
      } else {
        ranges.add(GaugeRange(startValue: start, endValue: max, color: Colors.orange.withOpacity(0.3)));
      }
    }

    return ranges;
  }
}
