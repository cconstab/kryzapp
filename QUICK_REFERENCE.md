# KRYZ Quick Reference Card

## 🚀 Quick Commands

### Install dependencies
```bash
cd shared          && dart pub get   && cd ..
cd snmp_collector  && dart pub get   && cd ..
cd mobile_app      && flutter pub get && cd ..
cd web_dashboard   && dart pub get   && cd ..
```

### Run Collector
```bash
cd snmp_collector
dart run bin/snmp_collector.dart \
  --atsign @snmp_collector \
  --keys ~/.atsign/keys/@snmp_collector_key.atKeys \
  --host 192.168.1.100
```

### Run Mobile App
```bash
cd mobile_app
flutter run
```

### Run Web Dashboard Server
```bash
cd web_dashboard
dart run bin/server.dart \
  --atsign @your_sign \
  --keys ~/.atsign/keys/@your_sign_key.atKeys
# Open http://localhost:8080 in any browser
```

---

## 📋 Package Reference

| Package | Role | @sign |
|---------|------|-------|
| `snmp_collector/` | Polls SNMP, writes AtCollection, sends alerts | `@snmp_collector` |
| `mobile_app/` | Flutter app — live gauges + historical charts | `@bob` (any receiver) |
| `web_dashboard/` | Dart shelf server → Chart.js browser dashboard | any authorised @sign |
| `shared/` | Shared models (`TransmitterStats`) + config | — |

---

## 🔗 Connection Reference

| From | To | Mechanism | Detail |
|------|----|-----------|--------|
| Transmitter | Collector | SNMP UDP:161 | Every 5 s |
| Collector | atServer | `AtCollection.create()` E2EE | Stats, 7-day TTL |
| Collector | atServer | `notificationService.notify()` | Alerts only, 5-min TTL |
| atServer | Mobile App | `collection.updates` stream | Sync on new item |
| atServer | Web Server | `collection.updates` stream | Sync on new item |
| Web Server | Browser | WebSocket JSON | Chart.js dashboard |

---

## 📊 TransmitterStats fields

```json
{
  "transmitterId": "KRYZ-TX-001",
  "timestamp":     "2026-05-10T12:00:00.000Z",
  "powerOut":      4800.0,   // Watts
  "powerRef":      50.0,     // Watts (reflected power)
  "swr":           1.15,     // SWR ratio
  "modulation":    92.0,     // %
  "heatTemp":      55.0,     // °C
  "fanSpeed":      1200,     // RPM
  "alertLevel":    null      // null | "warning" | "critical"
}
```

---

## ⚠️ Alert Thresholds

| Metric | Normal | Warning | Critical |
|--------|--------|---------|----------|
| Power Out | < 4500 W | 4500–5500 W | > 5500 W |
| Power Reflected | < 100 W | 100–300 W | > 300 W |
| SWR | < 1.8:1 | 1.8–3.0:1 | > 3.0:1 |
| Modulation | 80–105 % | 105–115 % | > 115 % |
| Heat Sink Temp | < 75 °C | 75–90 °C | > 90 °C |
| Fan Speed | > 500 RPM | 200–500 RPM | < 200 RPM |

---

## 🔑 atPlatform Quick Ref (at_client 3.12.0-rc.1)

### Open an AtCollection (collector side)
```dart
final collection = await atClient.collection<TransmitterStats>(
  'stats.kryz',
  Duration(days: 7),
  fromJson: TransmitterStats.fromJson,
  typeTag: 'TransmitterStats',
);
await collection.create(obj: stats, sharedWith: receivers);
```

### Watch for new items (mobile / web server)
```dart
// updates is Stream<CItemUpdated> — no type param, no embedded object
collection.updates.listen((event) async {
  final citem = await collection.getOrNull(event.id, event.owner);
  if (citem == null) return;
  final stats = citem.obj; // TransmitterStats
});
```

### Historical query (mobile MetricsScreen)
```dart
collection.query()
  .where((item) => item.obj.timestamp.isAfter(cutoff))
  .orderBy((item) => item.obj.timestamp)
  .watch(); // Stream<List<CItem<TransmitterStats>>>
```

### Send alert notification (collector)
```dart
await atClient.notificationService.notify(
  NotificationParams.forUpdate(
    AtKey()
      ..key = NotificationKeys.alertNotification  // 'alert'
      ..namespace = 'kryz'
      ..sharedWith = receiver
      ..metadata = (Metadata()..ttl = 300000),    // 5 min
    value: jsonEncode(alertData),
  ),
);
```

