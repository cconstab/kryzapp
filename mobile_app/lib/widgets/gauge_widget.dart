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

class _GaugeWidgetState extends State<GaugeWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _animationController;
  late Animation<double> _animation;
  double _currentValue = 0.0;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.value;
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 1200),
      vsync: this,
    );
    _animation =
        Tween<double>(begin: _currentValue, end: _currentValue).animate(
      CurvedAnimation(
          parent: _animationController, curve: Curves.easeInOutCubic),
    );
    // Start with the animation controller at 1.0 (completed)
    _animationController.value = 1.0;
  }

  @override
  void didUpdateWidget(GaugeWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      // Use the current animated value as the starting point for smoother transitions
      final currentAnimatedValue = _animation.value;
      _animation = Tween<double>(
        begin: currentAnimatedValue,
        end: widget.value,
      ).animate(
        CurvedAnimation(
            parent: _animationController, curve: Curves.easeInOutCubic),
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
    // Calculate appropriate interval to prevent label overlap
    final range = widget.max - widget.min;

    // For large ranges (like Fan Speed 0-8000), use larger intervals
    if (range > 5000) {
      return 2000; // Show labels at 0, 2000, 4000, 6000, 8000
    } else if (range > 1000) {
      return 500; // Show labels at reasonable intervals
    } else if (range > 100) {
      return 50;
    } else if (range > 50) {
      return 25;
    } else if (range > 10) {
      return 10;
    }
    // Let the gauge auto-calculate for small ranges
    return null;
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
      animation: _animation,
      builder: (context, child) {
        final animatedValue = _animation.value;
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
