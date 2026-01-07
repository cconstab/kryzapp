import 'package:flutter/material.dart';
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

class _GaugeWidgetState extends State<GaugeWidget> with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;
  double _currentValue = 0.0;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.value;
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _animation = Tween<double>(begin: _currentValue, end: _currentValue).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(GaugeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _animation = Tween<double>(
        begin: _currentValue,
        end: widget.value,
      ).animate(
        CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
      );
      _animationController.forward(from: 0.0).then((_) {
        _currentValue = widget.value;
      });
    }
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  Color _getValueColor(double value) {
    // Check critical thresholds first
    if (widget.criticalHighThreshold != null && value >= widget.criticalHighThreshold!) {
      return Colors.red;
    }
    if (widget.criticalLowThreshold != null && value <= widget.criticalLowThreshold!) {
      return Colors.red;
    }

    // Check warning thresholds
    if (widget.warningHighThreshold != null && value >= widget.warningHighThreshold!) {
      return Colors.orange;
    }
    if (widget.warningLowThreshold != null && value <= widget.warningLowThreshold!) {
      return Colors.orange;
    }

    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final animatedValue = _animation.value;
        return Card(
          elevation: 4,
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SfRadialGauge(
                  axes: <RadialAxis>[
                    RadialAxis(
                      minimum: widget.min,
                      maximum: widget.max,
                      showLabels: true,
                      showTicks: true,
                      ranges: _buildRanges(),
                      pointers: <GaugePointer>[
                        NeedlePointer(
                          value: animatedValue,
                          enableAnimation: false, // We handle animation ourselves
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
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: _getValueColor(animatedValue),
                                ),
                              ),
                              Text(widget.unit, style: const TextStyle(fontSize: 12, color: Colors.grey)),
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
      ranges.add(GaugeRange(startValue: widget.min, endValue: widget.max, color: Colors.green.withOpacity(0.3)));
      return ranges;
    }

    // Build ranges based on thresholds
    // For metrics with both low and high thresholds (e.g., modulation)
    if (widget.criticalLowThreshold != null) {
      ranges.add(GaugeRange(
          startValue: widget.min, endValue: widget.criticalLowThreshold!, color: Colors.red.withOpacity(0.3)));
    }

    if (widget.warningLowThreshold != null) {
      final start = widget.criticalLowThreshold ?? widget.min;
      ranges.add(
          GaugeRange(startValue: start, endValue: widget.warningLowThreshold!, color: Colors.orange.withOpacity(0.3)));
    }

    // Green range in the middle
    final greenStart = widget.warningLowThreshold ?? widget.criticalLowThreshold ?? widget.min;
    final greenEnd = widget.warningHighThreshold ?? widget.criticalHighThreshold ?? widget.max;
    ranges.add(GaugeRange(startValue: greenStart, endValue: greenEnd, color: Colors.green.withOpacity(0.3)));

    if (widget.warningHighThreshold != null) {
      final end = widget.criticalHighThreshold ?? widget.max;
      ranges.add(
          GaugeRange(startValue: widget.warningHighThreshold!, endValue: end, color: Colors.orange.withOpacity(0.3)));
    }

    if (widget.criticalHighThreshold != null) {
      ranges.add(GaugeRange(
          startValue: widget.criticalHighThreshold!, endValue: widget.max, color: Colors.red.withOpacity(0.3)));
    }

    return ranges;
  }
}
