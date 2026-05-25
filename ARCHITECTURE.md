# KRYZ Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    KRYZ Transmitter Monitoring System                │
│                     Powered by atPlatform 3.12.0-rc.1               │
└─────────────────────────────────────────────────────────────────────┘


┌─────────────────┐
│ KRYZ Transmitter│
│   (Hardware)    │
│                 │
│  • Power: 5 kW  │
│  • Temp: 55 °C  │
│  • SWR: 1.2     │
│  • Modulation%  │
└────────┬────────┘
         │
         │ SNMP (UDP:161)
         ▼
┌─────────────────┐
│ SNMP Collector  │
│  (Dart Process) │
│                 │
│ @snmp_collector │ ◄─── atSign Identity
│                 │
│ • Poll SNMP     │
│ • AtCollection  │ ──writes──► AtCollection<TransmitterStats>
│   .create()     │             ('stats.kryz', TTL 7 days)
│ • alert notify()│ ──(urgent alerts only)──►
└────────┬────────┘
         │
         │ AtCollection syncs via atServer (E2EE)
         ▼
┌─────────────────────────────────────────────────────────────────────┐
│                       atPlatform Network                             │
│                                                                      │
│  ┌──────────────┐         ┌──────────────┐                         │
│  │  atServer    │ ◄─────► │  atServer    │                         │
│  │ @snmp_       │         │    @bob      │                         │
│  │  collector   │         │              │                         │
│  └──────────────┘         └──────────────┘                         │
│                                                                      │
│  • End-to-end encrypted (atServer never sees plaintext)             │
│  • AtCollection items expire automatically after 7 days             │
│  • Alert notifications TTL = 5 min                                  │
└──────────┬──────────────────────────┬───────────────────────────────┘
           │                          │
           │ collection.updates       │ collection.updates
           │ stream (CItemUpdated)    │ stream (CItemUpdated)
           ▼                          ▼
┌─────────────────┐        ┌──────────────────────┐
│  Mobile App     │        │  Web Dashboard Server │
│  (Flutter)      │        │  (Dart CLI / shelf)   │
│                 │        │                       │
│      @bob       │        │  @any_authorised_sign │
│                 │        │                       │
│ • Live gauges   │        │ • GET /  → HTML page  │
│ • Alert modals  │        │ • GET /ws → WebSocket │
│ • MetricsScreen │        │   broadcasts readings │
│   ├─ 1h tab     │        │   to all browsers     │
│   ├─ 6h tab     │        └──────────┬────────────┘
│   ├─ 24h tab    │                   │
│   └─ 7d tab     │                   │ WebSocket (JSON)
│ SfCartesianChart│                   ▼
└─────────────────┘        ┌──────────────────────┐
         │                 │  Any Web Browser      │
         ▼                 │  Chart.js dashboard   │
    ┌─────────┐            │  • 6 live metric      │
    │  User   │            │    charts             │
    │  (Bob)  │            │  • 1h/6h/24h/7d       │
    └─────────┘            │    time-window tabs   │
                           └──────────────────────┘


═══════════════════════════════════════════════════════════════════════
                            Data Flow
═══════════════════════════════════════════════════════════════════════

┌──────────┐ SNMP  ┌──────────┐ AtCollection ┌──────────┐ sync  ┌────────┐
│Transmit. │──────►│Collector │─────────────►│atServer  │──────►│Mobile  │
└──────────┘       └──────────┘ (E2EE write)  └──────────┘       │App     │
                        │                          │              └────────┘
                        │ alert                    │ sync
                        │ notify()            ┌────▼───────────┐
                        └────────────────────►│Web Dashboard   │
                          (urgent only,        │Server          │──ws──► Browser
                           TTL 5 min)          └────────────────┘

Poll interval: 5 s
Collection TTL: 7 days (auto-expires on atServer)
Alert TTL: 5 min


═══════════════════════════════════════════════════════════════════════
                     AtCollection API (at_client 3.12.0-rc.1)
═══════════════════════════════════════════════════════════════════════

Write (collector):
  _collection = await atClient.collection<TransmitterStats>(
    'stats.kryz', Duration(days:7),
    fromJson: TransmitterStats.fromJson, typeTag: 'TransmitterStats');
  await _collection.create(obj: stats, sharedWith: receivers);

