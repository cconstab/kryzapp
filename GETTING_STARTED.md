# 🚀 Getting Started with KRYZ

## Your Step-by-Step Checklist

Follow these steps in order to get your KRYZ transmitter monitoring system up and running.

---

## Phase 1: Prerequisites ✅

### Step 1.1: Install Dart SDK
- [ ] Download from https://dart.dev/get-dart
- [ ] Install for Windows
- [ ] Verify installation:
  ```powershell
  dart --version
  # Should show version 3.0 or higher
  ```

### Step 1.2: Install Flutter SDK
- [ ] Download from https://flutter.dev/docs/get-started/install
- [ ] Add to PATH
- [ ] Verify installation:
  ```powershell
  flutter doctor
  # Check for any issues
  ```

### Step 1.3: Install Git (if not already installed)
- [ ] Download from https://git-scm.com
- [ ] Install with default options

### Step 1.4: Get @signs
- [ ] Visit https://atsign.com
- [ ] Sign up for an account (free)
- [ ] Claim at least 2 @signs:
  - [ ] One for collector (e.g., `@snmp_collector`)
  - [ ] One for yourself (e.g., `@bob`)
- [ ] Download .atKeys files for each @sign
- [ ] Save files to a safe location

**Estimated Time**: 30 minutes  
**Status**: ⬜ Not Started / ⏳ In Progress / ✅ Complete

---

## Phase 2: Project Setup ✅

### Step 2.1: Navigate to Project
```powershell
cd c:\Users\colin\kryzapp
```
- [ ] Confirm you're in the correct directory
- [ ] Run: `Get-ChildItem` to see project files

### Step 2.2: Install Dependencies (Automated)
```powershell
.\quickstart.ps1 setup
```
- [ ] Watch for successful completion
- [ ] Check for any error messages
- [ ] All three components should show "✓"

**OR Manual Installation:**
```powershell
# Shared package
cd shared
dart pub get
cd ..

# SNMP Collector
cd snmp_collector
dart pub get
cd ..

# Mobile App
cd mobile_app
flutter pub get
cd ..
```

### Step 2.3: Verify Dependencies
- [ ] No error messages during installation
- [ ] All pubspec.yaml files resolved
- [ ] Ready to proceed

**Estimated Time**: 5-10 minutes  
**Status**: ⬜ Not Started / ⏳ In Progress / ✅ Complete

---

## Phase 3: Configure SNMP Collector ✅

### Step 3.1: Set Up Keys Directory
```powershell
cd snmp_collector
New-Item -ItemType Directory -Force -Path .atsign
```
- [ ] Directory created

### Step 3.2: Copy .atKeys File
```powershell
# Copy your downloaded collector .atKeys file
Copy-Item "C:\Path\To\Your\@snmp_collector_key.atKeys" .atsign\
```
- [ ] File copied successfully
- [ ] File is in `snmp_collector\.atsign\` folder
- [ ] Filename format: `@something_key.atKeys`

### Step 3.3: Configure Authorized Receivers (Optional)
Edit: `c:\Users\colin\kryzapp\shared\lib\config\atsign_config.dart`

```dart
static const List<String> authorizedReceivers = [
  '@kryz_mobile',
  '@bob',  // ← Change this to your @sign
];
```
- [ ] Updated with your @sign
- [ ] Saved file

### Step 3.4: Test Collector
```powershell
# From snmp_collector directory
dart run bin\snmp_collector.dart `
  --atsign @snmp_collector `
  --keys .atsign\@snmp_collector_key.atKeys
```

**Expected Output:**
```
INFO: Initializing SNMP Collector for @snmp_collector
INFO: atClient initialized successfully
INFO: Authentication successful
INFO: Starting SNMP collection (polling every 5s)
INFO: Collected: TransmitterStats(id: KRYZ-TX-001, ...)
```

- [ ] Collector starts without errors
- [ ] See "Authentication successful"
- [ ] See repeating "Collected: TransmitterStats..." every 5 seconds
- [ ] Press Ctrl+C to stop for now

**Estimated Time**: 10 minutes  
**Status**: ⬜ Not Started / ⏳ In Progress / ✅ Complete

---

## Phase 4: Set Up Mobile Application ✅

### Step 4.1: Check Device
```powershell
cd ..\mobile_app
flutter devices
```
- [ ] At least one device listed (emulator or physical)
- [ ] If none, set up an emulator in Android Studio or Xcode

### Step 4.2: Run Mobile App
```powershell
flutter run
```
- [ ] App builds successfully
- [ ] App launches on device/emulator

### Step 4.3: Complete Onboarding
When app launches:
1. [ ] See "KRYZ Transmitter Monitor" welcome screen
2. [ ] Tap "Get Started"
3. [ ] Select or add your @sign (e.g., `@bob`)
4. [ ] Authenticate with your credentials
5. [ ] See dashboard screen with "Waiting for transmitter data..."

**Estimated Time**: 10 minutes  
**Status**: ⬜ Not Started / ⏳ In Progress / ✅ Complete

---

## Phase 5: End-to-End Testing ✅

### Step 5.1: Start Collector
In a PowerShell window:
```powershell
cd c:\Users\colin\kryzapp\snmp_collector
dart run bin\snmp_collector.dart `
  --atsign @snmp_collector `
  --keys .atsign\@snmp_collector_key.atKeys
