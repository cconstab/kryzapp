# KRYZ Transmitter Monitoring System - Setup Guide

This guide will help you set up and run the complete KRYZ transmitter monitoring system using the atPlatform.

## Overview

The system consists of:
1. **SNMP Collector** - Dart application that collects transmitter stats
2. **Mobile Application** - Flutter app for monitoring
3. **Shared Models** - Common data structures

## Prerequisites

### Required Software
- **Dart SDK** 3.0 or later - [Download](https://dart.dev/get-dart)
- **Flutter SDK** 3.0 or later - [Download](https://flutter.dev/docs/get-started/install)
- **Git** - For version control

### Required @signs

You need at least 2 @signs (get free @signs at https://atsign.com):

1. `@snmp_collector` (or any name) - For the collector service
2. `@bob` (or any name) - For the mobile app user

### Get Your @signs

1. Visit https://atsign.com
2. Sign up for a free account
3. Claim your @signs
4. Download the .atKeys files for each @sign

## Step 1: Initial Setup

### 1.1 Clone or Download the Project

```bash
cd c:\Users\colin\kryzapp
```

### 1.2 Install Shared Package Dependencies

```bash
cd shared
dart pub get
cd ..
```

## Step 2: Set Up SNMP Collector

### 2.1 Install Dependencies

```bash
cd snmp_collector
dart pub get
```

### 2.2 Configure @sign Keys

1. Create the keys directory:
   ```powershell
   New-Item -ItemType Directory -Force -Path .atsign
   ```

2. Copy your @snmp_collector .atKeys file:
   ```powershell
   # Copy your downloaded .atKeys file to .atsign folder
   Copy-Item "C:\Path\To\Downloaded\@snmp_collector_key.atKeys" .atsign\
   ```

### 2.3 Configure Environment (Optional)

```bash
# Copy the example environment file
Copy-Item .env.example .env

# Edit .env with your settings
notepad .env
```

### 2.4 Run the Collector

```bash
# Basic run with simulated SNMP data
dart run bin\snmp_collector.dart `
  --atsign @snmp_collector `
  --keys .atsign\@snmp_collector_key.atKeys

# With real SNMP device
dart run bin\snmp_collector.dart `
  --atsign @snmp_collector `
  --keys .atsign\@snmp_collector_key.atKeys `
  --host 192.168.1.100 `
  --port 161 `
  --community public `
  --interval 5
```

## Step 3: Set Up Mobile Application

### 3.1 Install Dependencies

```bash
cd ..\mobile_app
flutter pub get
```

### 3.2 Configure Authorized Receivers

Edit `shared\lib\config\atsign_config.dart` and ensure your @sign is in the authorized list:

```dart
static const List<String> authorizedReceivers = [
  '@kryz_mobile',
  '@bob',  // Add your @sign here
];
```

### 3.3 Run the Mobile App

#### On Emulator/Simulator

```bash
# List available devices
flutter devices

# Run on specific device
flutter run -d <device-id>

# Or just run on default device
flutter run
```

#### On Physical Device

1. Connect your device via USB
2. Enable developer mode on the device
3. Run: `flutter run`

### 3.4 First-Time App Setup

1. Launch the app
2. Tap "Get Started"
3. Select or add your @sign
4. Authenticate with your credentials
5. The app will start receiving notifications automatically

## Step 4: Testing the System

### 4.1 Verify Collector is Running

You should see logs like:

```
INFO: 2026-01-06 12:34:56: Starting SNMP collection (polling every 5s)
INFO: 2026-01-06 12:34:56: Collected: TransmitterStats(id: KRYZ-TX-001, power: 4800.0W, ...)
FINE: 2026-01-06 12:34:56: Notifications sent successfully
```

### 4.2 Verify Mobile App Receives Data

The mobile app should:
- Show the transmitter ID and status
- Display gauges with current values
- Update every 5 seconds (or your configured interval)

### 4.3 Test Alert Notifications

To trigger an alert, modify the simulated data in `snmp_collector\lib\services\snmp_service.dart`:

```dart
temperature: 92.0,  // Above critical threshold (90°C)
```

Restart the collector and watch for alert dialogs in the mobile app.

## Step 5: Production Deployment

### 5.1 SNMP Collector as a Service

#### Windows Service

```powershell
# Create a batch file to run the collector
# Then use NSSM or Windows Task Scheduler to run it as a service
```

#### Linux Service

```bash
# Create systemd service file
sudo nano /etc/systemd/system/kryz-collector.service
```

```ini
[Unit]
Description=KRYZ SNMP Collector
After=network.target

[Service]
Type=simple
User=youruser
WorkingDirectory=/path/to/snmp_collector
ExecStart=/usr/bin/dart run bin/snmp_collector.dart --atsign @snmp_collector --keys .atsign/@snmp_collector_key.atKeys
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable kryz-collector
sudo systemctl start kryz-collector
```

### 5.2 Mobile App Production Build

#### Android

```bash
flutter build apk --release
# APK will be in: build\app\outputs\flutter-apk\app-release.apk
```

#### iOS

```bash
flutter build ios --release
# Then open in Xcode for final signing and deployment
```

## Troubleshooting

### Collector Issues

**Problem**: Authentication failed
**Solution**: 
- Verify .atKeys file path is correct
- Ensure @sign has been activated
- Check internet connectivity

**Problem**: SNMP timeout
**Solution**:
- Verify transmitter IP address
- Check firewall rules
- Ensure SNMP community string is correct
- The system will use simulated data if SNMP fails

### Mobile App Issues

**Problem**: Not receiving notifications
**Solution**:
- Ensure collector is running
- Verify @sign is in authorized receivers list
- Check app has network permission
- Restart the app

**Problem**: Onboarding fails
**Solution**:
- Check internet connectivity
- Verify @sign credentials
- Try clearing app data and re-onboarding

## Customization

### Adding More Receivers

Edit `shared\lib\config\atsign_config.dart`:

```dart
static const List<String> authorizedReceivers = [
  '@kryz_mobile',
  '@bob',
  '@alice',  // Add new receiver
  '@charlie',  // Add another receiver
];
```

### Adjusting Alert Thresholds

Edit `shared\lib\models\transmitter_stats.dart`:

```dart
bool get isHealthy {
  return status == 'ON_AIR' &&
      temperature < 80.0 &&  // Adjust threshold
      vswr < 2.0 &&          // Adjust threshold
      powerOutput > 0;
}
```

### Changing Poll Interval

When running the collector:

```bash
dart run bin\snmp_collector.dart ... --interval 10  # Poll every 10 seconds
```

### Customizing SNMP OIDs

Edit `snmp_collector\lib\services\snmp_service.dart`:

```dart
static const String oidPowerOutput = '1.3.6.1.4.1.YOUR.MIB.HERE';
```

## Support

For atPlatform specific questions:
- Documentation: https://docs.atsign.com
- GitHub: https://github.com/atsign-foundation
- Discord: https://discord.atsign.com

## Next Steps

1. ✅ Set up and run the collector
2. ✅ Set up and run the mobile app
3. ✅ Test the complete flow
4. 📝 Customize for your specific transmitter
5. 📝 Deploy to production
6. 📝 Monitor and maintain

Congratulations! Your KRYZ transmitter monitoring system is now running on the atPlatform! 🎉
