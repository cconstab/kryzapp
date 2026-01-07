# KRYZ Transmitter Monitor - Project Journey

## Initial Request
**"build tapplication at required agents"**

The user wanted to build a complete IoT monitoring system for a KRYZ FM radio transmitter using the atProtocol for secure, decentralized communication.

---

## Project Architecture

### Three-Component System

1. **SNMP Collector** (`snmp_collector/`)
   - Dart CLI application
   - Polls transmitter via SNMP protocol
   - Sends data to mobile apps via atProtocol notifications
   - Runs on server/local machine near transmitter

2. **Shared Models** (`shared/`)
   - Dart package
   - Common data models (TransmitterStats, GaugeConfig, etc.)
   - Shared between collector and mobile app

3. **Mobile App** (`mobile_app/`)
   - Flutter application
   - Displays real-time gauges
   - Configurable thresholds
   - Cloud-synced settings via atProtocol
   - Currently supports Windows (Android attempted but plugin compatibility issues)

---

## Development Timeline

### Phase 1: Initial Architecture & Real SNMP
- Built complete 3-project structure
- Implemented real SNMP data collection using `dart_snmp` package
- Real SNMP OIDs for KRYZ transmitter:
  - Modulation: `1.3.6.1.4.1.28142.1.300.1025.291.0`
  - SWR: `1.3.6.1.4.1.28142.1.300.256.303.0`
  - Power Out: `1.3.6.1.4.1.28142.1.300.256.256.0`
  - Power Ref: `1.3.6.1.4.1.28142.1.300.256.257.0`
  - Heat Temp: `1.3.6.1.4.1.28142.1.300.256.271.0`
  - Fan Speed: `1.3.6.1.4.1.28142.1.300.256.281.0`
- Made simulated mode opt-in with `-s` flag (real SNMP by default)

### Phase 2: Gauge System with Bidirectional Thresholds
**User Request:** "I think we need to have high and low thresholds"

Implemented 4-threshold system for each gauge:
- **Critical Low**: Red zone (bottom)
- **Warning Low**: Orange zone
- **Warning High**: Orange zone
- **Critical High**: Red zone (top)
- Green zone in the middle for normal operation

Default values set to realistic ranges:
- Modulation: 0-120%, thresholds 50/60/104/105
- SWR: 1.0-3.5:1, high-only 2.0/2.5
- Power Out: 0-20W, bidirectional 5/8/12/15
- Power Ref: 0-5W, high-only 1.0/2.0
- Heat Temp: 0-100°C, bidirectional 10/15/75/90
- Fan Speed: 0-10000 RPM, bidirectional 4000/6000/8000/8500

### Phase 3: Cloud Configuration Sync
**User Request:** "I do not want to save to a file that is messy"

- Removed all local file storage
- Implemented atProtocol-only configuration storage
- Settings saved to self-key: `kryz_dashboard_config` with TTR=-1 (never expire)
- Automatic cloud sync across all devices using same @sign

### Phase 4: Smooth Animations
**User Request:** "the gauges tend to jerk with new values they should update smoothly"

Converted GaugeWidget to StatefulWidget with:
- AnimationController (800ms duration)
- Curves.easeInOut for smooth transitions
- Tween animation between old and new values
- Proper disposal to prevent memory leaks

### Phase 5: Responsive Layout
**User Request:** "could we make the screen with gauges more responsive to the screen size"

Implemented adaptive GridView:
- LayoutBuilder to detect screen width
- 2 columns for narrow screens (≤900px)
- 3 columns for wide screens (>900px)
- AspectRatio adjustments: 0.95 (narrow), 1.3 (wide)
- Fixed white-on-white text contrast issues in settings

### Phase 6: Data Timeout & Alerts
**User Request:** "if no data arrives after 1 min dials should reset to zero and alert be raised awaiting data"

Implemented comprehensive timeout system:
- 1-minute Timer in TransmitterProvider
- `isDataStale` flag and getter
- Auto-reset gauges to null (not zero)
- Critical alert generation on timeout
- Red banner on dashboard: "DATA TIMEOUT - No data received"
- Three states: Normal (green), Timeout (red alert), Waiting (grey spinner)

### Phase 7: atProtocol Modernization
**User Request:** "I think...we should set it up so we only get data that is current and no history"

Migrated to modern atProtocol patterns:
- Removed deprecated `AtClientService`
- Added `fetchOfflineNotifications = false` in `AtClientPreference`
- Comprehensive FileSystemException error handling
- `_isDisposed` flag to prevent post-disposal processing
- `cancelOnError: false` to keep notification stream alive

### Phase 8: SNMP Reliability Improvements
**User Request:** "I am seeing the snmp collector sending all 0 in the data"

Fixed SNMP data collection:
- Changed `_queryOid()` to return `null` instead of `0.0` on failure
- Added null checks after each SNMP query
- Throw exception if any query fails (skip entire cycle)
- No notification sent when SNMP fails (instead of sending zeros)
- Synchronous polling to avoid overloading SNMP server
- Mobile app timeout mechanism detects missing data