Read – live stream (mobile app / web dashboard):
  collection.updates.listen((CItemUpdated event) async {
    final citem = await collection.getOrNull(event.id, event.owner);
    // citem.obj is a TransmitterStats
  });

Read – historical query (mobile app MetricsScreen):
  collection.query()
    .where((item) => item.obj.timestamp.isAfter(cutoff))
    .orderBy((item) => item.obj.timestamp)
    .watch();   // returns Stream<List<CItem<TransmitterStats>>>

Key facts:
  • CItemUpdated has NO type parameter and NO embedded item
  • Always fetch via collection.getOrNull(event.id, event.owner)
  • collection.updates is Stream<CItemUpdated> (not Stream<CEvent>)


═══════════════════════════════════════════════════════════════════════
                        Package / File Structure
═══════════════════════════════════════════════════════════════════════

kryzapp/
├── shared/                          # Shared models & config
│   ├── lib/
│   │   ├── models/
│   │   │   └── transmitter_stats.dart   # fromJson / toJson
│   │   ├── config/
│   │   │   └── atsign_config.dart       # NotificationKeys, KryzAtSigns
│   │   └── kryz_shared.dart
│   └── pubspec.yaml
│
├── snmp_collector/                  # Collector service
│   ├── bin/
│   │   └── snmp_collector.dart     # Entry point (CLI args)
│   ├── lib/
│   │   ├── collector/
│   │   │   └── snmp_collector.dart # Poll loop; wires services
│   │   └── services/
│   │       ├── snmp_service.dart        # SNMP interface
│   │       ├── at_collection_service.dart  # AtCollection writer (NEW)
│   │       └── at_notification_service.dart # Alert-only notify()
│   └── pubspec.yaml
│
├── mobile_app/                      # Flutter app (iOS/Android/macOS)
│   ├── lib/
│   │   ├── main.dart               # Entry point
│   │   ├── screens/
│   │   │   ├── onboarding_screen.dart
│   │   │   ├── dashboard_screen.dart   # Live gauges + chart nav
│   │   │   └── metrics_screen.dart    # Historical charts (NEW)
│   │   ├── widgets/
│   │   │   ├── gauge_widget.dart
│   │   │   └── status_card.dart
│   │   ├── services/
│   │   │   ├── at_service.dart     # Collection watch + alert sub
│   │   │   └── config_service.dart
│   │   └── providers/
│   │       └── transmitter_provider.dart  # historyStream(), historySnapshot()
│   └── pubspec.yaml
│
├── web_dashboard/                   # Dart CLI web server (NEW)
│   ├── bin/
│   │   └── server.dart             # shelf server + embedded HTML
│   └── pubspec.yaml
│
├── README.md
├── SETUP.md
├── ARCHITECTURE.md                  # This file
├── ATPLATFORM_GUIDE.md
├── QUICK_REFERENCE.md
└── PROJECT_JOURNEY.md               # Development history (preserved)


═══════════════════════════════════════════════════════════════════════
                        Alert Thresholds
═══════════════════════════════════════════════════════════════════════

┌──────────────────┬──────────────┬──────────────┬──────────────┐
│ Metric           │ Normal       │ Warning      │ Critical     │
├──────────────────┼──────────────┼──────────────┼──────────────┤
│ Power Out        │ < 4500 W     │ 4500–5500 W  │ > 5500 W     │
│ Power Reflected  │ < 100 W      │ 100–300 W    │ > 300 W      │
│ SWR              │ < 1.8:1      │ 1.8–3.0:1    │ > 3.0:1      │
│ Modulation       │ 80–105 %     │ 105–115 %    │ > 115 %      │
│ Heat Sink Temp   │ < 75 °C      │ 75–90 °C     │ > 90 °C      │
│ Fan Speed        │ > 500 RPM    │ 200–500 RPM  │ < 200 RPM    │
└──────────────────┴──────────────┴──────────────┴──────────────┘


═══════════════════════════════════════════════════════════════════════
                        Security Model
═══════════════════════════════════════════════════════════════════════

         Collector                    atServer                  Mobile App
             │                           │                           │
             │── encrypted AtCollection──►│                           │
             │   item (SDK-managed)       │── sync AtCollection ──────►│
             │                           │                           │
             │── alert notify() ─────────►│── push notification ──────►│
             │   (TTL 5 min, E2EE)        │                           │

