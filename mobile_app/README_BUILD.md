# Build Instructions

## macOS Builds

For macOS builds with keychain persistence:

1. Comment out the forked flutter_keychain in `pubspec.yaml`:
   ```yaml
   # flutter_keychain:
   #   git:
   #     url: https://github.com/Al-Qaseh/flutter_keychain.git
   #     ref: hot-fix/v1-embedding-deprecation
   ```

2. Run:
   ```bash
   flutter pub get
   flutter run -d macos
   ```

## Android Builds

For Android builds with V2 embedding:

1. Uncomment the forked flutter_keychain in `pubspec.yaml`:
   ```yaml
   flutter_keychain:
     git:
       url: https://github.com/Al-Qaseh/flutter_keychain.git
       ref: hot-fix/v1-embedding-deprecation
   ```

2. Run:
   ```bash
   flutter pub get
   export JAVA_HOME=$(/usr/libexec/java_home -v 17)
   flutter run -d RFCY11AY9WD
   ```

Or use the build script:
```bash
./build_android.sh RFCY11AY9WD
```

## The Issue

The forked flutter_keychain fixes Android V2 embedding deprecation but breaks macOS keychain persistence. You need to toggle between the standard and forked versions depending on your target platform.