import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';

class GaugeWidget extends StatelessWidget {
  final String title;
  final double value;
  final double min;
  final double max;
  final String unit;
  final double? warningHighThreshold;
  final double? criticalHighThreshold;
  final double? warningLowThreshold;
  final double? criticalLowThreshold;
  final bool showPointer;

  const GaugeWidget({
    Key? key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    this.warningHighThreshold,
    this.criticalHighThreshold,
    this.warningLowThreshold,
    this.criticalLowThreshold,
    this.showPointer = false,
  }) : super(key: key);

  Color _getValueColor() {
    // Check critical thresholds first
    if (criticalHighThreshold != null && value >= criticalHighThreshold!) {
      return Colors.red;
    }
    if (criticalLowThreshold != null && value <= criticalLowThreshold!) {
      return Colors.red;
    }

    // Check warning thresholds
    if (warningHighThreshold != null && value >= warningHighThreshold!) {
      return Colors.orange;
    }
    if (warningLowThreshold != null && value <= warningLowThreshold!) {
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

    // No thresholds means all green
    if (warningHighThreshold == null &&
        criticalHighThreshold == null &&
        warningLowThreshold == null &&
        criticalLowThreshold == null) {
      ranges.add(GaugeRange(startValue: min, endValue: max, color: Colors.green.withOpacity(0.3)));
      return ranges;
    }

    // Build ranges based on thresholds
    // For metrics with both low and high thresholds (e.g., modulation)
    if (criticalLowThreshold != null) {
      ranges.add(GaugeRange(startValue: min, endValue: criticalLowThreshold!, color: Colors.red.withOpacity(0.3)));
    }

    if (warningLowThreshold != null) {
      final start = criticalLowThreshold ?? min;
      ranges.add(GaugeRange(startValue: start, endValue: warningLowThreshold!, color: Colors.orange.withOpacity(0.3)));
    }

    // Green range in the middle
    final greenStart = warningLowThreshold ?? criticalLowThreshold ?? min;
    final greenEnd = warningHighThreshold ?? criticalHighThreshold ?? max;
    ranges.add(GaugeRange(startValue: greenStart, endValue: greenEnd, color: Colors.green.withOpacity(0.3)));

    if (warningHighThreshold != null) {
      final end = criticalHighThreshold ?? max;
      ranges.add(GaugeRange(startValue: warningHighThreshold!, endValue: end, color: Colors.orange.withOpacity(0.3)));
    }

    if (criticalHighThreshold != null) {
      ranges.add(GaugeRange(startValue: criticalHighThreshold!, endValue: max, color: Colors.red.withOpacity(0.3)));
    }

    return ranges;
  }
}
