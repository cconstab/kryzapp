# KRYZ Transmitter Monitoring System

An atPlatform-based application for real-time and historical radio transmitter monitoring using SNMP.

## Architecture

This system consists of four packages:

1. **KRYZ Transmitter** (Hardware) — Radio transmitter exposing stats over SNMP
2. **SNMP Collector** (`snmp_collector/`) — Polls SNMP, persists readings to an `AtCollection`, sends critical alert notifications
3. **Mobile Application** (`mobile_app/`) — Flutter app; reads the same `AtCollection` for live gauges and historical charts, receives instant alert notifications
4. **Web Dashboard** (`web_dashboard/`) — Dart CLI server; authenticates with the atPlatform server-side, pushes live readings to any browser via WebSocket + Chart.js

## How data flows

```
Transmitter ──SNMP──► Collector ──AtCollection──► atServer (encrypted, 7-day TTL)
                           │                           │
                           │ alert notify()            │ sync
                           ▼                           ▼
                        Mobile App ◄──────────── Mobile App
                                                (collection.updates stream)
                       Web Dashboard server ──ws──► Browser (Chart.js)
```

**Stats** are written once by the collector into `AtCollection<TransmitterStats>('stats.kryz', Duration(days:7))` and end-to-end encrypted by the SDK. Any authorised receiver reads the same collection — no extra API calls.

**Alerts** still travel via `notificationService.notify()` so the mobile UI can pop a modal immediately, without waiting for a sync round-trip.

**Web dashboard** — `at_client` has no Flutter web support (platform keychain plugins have no web implementation), so the `web_dashboard` package is a Dart CLI shelf server that authenticates with the atPlatform, watches the `AtCollection`, and pushes JSON to browsers over WebSocket.

## Packages

### `shared/`
Common data model (`TransmitterStats`) and config constants (`NotificationKeys`, `KryzAtSigns`). All other packages depend on this.

### `snmp_collector/`
- Polls SNMP every 5 s
- Persists each reading via `AtCollectionService` → `AtCollection.create(obj: stats, sharedWith: receivers)`
- Sends alert notifications via `AtNotificationService` when `stats.alertLevel` is non-null

### `mobile_app/`
- Flutter application for iOS / Android / macOS
- `at_service.dart` opens the same `AtCollection` and streams updates via `collection.updates`
- `TransmitterProvider` exposes `historyStream(Duration)` (backed by `collection.query().where(...).orderBy(...).watch()`) for the metrics screen
- `MetricsScreen` — 4 time-window tabs (1h / 6h / 24h / 7d) × 6 metric charts (`SfCartesianChart`)

### `web_dashboard/`
- Dart CLI shelf server
- Auth via `at_onboarding_cli` on startup
- `GET /` — serves embedded Chart.js single-page dashboard
- `GET /ws` — WebSocket; client sends `{"action":"history","window":<s>}`, server replies with `{"type":"history","data":[…]}`; new readings broadcast as `{"type":"reading","data":{…}}`

## Key dependency versions

| Package | Version |
|---|---|
| `at_client` | `3.12.0-rc.1` |
| `at_client_flutter` | `^1.1.1` |
| `at_onboarding_cli` | `^1.15.0` |
| `syncfusion_flutter_charts` | `^32.1.23` |
| `shelf` / `shelf_router` / `shelf_web_socket` | `^1.4` / `^1.1` / `^2.0` |

## Setup

### Prerequisites
- Dart SDK 3.0+
- Flutter SDK 3.0+ (for mobile app)
- atSign accounts — get free @signs at https://atsign.com

### Quick install

```bash
cd shared       && dart pub get   && cd ..
cd snmp_collector && dart pub get && cd ..
cd mobile_app   && flutter pub get && cd ..
cd web_dashboard && dart pub get  && cd ..
```

## Running

### SNMP Collector
```bash
cd snmp_collector
dart run bin/snmp_collector.dart \
  --atsign @your_collector_sign \
  --keys ~/.atsign/keys/@your_collector_sign_key.atKeys \
  --host 192.168.1.100
```

### Mobile App
```bash
cd mobile_app
flutter run
```

### Web Dashboard
```bash
cd web_dashboard
dart run bin/server.dart \
  --atsign @your_sign \
  --keys ~/.atsign/keys/@your_sign_key.atKeys
# then open http://localhost:8080 in any browser
```

## atPlatform Integration

- **Storage** — `AtCollection<T>` provides typed, encrypted, synced records with built-in expiry
- **Authentication** — Each component authenticates independently with its own @sign
- **Zero-trust** — Data is end-to-end encrypted; the atServer never sees plaintext
- **Authorised receivers** — Defined in `shared/lib/config/atsign_config.dart`

## License

MIT License
