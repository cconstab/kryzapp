#!/bin/bash

# Script to build Android with flutter_keychain V2 embedding fix
# This allows using standard flutter_keychain (for macOS keychain persistence)
# while applying the V2 embedding patch for Android builds

set -e

echo "🔧 Preparing Android build..."

# 1. Ensure we're using standard flutter_keychain (should already be commented out)
echo "✓ Using standard flutter_keychain package"

# 2. Run flutter pub get
echo "📦 Getting dependencies..."
flutter pub get

# 3. Apply V2 embedding fix to flutter_keychain
KEYCHAIN_PATH="$HOME/.pub-cache/hosted/pub.dev/flutter_keychain-2.5.0/android/src/main/kotlin/be/appmire/flutterkeychain/FlutterKeychainPlugin.kt"

if [ -f "$KEYCHAIN_PATH" ]; then
    echo "🔨 Applying V2 embedding fix to flutter_keychain..."
    
    # Check if already patched by looking for the V2 embedding code
    if grep -q "fun onAttachedToEngine" "$KEYCHAIN_PATH"; then
        echo "✓ V2 embedding patch already applied"
    else
        echo "📝 Applying V2 embedding implementation..."
        
        # Replace the old V1 embedding code with V2 embedding code
        cat > /tmp/flutter_keychain_patch.kt << 'EOPATCH'
  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    preferences = flutterPluginBinding.applicationContext.getSharedPreferences(
            SHARED_PREFERENCES_NAME,
            Context.MODE_PRIVATE)

    encryptor = FlutterKeychainManager(flutterPluginBinding.applicationContext, preferences)
    encryptor.createKeys()

    channel = MethodChannel(flutterPluginBinding.binaryMessenger, channelName)
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    channel = null!!
  }
EOPATCH
        
        # Remove old V1 code (lines 283-304) and add V2 code
        sed -i '' '283,304d' "$KEYCHAIN_PATH"
        sed -i '' '282r /tmp/flutter_keychain_patch.kt' "$KEYCHAIN_PATH"
        
        echo "✓ V2 embedding patch applied successfully"
        rm /tmp/flutter_keychain_patch.kt
    fi
else
    echo "⚠️  flutter_keychain not found at expected path"
    echo "   Path: $KEYCHAIN_PATH"
    exit 1
fi

# 4. Set Java 17 and build for Android
echo "🏗️  Building for Android..."
export JAVA_HOME=$(/usr/libexec/java_home -v 17)

# Check if device ID is provided as argument
if [ -n "$1" ]; then
    echo "📱 Running on device: $1"
    flutter run -d "$1"
else
    # List available devices and build
    echo "📱 Available Android devices:"
    flutter devices | grep android
    echo ""
    echo "To run on a specific device, use: ./build_android.sh DEVICE_ID"
    flutter build apk --release
    echo "✓ APK built successfully at: build/app/outputs/flutter-apk/app-release.apk"
fi
