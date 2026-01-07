# KRYZ Mobile Application

Flutter mobile application for real-time KRYZ transmitter monitoring via atPlatform.

## Features

- Real-time transmitter status monitoring
- Visual gauges for key metrics (Power, Temperature, VSWR, Frequency)
- Alert notifications for critical conditions
- Secure end-to-end encrypted communication via atPlatform
- Works on iOS and Android

## Prerequisites

- Flutter SDK 3.0+
- An @sign for the user (e.g., `@bob`)
- .atKeys file for authentication

## Installation

```bash
cd mobile_app
flutter pub get
```

## Configuration

### Get Your @sign

1. Download the "at_app" or similar onboarding app from https://atsign.com
2. Claim a free @sign
3. The app will guide you through authentication

### First-time Setup

When you first run the app:

1. Tap "Get Started" on the welcome screen
2. Select your @sign from the list (or add a new one)
3. Authenticate using your @sign credentials
4. The app will automatically connect and start receiving notifications

## Running

### iOS Simulator / Android Emulator

```bash
flutter run
```

### Physical Device

```bash
# For iOS
flutter run -d <device-id>

# For Android
flutter run -d <device-id>

# List available devices
flutter devices
```

## Architecture

The app uses:

- **Provider** for state management
- **at_client_mobile** for atPlatform integration
- **Syncfusion Gauges** for visual displays
- **Shared models** from `kryz_shared` package

### Key Components

#### Services
- `AtService`: Manages atPlatform connection and notifications

#### Providers
- `TransmitterProvider`: Manages transmitter data state

#### Screens
- `OnboardingScreen`: Initial @sign authentication
- `DashboardScreen`: Main monitoring dashboard

#### Widgets
- `GaugeWidget`: Circular gauge with thresholds
- `StatusCard`: Transmitter status display

## Monitoring Metrics

### Power Output
- **Normal**: < 4500W
- **Warning**: 4500-5500W
- **Critical**: > 5500W

### Temperature
- **Normal**: < 75°C
- **Warning**: 75-90°C
- **Critical**: > 90°C

### VSWR (Voltage Standing Wave Ratio)
- **Normal**: < 1.8:1
- **Warning**: 1.8-3.0:1
- **Critical**: > 3.0:1

### Frequency
- Displays current transmitter frequency in MHz
- No threshold alerts (monitoring only)

## Receiving Notifications

The app subscribes to notifications from the SNMP collector. Ensure:

1. Your @sign is listed in the authorized receivers (see `shared/lib/config/atsign_config.dart`)
2. The SNMP collector is running and sending notifications
3. Your device has internet connectivity

## Troubleshooting

### Not Receiving Data
- Check that SNMP collector is running
- Verify your @sign is in the authorized receivers list
- Check network connectivity
- Look for errors in the logs

### Authentication Issues
- Ensure you have a valid @sign
- Try re-onboarding from the app
- Check that .atKeys file is not corrupted

### Performance Issues
- The app keeps the last 100 readings in history
- Old data is automatically pruned
- Restart the app if it becomes sluggish

## Building for Production

### Android

```bash
flutter build apk --release
# or for app bundle
flutter build appbundle --release
```

### iOS

```bash
flutter build ios --release
```

## Development

### Running in Debug Mode

```bash
flutter run --debug
```

### Hot Reload

While the app is running, press:
- `r` for hot reload
- `R` for hot restart
- `q` to quit

### Viewing Logs

```bash
flutter logs
```

## License

MIT License
