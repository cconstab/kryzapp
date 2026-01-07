import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kryz_shared/kryz_shared.dart';
import '../services/config_service.dart';

class SettingsScreen extends StatefulWidget {
  final ConfigService configService;

  const SettingsScreen({Key? key, required this.configService}) : super(key: key);

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late DashboardConfig _config;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _config = widget.configService.config;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gauge Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            tooltip: 'Export Configuration',
            onPressed: _exportConfig,
          ),
          IconButton(
            icon: const Icon(Icons.upload),
            tooltip: 'Import Configuration',
            onPressed: _importConfig,
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reset to Defaults',
            onPressed: _resetToDefaults,
          ),
          if (_hasChanges)
            IconButton(
              icon: const Icon(Icons.save),
              tooltip: 'Save Changes',
              onPressed: _saveChanges,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          _buildInfoCard(),
          const SizedBox(height: 16),
          ..._config.gauges.entries.map((entry) => _buildGaugeConfigCard(entry.key, entry.value)),
        ],
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: Colors.blue.shade700),
                const SizedBox(width: 8),
                Text(
                  'Gauge Configuration',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.blue.shade700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Configure the scale and thresholds for each gauge. '
              'Warning threshold should be less than critical threshold.',
              style: TextStyle(fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGaugeConfigCard(String metricName, GaugeConfig config) {
    final displayNames = {
      'modulation': 'Modulation',
      'swr': 'SWR',
      'powerOut': 'Power Out',
      'powerRef': 'Power Ref',
      'heatTemp': 'Heat Temp',
      'fanSpeed': 'Fan Speed',
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: ExpansionTile(
        title: Text(
          displayNames[metricName] ?? metricName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('${config.unit} • Range: ${config.minValue} - ${config.maxValue}'),
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                _buildNumberField(
                  label: 'Minimum Value',
                  value: config.minValue,
                  onChanged: (value) => _updateConfig(
                    metricName,
                    config.copyWith(minValue: value),
                  ),
                ),
                const SizedBox(height: 12),
                _buildNumberField(
                  label: 'Maximum Value',
                  value: config.maxValue,
                  onChanged: (value) => _updateConfig(
                    metricName,
                    config.copyWith(maxValue: value),
                  ),
                ),
                const SizedBox(height: 12),
                const Divider(),
                const Text('Low-Side Thresholds (optional)', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                _buildNumberField(
                  label: 'Critical Low Threshold',
                  value: config.criticalLowThreshold ?? 0,
                  onChanged: (value) => _updateConfig(
                    metricName,
                    config.copyWith(criticalLowThreshold: value),
                  ),
                  helperText: 'Red indicator appears below this value (0 = disabled)',
                ),
                const SizedBox(height: 12),
                _buildNumberField(
                  label: 'Warning Low Threshold',
                  value: config.warningLowThreshold ?? 0,
                  onChanged: (value) => _updateConfig(
                    metricName,
                    config.copyWith(warningLowThreshold: value),
                  ),
                  helperText: 'Yellow indicator appears below this value (0 = disabled)',
                ),
                const SizedBox(height: 12),
                const Divider(),
                const Text('High-Side Thresholds (optional)', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                _buildNumberField(
                  label: 'Warning High Threshold',
                  value: config.warningHighThreshold ?? 0,
                  onChanged: (value) => _updateConfig(
                    metricName,
                    config.copyWith(warningHighThreshold: value),
                  ),
                  helperText: 'Yellow indicator appears above this value (0 = disabled)',
                ),
                const SizedBox(height: 12),
                _buildNumberField(
                  label: 'Critical High Threshold',
                  value: config.criticalHighThreshold ?? 0,
                  onChanged: (value) => _updateConfig(
                    metricName,
                    config.copyWith(criticalHighThreshold: value),
                  ),
                  helperText: 'Red indicator appears above this value (0 = disabled)',
                ),
                const SizedBox(height: 12),
                const Divider(),
                _buildTextField(
                  label: 'Unit',
                  value: config.unit,
                  onChanged: (value) => _updateConfig(
                    metricName,
                    config.copyWith(unit: value),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNumberField({
    required String label,
    required double value,
    required Function(double) onChanged,
    String? helperText,
  }) {
    return TextFormField(
      initialValue: value.toString(),
      decoration: InputDecoration(
        labelText: label,
        helperText: helperText,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
      ],
      onChanged: (text) {
        final newValue = double.tryParse(text);
        if (newValue != null) {
          onChanged(newValue);
        }
      },
    );
  }

  Widget _buildTextField({
    required String label,
    required String value,
    required Function(String) onChanged,
  }) {
    return TextFormField(
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: onChanged,
    );
  }

  void _updateConfig(String metricName, GaugeConfig newConfig) {
    setState(() {
      final gauges = Map<String, GaugeConfig>.from(_config.gauges);
      gauges[metricName] = newConfig;
      _config = DashboardConfig(gauges: gauges);
      _hasChanges = true;
    });
  }

  Future<void> _saveChanges() async {
    try {
      await widget.configService.saveConfig(_config);
      setState(() {
        _hasChanges = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Configuration saved successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save configuration: $e')),
        );
      }
    }
  }

  Future<void> _exportConfig() async {
    try {
      final jsonString = widget.configService.exportConfigAsJson();
      await Clipboard.setData(ClipboardData(text: jsonString));

      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Configuration Exported'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Configuration has been copied to clipboard.'),
                  const SizedBox(height: 16),
                  Container(
                    constraints: const BoxConstraints(maxHeight: 400),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade900,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        jsonString,
                        style: const TextStyle(
                          fontFamily: 'Courier',
                          fontSize: 12,
                          color: Colors.greenAccent,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to export configuration: $e')),
        );
      }
    }
  }

  Future<void> _importConfig() async {
    final controller = TextEditingController();

    if (!mounted) return;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import Configuration'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Paste the JSON configuration below:'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Paste JSON here...',
              ),
              maxLines: 10,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Import'),
          ),
        ],
      ),
    );

    if (result == true && controller.text.isNotEmpty) {
      try {
        final newConfig = await widget.configService.importConfigFromJson(controller.text);
        setState(() {
          _config = newConfig;
          _hasChanges = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Configuration imported successfully')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to import configuration: $e')),
          );
        }
      }
    }
  }

  Future<void> _resetToDefaults() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset to Defaults'),
        content: const Text('Are you sure you want to reset all gauge settings to their default values?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Reset'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        await widget.configService.resetToDefaults();
        setState(() {
          _config = widget.configService.config;
          _hasChanges = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Configuration reset to defaults')),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to reset configuration: $e')),
          );
        }
      }
    }
  }
}
