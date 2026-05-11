# KRYZ Transmitter Monitoring System — Setup Guide

## Overview

Four packages make up the system:

| Package | Language | Purpose |
|---------|----------|---------|
| `shared/` | Dart | Shared data model + config |
| `snmp_collector/` | Dart (CLI) | Polls SNMP, writes `AtCollection`, sends alerts |
| `mobile_app/` | Flutter | Live gauges + historical charts (iOS/Android/macOS) |
| `web_dashboard/` | Dart (CLI) | shelf server → Chart.js browser dashboard |

---

## Prerequisites

| Requirement | Version | Download |
|-------------|---------|----------|
| Dart SDK | ≥ 3.0 | https://dart.dev/get-dart |
| Flutter SDK | ≥ 3.0 | https://flutter.dev/docs/get-started/install |
| @signs (≥ 2) | — | https://atsign.com (free) |

### @signs you need

- **Collector @sign** (e.g. `@snmp_collector`) — runs on the server/Raspberry Pi
- **Receiver @sign** (e.g. `@bob`) — used by the mobile app and/or web dashboard

Both @signs must be in `shared/lib/config/atsign_config.dart` → `KryzAtSigns.authorizedReceivers`.

Download the `.atKeys` file for each @sign from https://my.atsign.com.

---

## Step 1: Install dependencies

```bash
cd shared          && dart pub get   && cd ..
cd snmp_collector  && dart pub get   && cd ..
cd mobile_app      && flutter pub get && cd ..
cd web_dashboard   && dart pub get   && cd ..
```

---

## Step 2: Configure authorised receivers

Edit `shared/lib/config/atsign_config.dart`:

```dart
class KryzAtSigns {
  static const List<String> authorizedReceivers = [
    '@kryz_mobile',
    '@bob',           // add your receiver @sign(s) here
  ];
}
```

---

## Step 3: SNMP Collector

### 3.1 Place .atKeys file

```bash
mkdir -p snmp_collector/.atsign
cp ~/Downloads/@snmp_collector_key.atKeys snmp_collector/.atsign/
# or place the file at ~/.atsign/keys/@snmp_collector_key.atKeys
```

### 3.2 Run

```bash
cd snmp_collector
dart run bin/snmp_collector.dart \
  --atsign   @snmp_collector \
  --keys     .atsign/@snmp_collector_key.atKeys \
  --host     192.168.1.100 \   # transmitter IP; omit to use simulated data
  --port     161 \
  --community public \
  --interval 5                 # seconds between polls
```

### 3.3 Verify

Logs should show:

```
INFO: Authenticated as @snmp_collector
INFO: AtCollection initialised (stats.kryz, TTL 7d)
INFO: Appended reading: KRYZ-TX-001 @ 2026-05-10T12:00:00.000Z
```

---

## Step 4: Mobile App

### 4.1 Run

```bash
cd mobile_app
flutter run              # or flutter run -d <device-id>
```

### 4.2 First-time onboarding

1. Tap **Get Started**
2. Select or enter your receiver @sign (e.g. `@bob`)
3. Authenticate — the app loads your `.atKeys` from the device secure store
4. The dashboard opens automatically; gauges update as readings arrive

### 4.3 Historical charts

Tap the bar-chart icon (top-right of the dashboard) to open the **Metrics** screen.  
Select a time window (1 h / 6 h / 24 h / 7 d) and view `SfCartesianChart` plots for all 6 metrics.

### 4.4 Production build

```bash
# Android
flutter build apk --release
# -> build/app/outputs/flutter-apk/app-release.apk

# iOS (sign in Xcode after)
flutter build ios --release

# macOS
flutter build macos --release
```

---

## Step 5: Web Dashboard

The web dashboard is a Dart shelf server — `at_client` has no Flutter web support (platform keychain plugins have no web implementation), so the server authenticates with the atPlatform and forwards live data to any browser over WebSocket.

### 5.1 Place .atKeys file

```bash
# Use the same receiver @sign as the mobile app, or a dedicated one
mkdir -p web_dashboard/.atsign
cp ~/Downloads/@bob_key.atKeys web_dashboard/.atsign/
```

### 5.2 Run

```bash
cd web_dashboard
dart run bin/server.dart \
  --atsign @bob \
  --keys   .atsign/@bob_key.atKeys \
  --port   8080
```

Then open **http://localhost:8080** in any browser.

### 5.3 Run as a systemd service (Linux)

```ini
# /etc/systemd/system/kryz-dashboard.service
[Unit]
Description=KRYZ Web Dashboard
After=network.target

[Service]
Type=simple
User=youruser
WorkingDirectory=/path/to/kryzapp/web_dashboard
ExecStart=/usr/bin/dart run bin/server.dart \
  --atsign @bob \
  --keys .atsign/@bob_key.atKeys
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable kryz-dashboard
sudo systemctl start kryz-dashboard
```

---

## Step 6: Run SNMP Collector as a service (Linux)

```ini
# /etc/systemd/system/kryz-collector.service
[Unit]
Description=KRYZ SNMP Collector
After=network.target

[Service]
Type=simple
User=youruser
WorkingDirectory=/path/to/kryzapp/snmp_collector
ExecStart=/usr/bin/dart run bin/snmp_collector.dart \
  --atsign @snmp_collector \
  --keys .atsign/@snmp_collector_key.atKeys \
  --host 192.168.1.100
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable kryz-collector
sudo systemctl start kryz-collector
```

---

## Troubleshooting

### Collector: "Authentication failed"
- Verify `.atKeys` file path is correct
- Ensure the @sign has been activated at https://my.atsign.com
- Check internet connectivity

### Collector: "SNMP timeout"
- Verify the transmitter IP (`--host`)
- Check firewall rules allow UDP port 161
- Verify the SNMP community string (`--community`)
- The collector falls back to simulated data automatically

### Mobile app: no data after onboarding
1. Confirm the collector is running and logging "Appended reading"
2. Confirm your @sign is in `KryzAtSigns.authorizedReceivers`
3. Check `at_service.dart` — `_collectionSub` must be active

### Web dashboard: browser shows no charts
1. Server log must show "Dashboard running at http://…"
2. Open browser devtools → Network → WS — should see a `/ws` WebSocket
3. Ensure the server @sign is in `KryzAtSigns.authorizedReceivers`

---

## Customisation

### Change poll interval
```bash
dart run bin/snmp_collector.dart ... --interval 10
```

### Add a receiver @sign
`shared/lib/config/atsign_config.dart` → add to `authorizedReceivers`.

### Adjust alert thresholds
`shared/lib/models/transmitter_stats.dart` → `alertLevel` getter.

### Change web dashboard port
```bash
dart run bin/server.dart ... --port 9090
```

---

## Support

| Resource | URL |
|----------|-----|
| atPlatform docs | https://docs.atsign.com |
| Get @signs | https://atsign.com |
| at_client pub.dev | https://pub.dev/packages/at_client |
| Discord | https://discord.atsign.com |
