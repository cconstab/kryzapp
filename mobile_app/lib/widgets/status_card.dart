import 'package:flutter/material.dart';
import 'package:kryz_shared/kryz_shared.dart';

class StatusCard extends StatelessWidget {
  final TransmitterStats stats;
  final String? stationName;

  const StatusCard({
    Key? key,
    required this.stats,
    this.stationName,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      color: _getStatusColor(),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(_getStatusIcon(), size: 32, color: Colors.white),
                const SizedBox(width: 12),
                Text(
                  stationName ?? stats.transmitterId,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              stats.status,
              style: const TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.w500),
            ),
            if (stats.alertLevel != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: Text(
                  '${stats.alertLevel!.toUpperCase()} ALERT',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: _getStatusColor()),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Color _getStatusColor() {
    if (stats.status == 'FAULT') return Colors.red;
    if (stats.alertLevel == 'critical') return Colors.red;
    if (stats.alertLevel == 'warning') return Colors.orange;
    if (stats.status == 'ON_AIR') return Colors.green;
    if (stats.status == 'STANDBY') return Colors.blue;
    return Colors.grey;
  }

  IconData _getStatusIcon() {
    if (stats.status == 'FAULT') return Icons.error;
    if (stats.alertLevel != null) return Icons.warning;
    if (stats.status == 'ON_AIR') return Icons.radio;
    if (stats.status == 'STANDBY') return Icons.pause_circle;
    return Icons.help_outline;
  }
}
