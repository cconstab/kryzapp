# KRYZ Transmitter Monitoring System

An atPlatform-based application for real-time radio transmitter monitoring using SNMP.

## Architecture

This system consists of:

1. **KRYZ Transmitter** (Thing) - Radio transmitter with SNMP stats
2. **SNMP Collector** (Process) - Gathers stats via SNMP and sends notifications
3. **Mobile Application** (Thing) - Displays real-time gauges
4. **Bob** (Person) - User with @sign identity

## Components

### 1. SNMP Collector (`snmp_collector/`)
- Connects to transmitter via SNMP
- Formats data as JSON
- Sends notifications to authorized @signs via atPlatform

### 2. Mobile Application (`mobile_app/`)
- Flutter application
- Receives real-time notifications
- Displays transmitter stats as gauges

## Setup

### Prerequisites
- Dart SDK 3.0+
- Flutter SDK (for mobile app)
- atSign accounts (@signs) - Get free @signs at https://atsign.com

### Required @signs
- `@kryz_transmitter` - For the transmitter device
- `@snmp_collector` - For the collector process
- `@bob` - For the user

### Installation

1. Clone this repository
2. Set up SNMP Collector:
   ```bash
   cd snmp_collector
   dart pub get
   ```

3. Set up Mobile Application:
   ```bash
   cd mobile_app
   flutter pub get
   ```

## Configuration

See individual component READMEs for detailed configuration instructions.

## Running

### SNMP Collector
```bash
cd snmp_collector
dart run bin/snmp_collector.dart
```

### Mobile Application
```bash
cd mobile_app
flutter run
```

## atPlatform Integration

This application uses the atPlatform for:
- **Secure Communication**: End-to-end encrypted notifications
- **Authentication**: Each entity has its own @sign
- **Real-time Updates**: Notification service for live data streaming
- **Privacy**: Only authorized @signs can receive transmitter data

## License

MIT License