### Phase 9: Station Name Configuration
**User Request:** "We should have a settings option to set the Station name"

Added station name feature:
- New field in `DashboardConfig` model
- Text input in settings screen (with proper TextEditingController)
- Saved to atProtocol cloud storage
- Displayed in status card (green box) instead of transmitter ID
- Live clock in AppBar header (updates every 500ms)
- Format: "KRYZ Transmitter Monitor" + "Jan 07, 2026 • 14:35:42"

---

## Current Feature Set

### SNMP Collector
✅ Real SNMP polling with dart_snmp 3.0.1  
✅ Simulated mode for testing (`-s` flag)  
✅ Synchronous polling (one OID at a time)  
✅ Null handling - no data sent if queries fail  
✅ atProtocol notifications to multiple receivers  
✅ Configurable poll interval (default 5 seconds)  
✅ Graceful error handling and logging  

### Mobile App
✅ Real-time gauge displays (6 metrics)  
✅ Smooth 800ms animations  
✅ Responsive 2-3 column layout  
✅ 4-threshold bidirectional system  
✅ Cloud-synced configuration via atProtocol  
✅ 1-minute data timeout with alerts  
✅ Station name customization  
✅ Live clock in header (500ms updates)  
✅ Theme-aware UI (light/dark mode)  
✅ Export/import configuration  
✅ Reset to defaults  

### atProtocol Integration
✅ Secure end-to-end encrypted notifications  
✅ Self-key storage for settings (cloud sync)  
✅ Modern SDK patterns (no deprecated code)  
✅ Current notifications only (no history)  
✅ Robust error handling  
✅ FileSystemException graceful handling  

---

## Technical Stack

### Dependencies
- **atProtocol**: at_client_mobile ^3.2.0, at_onboarding_flutter ^6.2.0
- **SNMP**: dart_snmp 3.0.1
- **Flutter**: Provider for state management
- **UI**: Material Design, responsive GridView
- **Shared Package**: kryz_shared (local path dependency)

### Architecture Patterns
- Provider pattern for state management
- Service layer (AtService, ConfigService, SNMPService)
- Model layer (TransmitterStats, GaugeConfig, DashboardConfig)
- Widget composition (GaugeWidget, StatusCard)
- Stream-based notification handling

---

## Challenges Overcome

### 1. Android Build Issues
**Problem**: Namespace compatibility with modern Android Gradle Plugin  
**Attempted**: Manual patching of plugin build.gradle files  
**Status**: Postponed - plugins need official updates from atProtocol team  
**Workaround**: Windows platform fully functional  

### 2. SNMP Zero Values
**Problem**: Failed SNMP queries returned 0.0, creating false data  
**Solution**: Return null on failure, skip entire cycle, let timeout handle missing data  

### 3. TextField Focus Loss
**Problem**: Station name input lost focus while typing  
**Solution**: Proper TextEditingController lifecycle (initState/dispose)  

### 4. Jerky Gauge Updates
**Problem**: Instant value changes looked unnatural  
**Solution**: StatefulWidget with AnimationController and Tween  

### 5. Notification History
**Problem**: Old notifications processed on app startup  
**Solution**: fetchOfflineNotifications = false in AtClientPreference  

---

## Key Design Decisions

1. **Real SNMP by Default**: `-s` flag for simulated mode (reversed from initial design)
2. **Cloud-Only Settings**: No local file storage, atProtocol sync only
3. **Null Over Zero**: Better to skip data than send false zeros
4. **Bidirectional Thresholds**: 4-zone system for comprehensive monitoring
5. **Responsive Grid**: Adaptive columns based on screen width
6. **Smooth Animations**: 800ms transitions for professional feel
7. **1-Minute Timeout**: Balance between responsiveness and false alarms
8. **Station Name in Status**: More visible than header, header shows app name + time

---

## Future Enhancements (Not Implemented)

- Android build (pending plugin updates)
- Historical data charts
- Alert history log
- Multiple transmitter support
- Push notifications when app in background
- Custom alert sounds
- Trend analysis

---

## Project Statistics

- **Total Files**: ~30+ Dart files across 3 projects
- **Lines of Code**: ~3000+ lines
- **Development Sessions**: Multiple iterative improvements
- **Major Iterations**: 9 significant feature additions/changes
- **Dependencies**: 15+ packages
- **Platforms Supported**: Windows (Android pending)

---

## Conclusion

The KRYZ Transmitter Monitor evolved from a basic concept to a production-ready IoT monitoring system through iterative development and user feedback. The project demonstrates:

- Real-world IoT integration (SNMP)
- Modern Flutter development practices
- Secure decentralized communication (atProtocol)
- Professional UX (smooth animations, responsive design)
- Robust error handling
- Cloud-based configuration management

The system is now ready for deployment on Windows platforms, with a smooth user experience, reliable data collection, and comprehensive monitoring capabilities.
