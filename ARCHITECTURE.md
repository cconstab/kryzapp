# KRYZ Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                    KRYZ Transmitter Monitoring System                │
│                        Powered by atPlatform                         │
└─────────────────────────────────────────────────────────────────────┘

                                                                        
┌─────────────────┐                                                    
│ KRYZ Transmitter│                                                    
│   (Hardware)    │                                                    
│                 │                                                    
│  • Power: 5kW   │                                                    
│  • Temp: 55°C   │                                                    
│  • VSWR: 1.2    │                                                    
│  • Freq: 88.5MHz│                                                    
└────────┬────────┘                                                    
         │                                                             
         │ SNMP (UDP:161)                                             
         │ Community: public                                          
         ▼                                                             
┌─────────────────┐                                                    
│ SNMP Collector  │                                                    
│  (Dart Process) │                                                    
│                 │                                                    
│ @snmp_collector │ ◄─── atSign Identity                              
│                 │                                                    
│ Functions:      │                                                    
│ • Poll SNMP     │                                                    
│ • Format JSON   │                                                    
│ • Encrypt data  │                                                    
│ • Send notifs   │                                                    
└────────┬────────┘                                                    
         │                                                             
         │ at_client.notify()                                         
         │ Encrypted notifications                                    
         ▼                                                             
┌─────────────────────────────────────────────────────────────────────┐
│                       atPlatform Network                             │
│                                                                      │
│  ┌──────────────┐         ┌──────────────┐                         │
│  │  atServer    │         │  atServer    │                         │
│  │ @snmp_       │ ◄─────► │    @bob      │                         │
│  │  collector   │         │              │                         │
│  └──────────────┘         └──────────────┘                         │
│                                                                      │
│  • End-to-end encryption                                            │
│  • Zero-trust architecture                                          │
│  • No data access by platform                                       │
└────────┬────────────────────────────────────────────────────────────┘
         │                                                             
         │ Push notification                                          
         │ Subscriber: regex '.*kryz'                                 
         ▼                                                             
┌─────────────────┐                                                    
│  Mobile App     │                                                    
│  (Flutter)      │                                                    
│                 │                                                    
│      @bob       │ ◄─── atSign Identity                              
│                 │                                                    
│ UI Components:  │                                                    
│ • Status Card   │                                                    
│ • Power Gauge   │                                                    
│ • Temp Gauge    │                                                    
│ • VSWR Gauge    │                                                    
│ • Freq Display  │                                                    
│ • Alert Dialogs │                                                    
└─────────────────┘                                                    
         │                                                             
         │                                                             
         ▼                                                             
┌─────────────────┐                                                    
│      Bob        │                                                    
│    (Person)     │                                                    
│                 │                                                    
│  Views real-time│                                                    
│  transmitter    │                                                    
│  status on      │                                                    
│  phone/tablet   │                                                    
└─────────────────┘                                                    


═══════════════════════════════════════════════════════════════════════
                            Data Flow
═══════════════════════════════════════════════════════════════════════

┌─────────┐  SNMP   ┌──────────┐  Encrypt   ┌──────────┐  Push    ┌────────┐
│Transmit.│ ──────► │Collector │ ─────────► │atPlatform│ ───────► │ Mobile │
└─────────┘         └──────────┘            └──────────┘          └────────┘
   (Thing)           (Process)                (Network)            (Thing)
                                                                       │
                     Every 5s                                          │
                                                                       ▼
                                                                   ┌────────┐
                                                                   │  Bob   │
                                                                   │(Person)│
                                                                   └────────┘


═══════════════════════════════════════════════════════════════════════
                        Connection Types
═══════════════════════════════════════════════════════════════════════

1. Async (Fire & Forget)
   Transmitter ──async──► Collector
   • SNMP query/response
   • No persistent connection

2. Notification (Real-time Push)
   Collector ──notify──► Mobile App
   • at_client.notificationService.notify()
   • Encrypted end-to-end
   • Delivered via atServer network


═══════════════════════════════════════════════════════════════════════
                        Security Model
═══════════════════════════════════════════════════════════════════════

         Collector                    atServer                  Mobile App
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