Zero-trust principles:
  • atServer stores only ciphertext — it cannot read stats or alerts
  • Each @sign owns its own private keys (stored locally in .atKeys)
  • Receivers are allowlisted in shared/lib/config/atsign_config.dart
  • Web dashboard server authenticates with a full atSign — browsers
    receive only the already-decrypted JSON forwarded over WebSocket;
    no atSign credentials ever reach the browser
```

            │                             │                         │
            │  1. Collect data            │                         │
            ├─────────────►               │                         │
            │                             │                         │
            │  2. Encrypt with            │                         │
            │     Bob's public key        │                         │
            ├──────────────────────►      │                         │
            │                             │                         │
            │                             │  3. Store encrypted     │
            │                             ├────────►                │
            │                             │                         │
            │                             │  4. Push notification   │
            │                             ├───────────────────────► │
            │                             │                         │
            │                             │  5. Fetch & decrypt     │
            │                             │     with Bob's private  │
            │                             │         key             │
            │                             │ ◄───────────────────────┤
            │                             │                         │
            
   • atPlatform cannot decrypt data
   • Only Bob's private key can decrypt
   • Zero-knowledge architecture


═══════════════════════════════════════════════════════════════════════
                        Tech Stack
═══════════════════════════════════════════════════════════════════════

┌─────────────────────┬─────────────────────┬─────────────────────────┐
│  SNMP Collector     │  atPlatform         │  Mobile App             │
├─────────────────────┼─────────────────────┼─────────────────────────┤
│ • Dart 3.0+         │ • at_client SDK     │ • Flutter 3.0+          │
│ • at_client         │ • Root servers      │ • at_client_mobile      │
│ • dart_snmp         │ • atServers         │ • at_onboarding_flutter │
│ • logging           │ • Secondary servers │ • Syncfusion Gauges     │
│                     │                     │ • Provider (state mgmt) │
└─────────────────────┴─────────────────────┴─────────────────────────┘


═══════════════════════════════════════════════════════════════════════
                        File Structure
═══════════════════════════════════════════════════════════════════════

kryzapp/
├── shared/                          # Shared models & config
│   ├── lib/
│   │   ├── models/
│   │   │   └── transmitter_stats.dart
│   │   ├── config/
│   │   │   └── atsign_config.dart
│   │   └── kryz_shared.dart
│   └── pubspec.yaml
│
├── snmp_collector/                  # Collector service
│   ├── bin/
│   │   └── snmp_collector.dart     # Entry point
│   ├── lib/
│   │   ├── collector/
│   │   │   └── snmp_collector.dart # Main collector logic
│   │   └── services/
│   │       ├── snmp_service.dart   # SNMP interface
│   │       └── at_notification_service.dart
│   └── pubspec.yaml
│
├── mobile_app/                      # Flutter app
│   ├── lib/
│   │   ├── main.dart               # Entry point
│   │   ├── screens/
│   │   │   ├── onboarding_screen.dart
│   │   │   └── dashboard_screen.dart
│   │   ├── widgets/
│   │   │   ├── gauge_widget.dart
│   │   │   └── status_card.dart
│   │   ├── services/
│   │   │   └── at_service.dart     # atPlatform integration
│   │   └── providers/
│   │       └── transmitter_provider.dart
│   └── pubspec.yaml
│
├── README.md                        # Project overview
├── SETUP.md                         # Setup instructions
├── ATPLATFORM_GUIDE.md             # atPlatform details
└── ARCHITECTURE.md                  # This file


═══════════════════════════════════════════════════════════════════════
                        Alert Thresholds
═══════════════════════════════════════════════════════════════════════

┌──────────────┬──────────┬──────────┬──────────┐
│ Metric       │ Normal   │ Warning  │ Critical │
├──────────────┼──────────┼──────────┼──────────┤
│ Power Output │ < 4500 W │ 4500-5500│ > 5500 W │
│ Temperature  │ < 75°C   │ 75-90°C  │ > 90°C   │
│ VSWR         │ < 1.8:1  │ 1.8-3.0  │ > 3.0:1  │
│ Status       │ ON_AIR   │ STANDBY  │ FAULT    │
└──────────────┴──────────┴──────────┴──────────┘

```