### Subscribe to alert notifications (mobile)
```dart
atClient.notificationService
  .subscribe(regex: '.*alert.*kryz')
  .listen((notification) { /* show modal */ });
```

---

## 📁 Key file locations

| Purpose | Path |
|---------|------|
| Authorised receivers | `shared/lib/config/atsign_config.dart` |
| Domain model | `shared/lib/models/transmitter_stats.dart` |
| SNMP OID map | `snmp_collector/lib/services/snmp_service.dart` |
| Collection writer | `snmp_collector/lib/services/at_collection_service.dart` |
| Alert sender | `snmp_collector/lib/services/at_notification_service.dart` |
| Mobile atPlatform service | `mobile_app/lib/services/at_service.dart` |
| State management | `mobile_app/lib/providers/transmitter_provider.dart` |
| Historical charts screen | `mobile_app/lib/screens/metrics_screen.dart` |
| Web server + embedded HTML | `web_dashboard/bin/server.dart` |

---

## 🛠️ Troubleshooting

### Collector won't start
```bash
dart --version          # Must be 3.0+
ls snmp_collector/.atsign/*.atKeys   # Keys must exist
```

### Mobile app build fails
```bash
flutter doctor
cd mobile_app && flutter clean && flutter pub get && flutter run
```

### No data appearing in mobile app
1. Confirm collector is running and logging "Appended reading"
2. Verify your @sign is in `KryzAtSigns.authorizedReceivers`
3. Check `collection.updates` subscription is active in `at_service.dart`

### Web dashboard shows no data
1. Confirm the web server authenticated ("Authenticated as @…" in logs)
2. Open browser devtools → Network → WS — should see the `/ws` connection
3. Check the server is connected to the same `stats.kryz` namespace

---

## 🔧 Common customisations

### Change poll interval
```bash
dart run bin/snmp_collector.dart ... --interval 10  # seconds
```

### Add a receiver @sign
`shared/lib/config/atsign_config.dart`:
```dart
static const List<String> authorizedReceivers = [
  '@kryz_mobile',
  '@bob',
  '@alice',   // new
];
```

### Adjust alert thresholds
`shared/lib/models/transmitter_stats.dart` — `alertLevel` getter.

---

## 📞 Resources

| Resource | URL |
|----------|-----|
| atPlatform docs | https://docs.atsign.com |
| Get @signs | https://atsign.com |
| pub.dev at_client | https://pub.dev/packages/at_client |
| Discord | https://discord.atsign.com |

---

## 🎯 Success Checklist

**Setup**
- [ ] Dart SDK 3.0+ installed
- [ ] Flutter SDK 3.0+ installed
- [ ] `dart pub get` / `flutter pub get` completed for all packages
- [ ] @signs obtained; `.atKeys` files downloaded

**Collector**
- [ ] `.atKeys` in `snmp_collector/.atsign/` (or `~/.atsign/keys/`)
- [ ] Collector logs "Authenticated" + "AtCollection initialised"
- [ ] Logs show "Appended reading" every 5 s

**Mobile App**
- [ ] App builds and runs
- [ ] Onboarding completed with receiver @sign
- [ ] Live gauges update; metrics screen shows charts

**Web Dashboard**
- [ ] Server logs "Dashboard running at http://…"
- [ ] Browser shows 6 live charts; time-window buttons work

.\quickstart.ps1 mobile

# Or manually
cd mobile_app
flutter run
```

---

## 📋 Node Reference

| Node | Type | @sign | Role |
|------|------|-------|------|
| KRYZ Transmitter | Thing | `@kryz_transmitter` | Hardware device with SNMP |
| SNMP Collector | Process | `@snmp_collector` | Polls SNMP, sends notifications |
| Mobile Application | Thing | `@kryz_mobile` | Displays data |
| Bob | Person | `@bob` | End user |

---

## 🔗 Connection Reference

| From | To | Type | Implementation |
|------|-----|------|----------------|
| Transmitter | Collector | Async | SNMP UDP:161 |
| Collector | Mobile App | Notification | `atClient.notify()` |

---

## 📊 Data Fields

```json
{
  "transmitterId": "KRYZ-TX-001",
  "timestamp": "ISO8601 string",
  "powerOutput": 4800.0,        // Watts
  "temperature": 55.0,          // Celsius  
  "vswr": 1.15,                 // Ratio
  "frequency": 88.5,            // MHz
  "status": "ON_AIR"            // ON_AIR|STANDBY|FAULT
}
```

---

## ⚠️ Alert Thresholds

### Temperature
- 🟢 **Normal**: < 75°C
- 🟡 **Warning**: 75-90°C  
- 🔴 **Critical**: > 90°C

### VSWR
- 🟢 **Normal**: < 1.8:1
- 🟡 **Warning**: 1.8-3.0:1
- 🔴 **Critical**: > 3.0:1

### Power Output
- 🟢 **Normal**: < 4500W
- 🟡 **Warning**: 4500-5500W
- 🔴 **Critical**: > 5500W

---

## 🔑 atPlatform Quick Ref

### Initialize atClient
```dart
final atClient = await AtClientManager.getInstance()
  .setCurrentAtSign(
    '@youratsign',
    'kryz',
    AtClientPreference()..namespace = 'kryz'
  );
