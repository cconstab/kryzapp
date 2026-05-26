import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';

class GaugeWidget extends StatefulWidget {
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

  @override
  State<GaugeWidget> createState() => _GaugeWidgetState();
}

class _GaugeWidgetState extends State<GaugeWidget>
    with SingleTickerProviderStateMixin {
  // Spring parameters matching the web dashboard's analog-needle feel.
  // The controller runs in normalised [0,1] space so the spring is
  // independent of each metric's physical range (e.g. 0–120 % vs 1–3.5 SWR).
  // ω₀ = √180 ≈ 13.4 rad/s → half-period ≈ 0.47 s; ζ = 20/(2·13.4) ≈ 0.75
  // → slightly underdamped: settles in ~0.4 s with a tiny graceful overshoot.
  static const _spring =
      SpringDescription(mass: 1.0, stiffness: 180, damping: 20);

  // Controller drives a normalised [0,1] needle position; we map back to
  // physical units in build().  Unbounded so overshoot past [0,1] is allowed.
  late AnimationController _controller;

  double _normalize(double v) {
    final range = widget.max - widget.min;
    return range != 0 ? (v - widget.min) / range : 0;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController.unbounded(vsync: this)
      ..value = _normalize(widget.value);
  }

  @override
  void didUpdateWidget(GaugeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _controller.animateWith(
        SpringSimulation(_spring, _controller.value, _normalize(widget.value), 0),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _getValueColor(double value) {
    // Check critical thresholds first
    if (widget.criticalHighThreshold != null &&
        value >= widget.criticalHighThreshold!) {
      return Colors.red;
    }
    if (widget.criticalLowThreshold != null &&
        value <= widget.criticalLowThreshold!) {
      return Colors.red;
    }

    // Check warning thresholds
    if (widget.warningHighThreshold != null &&
        value >= widget.warningHighThreshold!) {
      return Colors.orange;
    }
    if (widget.warningLowThreshold != null &&
        value <= widget.warningLowThreshold!) {
      return Colors.orange;
    }

    return Colors.green;
  }

  double? _calculateInterval() {
    final range = widget.max - widget.min;
    if (range <= 0) return null;

    // Target at most 5 label steps.  Find the smallest "nice" number
    // (1, 2, 5 × 10^n) that keeps the step count ≤ 5.
    const maxSteps = 5;
    final raw = range / maxSteps;
    final mag = _floorPow10(raw); // largest power of 10 ≤ raw
    final norm = raw / mag; // 1.0 – 9.9…

    double nice;
    if (norm <= 1)
      nice = 1;
    else if (norm <= 2)
      nice = 2;
    else if (norm <= 5)
      nice = 5;
    else
      nice = 10;

    return nice * mag;
  }

  /// Largest power of 10 that is ≤ [value].
  double _floorPow10(double value) {
    if (value <= 0) return 1;
    double p = 1;
    while (p * 10 <= value) p *= 10;
    while (p > value) p /= 10;
    return p;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;
    final titleFontSize = isSmallScreen ? 13.0 : 16.0;
    final valueFontSize = isSmallScreen ? 16.0 : 20.0;
    final unitFontSize = isSmallScreen ? 10.0 : 12.0;
    final padding = isSmallScreen ? 8.0 : 16.0;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Map normalised position back to physical gauge units.
        final animatedValue =
            widget.min + _controller.value * (widget.max - widget.min);
        return Card(
          elevation: 4,
          child: Padding(
            padding: EdgeInsets.all(padding),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: AspectRatio(
                    aspectRatio: 1.0,
                    child: SfRadialGauge(
                      axes: <RadialAxis>[
                        RadialAxis(
                          minimum: widget.min,
                          maximum: widget.max,
                          showLabels: true,
                          showTicks: true,
                          labelOffset: isSmallScreen ? 5 : 10,
                          axisLabelStyle: GaugeTextStyle(
                            fontSize: isSmallScreen ? 8 : 10,
                          ),
                          interval: _calculateInterval(),
                          ranges: _buildRanges(),
                          pointers: <GaugePointer>[
                            NeedlePointer(
                              value: animatedValue,
                              enableAnimation:
                                  false, // We handle animation ourselves
                              needleColor: _getValueColor(animatedValue),
                            ),
                          ],
                          annotations: <GaugeAnnotation>[
                            GaugeAnnotation(
                              widget: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    animatedValue.toStringAsFixed(1),
                                    style: TextStyle(
                                      fontSize: valueFontSize,
                                      fontWeight: FontWeight.bold,
                                      color: _getValueColor(animatedValue),
                                    ),
                                  ),
                                  Text(widget.unit,
                                      style: TextStyle(
                                          fontSize: unitFontSize,
                                          color: Colors.grey)),
                                ],
                              ),
                              angle: 90,
                              positionFactor: 0.5,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: isSmallScreen ? 4 : 8),
                Text(
                  widget.title,
                  style: TextStyle(
                      fontSize: titleFontSize, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<GaugeRange> _buildRanges() {
    final ranges = <GaugeRange>[];

    // No thresholds means all green
    if (widget.warningHighThreshold == null &&
        widget.criticalHighThreshold == null &&
        widget.warningLowThreshold == null &&
        widget.criticalLowThreshold == null) {
      ranges.add(GaugeRange(
          startValue: widget.min,
          endValue: widget.max,
          color: Colors.green.withOpacity(0.3)));
      return ranges;
    }

    // Build ranges based on thresholds
    // For metrics with both low and high thresholds (e.g., modulation)
    if (widget.criticalLowThreshold != null) {
      ranges.add(GaugeRange(
          startValue: widget.min,
          endValue: widget.criticalLowThreshold!,
          color: Colors.red.withOpacity(0.3)));
    }

    if (widget.warningLowThreshold != null) {
      final start = widget.criticalLowThreshold ?? widget.min;
      ranges.add(GaugeRange(
          startValue: start,
          endValue: widget.warningLowThreshold!,
          color: Colors.orange.withOpacity(0.3)));
    }

    // Green range in the middle
    final greenStart =
        widget.warningLowThreshold ?? widget.criticalLowThreshold ?? widget.min;
    final greenEnd = widget.warningHighThreshold ??
        widget.criticalHighThreshold ??
        widget.max;
    ranges.add(GaugeRange(
        startValue: greenStart,
        endValue: greenEnd,
        color: Colors.green.withOpacity(0.3)));

    if (widget.warningHighThreshold != null) {
      final end = widget.criticalHighThreshold ?? widget.max;
      ranges.add(GaugeRange(
          startValue: widget.warningHighThreshold!,
          endValue: end,
          color: Colors.orange.withOpacity(0.3)));
    }

    if (widget.criticalHighThreshold != null) {
      ranges.add(GaugeRange(
          startValue: widget.criticalHighThreshold!,
          endValue: widget.max,
          color: Colors.red.withOpacity(0.3)));
    }

    return ranges;
  }
}
