# SNMP Collector

SNMP collector service that gathers transmitter statistics and sends them via atPlatform notifications.

## Features

- Collects radio transmitter stats via SNMP
- Converts data to JSON format
- Sends real-time notifications to authorized @signs
- Alert detection and notification
- Configurable poll interval

## Prerequisites

- Dart SDK 3.0+
- An @sign for the collector (e.g., `@snmp_collector`)
- .atKeys file for authentication

## Installation

```bash
cd snmp_collector
dart pub get
```

## Configuration

### Get Your @sign Keys

1. Visit https://atsign.com to get a free @sign
2. Use the onboarding process to generate your .atKeys file
3. Save the .atKeys file to `.atsign/@your_atsign_key.atKeys`

### SNMP Configuration

By default, the collector uses simulated data. To connect to a real SNMP device:

1. Edit `lib/services/snmp_service.dart`
2. Update the OID constants to match your transmitter's MIB:
   ```dart
   static const String oidPowerOutput = '1.3.6.1.4.1.YOUR.OID.HERE';
   static const String oidTemperature = '1.3.6.1.4.1.YOUR.OID.HERE';
   // ... etc
   ```

## Running

### Basic Usage

```bash
# Using default keys location (~/.atsign/keys/<atsign>_key.atKeys)
dart run bin/snmp_collector.dart \
  --atsign @snmp_collector \
  --receivers @cconstab,@bob

# Or specify keys file explicitly
dart run bin/snmp_collector.dart \
  --atsign @snmp_collector \
  --keys .atsign/@snmp_collector_key.atKeys \
  --receivers @cconstab,@bob
```

### With SNMP Configuration

```bash
dart run bin/snmp_collector.dart \
  --atsign @snmp_collector \
  --receivers @cconstab,@bob \
  --host 192.168.1.100 \
  --port 161 \
  --community public \
  --interval 5
```

### Command Line Options

- `--atsign` (-a): Your @sign for the collector (required)
- `--keys` (-k): Path to .atKeys file (optional, default: ~/.atsign/keys/<atsign>_key.atKeys)
- `--receivers` (-r): Comma-separated list of @signs to receive notifications (required)
- `--host` (-h): SNMP host address (default: 127.0.0.1)
- `--port` (-p): SNMP port (default: 161)
- `--community` (-c): SNMP community string (default: public)
- `--interval` (-i): Poll interval in seconds (default: 5)
- `--help`: Show help message

## Authorized Receivers

The collector sends notifications to the @signs you specify with the `--receivers` parameter.

- `@kryz_mobile` - Mobile application
- `@bob` - User

To add more receivers, edit the `authorizedReceivers` list in the config.

## Data Format

Transmitter stats are sent as JSON:

```json
{
  "transmitterId": "KRYZ-TX-001",
  "timestamp": "2026-01-06T12:34:56.789Z",
  "powerOutput": 4800.0,
  "temperature": 55.0,
  "vswr": 1.15,
  "frequency": 88.5,
  "status": "ON_AIR",
  "additionalMetrics": {
    "reflectedPower": 25.0,
    "modulationLevel": 95.0
  }
}
```

## Alert Thresholds

Alerts are triggered when:

- **Critical**: Temperature > 90°C, VSWR > 3.0, Status = FAULT
- **Warning**: Temperature > 75°C, VSWR > 1.8

## Troubleshooting

### Authentication Issues
- Ensure your .atKeys file is correct
- Verify your @sign is activated
- Check network connectivity to root.atsign.org

### SNMP Issues
- Verify transmitter IP address and port
- Check SNMP community string
- Ensure firewall allows SNMP traffic
- The service will use simulated data if SNMP fails

## Development

Run in verbose mode for debugging:

```bash
# The logger is already set to Level.ALL in main
dart run bin/snmp_collector.dart -a @snmp_collector -k .atsign/@snmp_collector_key.atKeys
```