```

### Send Notification
```dart
await atClient.notificationService.notify(
  NotificationParams.forUpdate(
    AtKey()
      ..key = 'transmitter_stats'
      ..namespace = 'kryz'
      ..sharedWith = '@receiver',
    value: jsonEncode(data)
  )
);
```

### Subscribe to Notifications
```dart
atClient.notificationService
  .subscribe(regex: '.*kryz')
  .listen((notification) {
    // Handle notification
  });
```

---

## 📁 File Locations

### Configuration
- **Authorized receivers**: `shared/lib/config/atsign_config.dart`
- **SNMP OIDs**: `snmp_collector/lib/services/snmp_service.dart`
- **Alert thresholds**: `shared/lib/models/transmitter_stats.dart`

### Keys
- **Collector keys**: `snmp_collector/.atsign/`
- **Mobile app keys**: Managed by at_onboarding_flutter

### Logs
- **Collector**: Console output (stdout)
- **Mobile app**: Flutter debug console

---

## 🛠️ Troubleshooting

### Collector Won't Start
```powershell
# Check Dart version
dart --version  # Should be 3.0+

# Check keys file exists
Test-Path snmp_collector\.atsign\*.atKeys

# Run with verbose output (already set to Level.ALL)
cd snmp_collector
dart run bin\snmp_collector.dart ...
```

### Mobile App Won't Build
```powershell
# Check Flutter version
flutter doctor

# Clean and rebuild
cd mobile_app
flutter clean
flutter pub get
flutter run
```

### Not Receiving Notifications
```dart
// 1. Check collector is running
// 2. Verify @sign in authorized list (shared/lib/config/atsign_config.dart)
static const List<String> authorizedReceivers = [
  '@bob',  // Your @sign here
];

// 3. Check mobile app subscription
atClient.notificationService.subscribe(regex: '.*kryz')
```

---

## 🔧 Common Customizations

### Change Poll Interval
```bash
dart run bin\snmp_collector.dart ... --interval 10  # 10 seconds
```

### Add Receiver
Edit `shared/lib/config/atsign_config.dart`:
```dart
static const List<String> authorizedReceivers = [
  '@kryz_mobile',
  '@bob',
  '@alice',  // New receiver
];
```

### Update SNMP OIDs
Edit `snmp_collector/lib/services/snmp_service.dart`:
```dart
static const String oidPowerOutput = '1.3.6.1.4.1.YOUR.OID';
```

### Adjust Thresholds
Edit `shared/lib/models/transmitter_stats.dart`:
```dart
String? get alertLevel {
  if (temperature > 85.0) return 'critical';  // Changed from 90
  if (temperature > 70.0) return 'warning';   // Changed from 75
  return null;
}
```

---

## 📞 Support Resources

| Resource | URL |
|----------|-----|
| **atPlatform Docs** | https://docs.atsign.com |
| **Get @signs** | https://atsign.com |
| **Discord** | https://discord.atsign.com |
| **GitHub** | https://github.com/atsign-foundation |
| **YouTube** | https://youtube.com/@atsigncompany |

---

## 📝 Project Files

| File | Purpose |
|------|---------|
| `README.md` | Project overview |
| `SETUP.md` | Detailed setup guide |
| `ATPLATFORM_GUIDE.md` | atPlatform integration |
| `ARCHITECTURE.md` | System diagrams |
| `IMPLEMENTATION_SUMMARY.md` | Complete summary |
| `QUICK_REFERENCE.md` | This file |
| `quickstart.ps1` | Automation script |

