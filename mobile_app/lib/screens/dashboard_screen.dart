import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../services/at_service.dart';
import '../services/config_service.dart';
import '../providers/transmitter_provider.dart';
import '../widgets/gauge_widget.dart';
import '../widgets/status_card.dart';
import 'settings_screen.dart';

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
    _syncConfigWithAtProtocol();
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

  void _syncConfigWithAtProtocol() async {
    // When dashboard loads, connect ConfigService to AtClient and sync
    final atService = Provider.of<AtService>(context, listen: false);
    final configService = Provider.of<ConfigService>(context, listen: false);

    if (atService.atClient != null) {
      configService.setAtClient(atService.atClient);
      await configService.loadConfig(); // Load from atProtocol
      if (mounted) {
        setState(() {}); // Refresh UI with synced config
      }
    }
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
    final configService = Provider.of<ConfigService>(context);
    final config = configService.config;

    return Scaffold(
      appBar: AppBar(
        title: const Text('KRYZ Transmitter Monitor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => SettingsScreen(configService: configService),
                ),
              );
              // Refresh the screen when returning from settings
              if (mounted) {
                setState(() {});
              }
            },
          ),
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

                // Gauges - Row 1
                Row(
                  children: [
                    Expanded(
                      child: GaugeWidget(
                        title: 'Modulation',
                        value: stats?.modulation ?? 0,
                        min: config.getConfig('modulation').minValue,
                        max: config.getConfig('modulation').maxValue,
                        unit: config.getConfig('modulation').unit,
                        warningLowThreshold: config.getConfig('modulation').warningLowThreshold,
                        criticalLowThreshold: config.getConfig('modulation').criticalLowThreshold,
                        warningHighThreshold: config.getConfig('modulation').warningHighThreshold,
                        criticalHighThreshold: config.getConfig('modulation').criticalHighThreshold,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: GaugeWidget(
                        title: 'SWR',
                        value: stats?.swr ?? 1.0,
                        min: config.getConfig('swr').minValue,
                        max: config.getConfig('swr').maxValue,
                        unit: config.getConfig('swr').unit,
                        warningLowThreshold: config.getConfig('swr').warningLowThreshold,
                        criticalLowThreshold: config.getConfig('swr').criticalLowThreshold,
                        warningHighThreshold: config.getConfig('swr').warningHighThreshold,
                        criticalHighThreshold: config.getConfig('swr').criticalHighThreshold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Gauges - Row 2
                Row(
                  children: [
                    Expanded(
                      child: GaugeWidget(
                        title: 'Power Out',
                        value: stats?.powerOut ?? 0,
                        min: config.getConfig('powerOut').minValue,
                        max: config.getConfig('powerOut').maxValue,
                        unit: config.getConfig('powerOut').unit,
                        warningLowThreshold: config.getConfig('powerOut').warningLowThreshold,
                        criticalLowThreshold: config.getConfig('powerOut').criticalLowThreshold,
                        warningHighThreshold: config.getConfig('powerOut').warningHighThreshold,
                        criticalHighThreshold: config.getConfig('powerOut').criticalHighThreshold,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: GaugeWidget(
                        title: 'Power Ref',
                        value: stats?.powerRef ?? 0,
                        min: config.getConfig('powerRef').minValue,
                        max: config.getConfig('powerRef').maxValue,
                        unit: config.getConfig('powerRef').unit,
                        warningLowThreshold: config.getConfig('powerRef').warningLowThreshold,
                        criticalLowThreshold: config.getConfig('powerRef').criticalLowThreshold,
                        warningHighThreshold: config.getConfig('powerRef').warningHighThreshold,
                        criticalHighThreshold: config.getConfig('powerRef').criticalHighThreshold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Gauges - Row 3
                Row(
                  children: [
                    Expanded(
                      child: GaugeWidget(
                        title: 'Heat Temp',
                        value: stats?.heatTemp ?? 0,
                        min: config.getConfig('heatTemp').minValue,
                        max: config.getConfig('heatTemp').maxValue,
                        unit: config.getConfig('heatTemp').unit,
                        warningLowThreshold: config.getConfig('heatTemp').warningLowThreshold,
                        criticalLowThreshold: config.getConfig('heatTemp').criticalLowThreshold,
                        warningHighThreshold: config.getConfig('heatTemp').warningHighThreshold,
                        criticalHighThreshold: config.getConfig('heatTemp').criticalHighThreshold,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: GaugeWidget(
                        title: 'Fan Speed',
                        value: stats?.fanSpeed ?? 0,
                        min: config.getConfig('fanSpeed').minValue,
                        max: config.getConfig('fanSpeed').maxValue,
                        unit: config.getConfig('fanSpeed').unit,
                        warningLowThreshold: config.getConfig('fanSpeed').warningLowThreshold,
                        criticalLowThreshold: config.getConfig('fanSpeed').criticalLowThreshold,
                        warningHighThreshold: config.getConfig('fanSpeed').warningHighThreshold,
                        criticalHighThreshold: config.getConfig('fanSpeed').criticalHighThreshold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

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
