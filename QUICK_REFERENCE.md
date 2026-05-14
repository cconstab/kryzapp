# KRYZ Quick Reference Card

## 🚀 Quick Commands

### Setup
```powershell
# Install all dependencies
.\quickstart.ps1 setup

# Or manually:
cd shared && dart pub get && cd ..
cd snmp_collector && dart pub get && cd ..
cd mobile_app && flutter pub get && cd ..
```

### Run Collector
```powershell
# With script
.\quickstart.ps1 collector

# Or manually
cd snmp_collector
dart run bin\snmp_collector.dart `
  --atsign @snmp_collector `
  --keys .atsign\@snmp_collector_key.atKeys
```

### Run Mobile App
```powershell
# With script
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
| **YouTube** | https://youtube.com/@AtsignCo |

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

---

## 🎯 Success Checklist

Setup Phase:
- [ ] Dart SDK installed (3.0+)
- [ ] Flutter SDK installed (3.0+)
- [ ] Dependencies installed (`.\quickstart.ps1 setup`)
- [ ] @signs obtained from atsign.com
- [ ] .atKeys files downloaded

Collector Phase:
- [ ] .atKeys file in `snmp_collector/.atsign/`
- [ ] Collector runs without errors
- [ ] Logs show "Notifications sent successfully"

Mobile App Phase:
- [ ] App builds and runs
- [ ] Onboarding completed
- [ ] Gauges display data
- [ ] Receiving updates every 5 seconds

Testing Phase:
- [ ] Data updates in real-time
- [ ] Alert dialogs appear for critical conditions
- [ ] Status card shows correct colors

---

**Keep this reference handy for quick lookups! 📌**
