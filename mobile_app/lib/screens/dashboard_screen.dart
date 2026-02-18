import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'dart:async';
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
  Timer? _clockTimer;
  bool _alertActive = false; // Track if alert is currently active
  bool _alertAcknowledged = false; // Track if user has acknowledged this alert

  @override
  void initState() {
    super.initState();
    _setupNotificationListeners();
    _syncConfigWithAtProtocol();
    _startClockTimer();
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  void _startClockTimer() {
    // Update the UI every half second to keep the clock smooth
    _clockTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  void _setupNotificationListeners() {
    final atService = Provider.of<AtService>(context, listen: false);
    final transmitterProvider =
        Provider.of<TransmitterProvider>(context, listen: false);

    atService.onStatsReceived = (stats) {
      transmitterProvider.updateStats(stats);
    };

    atService.onAlertReceived = (alert) {
      transmitterProvider.updateAlert(alert);
      
      // Only show dialog if alert just became active AND user hasn't acknowledged it yet
      // Once acknowledged, don't show it again until alert clears and comes back
      if (!_alertActive) {
        _alertActive = true;
        _alertAcknowledged = false; // Reset acknowledgment for new alert condition
      }
      
      if (!_alertAcknowledged) {
        _alertAcknowledged = true;
        _showAlertDialog(alert);
      }
    };
  }

  String _hashAlert(Map<String, dynamic> alert) {
    return '${alert['message']}_${alert['level']}';
  }

  void _syncConfigWithAtProtocol() async {
    // When dashboard loads, connect ConfigService to AtClient and sync
    final atService = Provider.of<AtService>(context, listen: false);
    final configService = Provider.of<ConfigService>(context, listen: false);

    if (atService.atClient != null) {
      configService.setAtClient(atService.atClient);
      await configService
          .loadConfig(); // Load from atProtocol - will notify listeners
    }
  }

  void _handleLogout(BuildContext context) async {
    // Show confirmation dialog
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      // Reset the AtService
      final atService = Provider.of<AtService>(context, listen: false);
      atService.reset();

      // Clear transmitter data
      final transmitterProvider =
          Provider.of<TransmitterProvider>(context, listen: false);
      transmitterProvider.clearAlert();
    }
  }

  void _showAlertDialog(Map<String, dynamic> alert) {
    showDialog(
      context: context,
      barrierDismissible: false, // Force user to click OK
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.warning,
                color:
                    alert['level'] == 'critical' ? Colors.red : Colors.orange),
            const SizedBox(width: 8),
            Text(alert['level']?.toUpperCase() ?? 'ALERT'),
          ],
        ),
        content: Text(alert['message'] ?? 'Unknown alert'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              // Just close the dialog - _alertAcknowledged stays true
              // so it won't pop up again until alert condition clears
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
    final transmitterProvider = Provider.of<TransmitterProvider>(context);
    
    // Check if alert has been cleared - if so, reset the alert flags
    if (transmitterProvider.latestAlert == null && _alertActive) {
      _alertActive = false;
      _alertAcknowledged = false; // Ready to show modal again when alert returns
    }
    
    final now = DateTime.now();
    final timeFormat = DateFormat('HH:mm:ss');
    final dateFormat = DateFormat('MMM dd, yyyy');
    final screenWidth = MediaQuery.of(context).size.width;
    final isSmallScreen = screenWidth < 600;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('KRYZ Transmitter Monitor',
                style: TextStyle(fontSize: isSmallScreen ? 16 : 18)),
            Text(
              '${dateFormat.format(now)} • ${timeFormat.format(now)}',
              style: TextStyle(
                  fontSize: isSmallScreen ? 10 : 12,
                  fontWeight: FontWeight.normal),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) =>
                      SettingsScreen(configService: configService),
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
                padding: EdgeInsets.symmetric(
                    horizontal: isSmallScreen ? 8.0 : 16.0),
                child: Center(
                    child: Text(atService.currentAtSign ?? '',
                        style: TextStyle(fontSize: isSmallScreen ? 12 : 14))),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () => _handleLogout(context),
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
                  StatusCard(stats: stats, stationName: config.stationName)
                else if (provider.isDataStale)
                  Card(
                    elevation: 4,
                    color: Colors.red.shade700,
                    child: const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.warning,
                                  color: Colors.white, size: 24),
                              SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  'DATA TIMEOUT - No data received',
                                  style: TextStyle(
                                    fontSize: 18,
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Connection lost - Check SNMP collector and transmitter',
                            style:
                                TextStyle(fontSize: 14, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  )
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
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
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
                            style:
                                TextStyle(fontSize: 14, color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),

                // Responsive gauge grid
                LayoutBuilder(
                  builder: (context, constraints) {
                    // Determine number of columns based on screen width
                    int crossAxisCount;
                    double childAspectRatio;
                    double spacing;

                    if (constraints.maxWidth > 900) {
                      crossAxisCount = 3; // 3 columns for wide screens
                      childAspectRatio = 1.3;
                      spacing = 16;
                    } else if (constraints.maxWidth > 600) {
                      crossAxisCount = 2; // 2 columns for medium screens
                      childAspectRatio = 1.1;
                      spacing = 16;
                    } else {
                      crossAxisCount = 2; // 2 columns for small screens
                      childAspectRatio =
                          1.0; // More square to fit gauges better
                      spacing = 8; // Reduced spacing
                    }

                    final gaugeWidgets = [
                      GaugeWidget(
                        title: 'Modulation',
                        value: stats?.modulation ?? 0,
                        min: config.getConfig('modulation').minValue,
                        max: config.getConfig('modulation').maxValue,
                        unit: config.getConfig('modulation').unit,
                        warningLowThreshold:
                            config.getConfig('modulation').warningLowThreshold,
                        criticalLowThreshold:
                            config.getConfig('modulation').criticalLowThreshold,
                        warningHighThreshold:
                            config.getConfig('modulation').warningHighThreshold,
                        criticalHighThreshold: config
                            .getConfig('modulation')
                            .criticalHighThreshold,
                      ),
                      GaugeWidget(
                        title: 'SWR',
                        value: stats?.swr ?? 1.0,
                        min: config.getConfig('swr').minValue,
                        max: config.getConfig('swr').maxValue,
                        unit: config.getConfig('swr').unit,
                        warningLowThreshold:
                            config.getConfig('swr').warningLowThreshold,
                        criticalLowThreshold:
                            config.getConfig('swr').criticalLowThreshold,
                        warningHighThreshold:
                            config.getConfig('swr').warningHighThreshold,
                        criticalHighThreshold:
                            config.getConfig('swr').criticalHighThreshold,
                      ),
                      GaugeWidget(
                        title: 'Power Out',
                        value: stats?.powerOut ?? 0,
                        min: config.getConfig('powerOut').minValue,
                        max: config.getConfig('powerOut').maxValue,
                        unit: config.getConfig('powerOut').unit,
                        warningLowThreshold:
                            config.getConfig('powerOut').warningLowThreshold,
                        criticalLowThreshold:
                            config.getConfig('powerOut').criticalLowThreshold,
                        warningHighThreshold:
                            config.getConfig('powerOut').warningHighThreshold,
                        criticalHighThreshold:
                            config.getConfig('powerOut').criticalHighThreshold,
                      ),
                      GaugeWidget(
                        title: 'Power Ref',
                        value: stats?.powerRef ?? 0,
                        min: config.getConfig('powerRef').minValue,
                        max: config.getConfig('powerRef').maxValue,
                        unit: config.getConfig('powerRef').unit,
                        warningLowThreshold:
                            config.getConfig('powerRef').warningLowThreshold,
                        criticalLowThreshold:
                            config.getConfig('powerRef').criticalLowThreshold,
                        warningHighThreshold:
                            config.getConfig('powerRef').warningHighThreshold,
                        criticalHighThreshold:
                            config.getConfig('powerRef').criticalHighThreshold,
                      ),
                      GaugeWidget(
                        title: 'Heat Temp',
                        value: stats?.heatTemp ?? 0,
                        min: config.getConfig('heatTemp').minValue,
                        max: config.getConfig('heatTemp').maxValue,
                        unit: config.getConfig('heatTemp').unit,
                        warningLowThreshold:
                            config.getConfig('heatTemp').warningLowThreshold,
                        criticalLowThreshold:
                            config.getConfig('heatTemp').criticalLowThreshold,
                        warningHighThreshold:
                            config.getConfig('heatTemp').warningHighThreshold,
                        criticalHighThreshold:
                            config.getConfig('heatTemp').criticalHighThreshold,
                      ),
                      GaugeWidget(
                        title: 'Fan Speed',
                        value: stats?.fanSpeed ?? 0,
                        min: config.getConfig('fanSpeed').minValue,
                        max: config.getConfig('fanSpeed').maxValue,
                        unit: config.getConfig('fanSpeed').unit,
                        warningLowThreshold:
                            config.getConfig('fanSpeed').warningLowThreshold,
                        criticalLowThreshold:
                            config.getConfig('fanSpeed').criticalLowThreshold,
                        warningHighThreshold:
                            config.getConfig('fanSpeed').warningHighThreshold,
                        criticalHighThreshold:
                            config.getConfig('fanSpeed').criticalHighThreshold,
                      ),
                    ];

                    return GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: spacing,
                        mainAxisSpacing: spacing,
                        childAspectRatio: childAspectRatio,
                      ),
                      itemCount: gaugeWidgets.length,
                      itemBuilder: (context, index) => gaugeWidgets[index],
                    );
                  },
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