```
- [ ] Collector running
- [ ] Logs show "Notifications sent successfully"

### Step 5.2: Observe Mobile App
The mobile app should:
- [ ] Transition from "Waiting..." to showing gauges
- [ ] Display transmitter stats (Power, Temp, VSWR, Frequency)
- [ ] Show status card with "KRYZ-TX-001"
- [ ] Update every 5 seconds
- [ ] Gauges animate with new values

### Step 5.3: Test Alerts (Optional)
To trigger an alert:
1. Stop collector (Ctrl+C)
2. Edit `snmp_collector\lib\services\snmp_service.dart`
3. In `_getSimulatedStats()` method, change:
   ```dart
   temperature: 92.0,  // Above critical threshold
   ```
4. Save and restart collector
5. [ ] Mobile app shows alert dialog
6. [ ] Status card turns red

### Step 5.4: Verify Complete Flow
- [ ] ✅ Data flows from collector to mobile app
- [ ] ✅ Updates are real-time (every 5 seconds)
- [ ] ✅ Alerts trigger correctly
- [ ] ✅ UI is responsive and attractive

**Estimated Time**: 15 minutes  
**Status**: ⬜ Not Started / ⏳ In Progress / ✅ Complete

---

## Phase 6: Production Setup (Optional) 🎯

### Step 6.1: Configure Real SNMP Device
If you have a real transmitter:

1. Edit `snmp_collector\lib\services\snmp_service.dart`
2. Update OIDs to match your transmitter's MIB
3. Run collector with real SNMP settings:
   ```powershell
   dart run bin\snmp_collector.dart `
     --atsign @snmp_collector `
     --keys .atsign\@snmp_collector_key.atKeys `
     --host 192.168.1.100 `
     --port 161 `
     --community public
   ```
- [ ] Connected to real transmitter
- [ ] Receiving actual data

### Step 6.2: Deploy Collector as Service
See `SETUP.md` for instructions on:
- [ ] Windows Service setup
- [ ] Linux systemd service
- [ ] Auto-start on boot

### Step 6.3: Build Production Mobile App
```powershell
cd mobile_app

# For Android
flutter build apk --release

# For iOS
flutter build ios --release
```
- [ ] Production build created
- [ ] App installed on devices

**Estimated Time**: 30-60 minutes  
**Status**: ⬜ Not Started / ⏳ In Progress / ✅ Complete

---

## ✅ Success Criteria

You've successfully completed setup when:

- ✅ Collector runs without errors
- ✅ Mobile app displays real-time data
- ✅ Data updates every 5 seconds
- ✅ Gauges show current values
- ✅ Alerts work correctly
- ✅ No authentication errors

---

## 🆘 Troubleshooting Quick Fixes

### "Authentication failed"
```powershell
# Check .atKeys file exists and path is correct
Test-Path snmp_collector\.atsign\*.atKeys

# Check @sign spelling matches exactly
```

### "Not receiving notifications"
```dart
// Verify your @sign is in authorized list
// Edit: shared/lib/config/atsign_config.dart
static const List<String> authorizedReceivers = [
  '@your_actual_atsign',  // Must match exactly
];
```

### "Flutter doctor shows issues"
```powershell
flutter doctor -v  # Detailed diagnostics
# Follow recommendations to fix issues
```

### "Collector shows SNMP timeout"
This is normal! The system automatically uses simulated data.
- [ ] See "SNMP query failed, returning simulated data"
- [ ] Simulated data is perfect for testing

---

## 📚 What to Read Next

Based on your needs:

**Just Getting Started**:
- ✅ You're reading it! (This file)
- → `QUICK_REFERENCE.md` - Command cheat sheet

**Want to Understand the System**:
- → `ARCHITECTURE.md` - Visual diagrams
- → `IMPLEMENTATION_MAP.md` - Complete feature map

**Ready to Customize**:
- → `ATPLATFORM_GUIDE.md` - Deep dive into atPlatform
- → Component READMEs in `snmp_collector/` and `mobile_app/`

**Need Help**:
- → `SETUP.md` - Detailed setup guide
- → https://docs.atsign.com - atPlatform docs
- → https://discord.atsign.com - Community support

---

## 🎉 Congratulations!

When all checkboxes above are checked, you have:
- ✅ A fully functional IoT monitoring system
- ✅ Real-time encrypted communication
- ✅ Beautiful mobile interface
- ✅ Production-ready code
- ✅ Complete documentation

**Your KRYZ transmitter monitoring system is live!** 🚀

---

## 📝 Notes Section

Use this space for your own notes:

```
My @signs:
- Collector: @_______________
- Mobile: @_______________

My SNMP Device IP: _______________

Custom OIDs:
- Power: _______________
- Temperature: _______________
- VSWR: _______________
- Frequency: _______________

Next steps:
-
-
-
```

---

**Questions?** See documentation or visit https://docs.atsign.com
