import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/at_service.dart';
import '../providers/transmitter_provider.dart';
import '../widgets/gauge_widget.dart';
import '../widgets/status_card.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    _setupNotificationListeners();
  }

  void _setupNotificationListeners() {
    final atService = Provider.of<AtService>(context, listen: false);
    final transmitterProvider = Provider.of<TransmitterProvider>(context, listen: false);

    atService.onStatsReceived = (stats) {
      transmitterProvider.updateStats(stats);
    };

    atService.onAlertReceived = (alert) {
      transmitterProvider.updateAlert(alert);
      _showAlertDialog(alert);
    };
  }

  void _showAlertDialog(Map<String, dynamic> alert) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning, color: alert['level'] == 'critical' ? Colors.red : Colors.orange),
            const SizedBox(width: 8),
            Text(alert['level']?.toUpperCase() ?? 'ALERT'),
          ],
        ),
        content: Text(alert['message'] ?? 'Unknown alert'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Provider.of<TransmitterProvider>(context, listen: false).clearAlert();
            },
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('KRYZ Transmitter Monitor'),
        actions: [
          Consumer<AtService>(
            builder: (context, atService, child) {
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Center(child: Text(atService.currentAtSign ?? '', style: const TextStyle(fontSize: 14))),
              );
            },
          ),
        ],
      ),
      body: Consumer<TransmitterProvider>(
        builder: (context, provider, child) {
          final hasData = provider.hasData;
          final stats = provider.currentStats;

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Status card or waiting message
                if (hasData && stats != null)
                  StatusCard(stats: stats)
                else
                  Card(
                    elevation: 4,
                    color: Colors.grey.shade700,
                    child: const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                ),
                              ),
                              SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  'Waiting for transmitter data...',
                                  style: TextStyle(
                                    fontSize: 18,
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Make sure the SNMP collector is running',
                            style: TextStyle(fontSize: 14, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),

                // Gauges
                Row(
                  children: [
                    Expanded(
                      child: GaugeWidget(
                        title: 'Power Output',
                        value: stats?.powerOutput ?? 0,
                        min: 0,
                        max: 6000,
                        unit: 'W',
                        warningThreshold: 4500,
                        criticalThreshold: 5500,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: GaugeWidget(
                        title: 'Temperature',
                        value: stats?.temperature ?? 0,
                        min: 0,
                        max: 120,
                        unit: '°C',
                        warningThreshold: 75,
                        criticalThreshold: 90,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                Row(
                  children: [
                    Expanded(
                      child: GaugeWidget(
                        title: 'VSWR',
                        value: stats?.vswr ?? 1.0,
                        min: 1.0,
                        max: 5.0,
                        unit: ':1',
                        warningThreshold: 1.8,
                        criticalThreshold: 3.0,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: GaugeWidget(
                        title: 'Frequency',
                        value: stats?.frequency ?? 88.5,
                        min: 80,
                        max: 100,
                        unit: 'MHz',
                        showPointer: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Additional metrics
                if (stats?.additionalMetrics != null) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Additional Metrics', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 12),
                          ...stats!.additionalMetrics!.entries.map((entry) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(entry.key, style: const TextStyle(fontSize: 14)),
                                  Text(
                                    entry.value.toString(),
                                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),

                // Last update timestamp
                Text(
                  stats != null
                      ? 'Last update: ${DateFormat('MMM dd, yyyy HH:mm:ss').format(stats.timestamp)}'
                      : 'Waiting for data...',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
