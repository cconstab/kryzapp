# atPlatform Integration Guide

## What is atPlatform?

The atPlatform is a revolutionary technology that puts people in complete control of their data. It provides:

- **End-to-end encryption** - All data is encrypted on the sender's device and decrypted only on the receiver's device
- **No middleman** - Direct peer-to-peer communication
- **Privacy by design** - No one (not even atPlatform) can access your data
- **Zero-trust architecture** - Built-in security from the ground up

## How KRYZ Uses atPlatform

### Architecture Overview

```
[KRYZ Transmitter]
        |
        | (SNMP)
        v
[SNMP Collector] (@snmp_collector)
        |
        | (Encrypted Notifications)
        v
[atServer Network]
        |
        v
[Mobile App] (@bob)
```

### Key Components

#### 1. @signs (atSign Identities)

Every entity has a unique @sign identifier:
- **@snmp_collector** - The collector service
- **@bob** - The user/mobile app
- **@kryz_transmitter** - (Optional) Could represent the transmitter itself

Think of @signs like email addresses, but for secure data exchange.

#### 2. Namespaces

All KRYZ data uses the `kryz` namespace:
- Keeps data organized
- Prevents conflicts with other apps
- Example: `transmitter_stats.kryz@snmp_collector`

#### 3. Notifications

Real-time push notifications for data delivery:

```dart
// Sending (Collector)
await atClient.notify(
  NotificationParams.forUpdate(
    AtKey()..key = 'transmitter_stats'
           ..namespace = 'kryz'
           ..sharedWith = '@bob',
    value: jsonEncode(stats),
  )
);

// Receiving (Mobile App)
atClient.notificationService
  .subscribe(regex: '.*kryz')
  .listen((notification) {
    // Process received data
  });
```

### Data Flow Example

1. **Collection**:
   ```
   Transmitter → SNMP → Collector (reads stats)
   ```

2. **Encryption**:
   ```
   Collector encrypts data with @bob's public key
   ```

3. **Transmission**:
   ```
   Collector → atServer (@snmp_collector) → atServer (@bob)
   ```

4. **Decryption**:
   ```
   Mobile App decrypts data with @bob's private key
   ```

5. **Display**:
   ```
   Mobile App displays gauges and alerts
   ```

## Security Features

### End-to-End Encryption

All transmitter data is encrypted:
- Encrypted at source (collector)
- Transmitted encrypted
- Decrypted only at destination (mobile app)
- No intermediate party can read the data

### Authentication

Each @sign requires authentication:
- Private key stored securely in .atKeys file
- PKAM (Public Key Authentication Mechanism)
- No passwords transmitted over network

### Authorization

Access control via authorized receivers:
```dart
static const List<String> authorizedReceivers = [
  '@kryz_mobile',
  '@bob',
];
```

Only these @signs can receive transmitter data.

## atPlatform APIs Used

### 1. at_client

Core client library for atPlatform operations:

```dart
// Initialize
final atClient = await AtClientManager.getInstance()
    .setCurrentAtSign(atSign, namespace, preference);

// Store data
await atClient.put(atKey, value);

// Retrieve data
final value = await atClient.get(atKey);

// Delete data
await atClient.delete(atKey);
```

### 2. Notification Service

Real-time push notifications:

```dart
// Subscribe to notifications
atClient.notificationService
    .subscribe(regex: '.*')
    .listen((notification) {
      // Handle notification
    });

// Send notification
await atClient.notificationService.notify(
  notificationParams,
  waitForFinalDeliveryStatus: false,
);
```

### 3. AtKey

Data identifier structure:

```dart
final atKey = AtKey()
  ..key = 'transmitter_stats'
  ..namespace = 'kryz'
  ..sharedWith = '@bob'
  ..metadata = (Metadata()
    ..isPublic = false
    ..isEncrypted = true
    ..ttl = 86400000); // 24 hours
```

## Connection Types in KRYZ

### 1. Async Communication (Transmitter → Collector)

```dart
// Fire and forget SNMP collection
final stats = await snmpService.collectStats();
// No response expected from transmitter
```

### 2. Notification (Collector → Mobile App)

```dart
// Real-time push notification
await notificationService.sendTransmitterStats(
  stats,
  authorizedReceivers,
);
```

## Best Practices

### 1. Namespace Usage

Always use namespaces for organization:
```dart
AtClientPreference()
  ..namespace = 'kryz'
```

### 2. Error Handling

Wrap atPlatform calls in try-catch:
```dart
try {
  await atClient.notify(params);
} catch (e) {
  logger.warning('Notification failed: $e');
}
```

### 3. Connection Management

Maintain single atClient instance:
```dart
// Good - Singleton
final atClient = AtClientManager.getInstance().atClient;

// Bad - Multiple instances
final atClient1 = AtClient(...);
final atClient2 = AtClient(...);
```

### 4. Notification Filtering

Use regex to filter relevant notifications:
```dart
// Only KRYZ notifications
atClient.notificationService
    .subscribe(regex: '.*kryz')
```

## Performance Considerations

### Notification Latency

- Typical delivery: < 1 second
- Depends on network conditions
- No polling required (push-based)

### Data Size Limits

- Recommended: < 10KB per notification
- Large data: Consider chunking or referencing

### Rate Limiting

- No hard limits on atPlatform
- Consider your use case (every 5 seconds is reasonable)

## Monitoring & Debugging

### Enable Verbose Logging

```dart
Logger.root.level = Level.ALL;
Logger.root.onRecord.listen((record) {
  print('${record.level.name}: ${record.message}');
});
```

### Check Notification Delivery

```dart
await atClient.notificationService.notify(
  params,
  waitForFinalDeliveryStatus: true, // Wait for confirmation
);
```

### Monitor Connection Status

```dart
// Check if connected
final isConnected = atClient.getConnectionStatus();
```

## Extending the System

### Adding More Data Types

1. Define model in `shared/lib/models/`:
```dart
class TransmitterConfig {
  final String transmitterId;
  final Map<String, dynamic> settings;
  // ...
}
```

2. Add notification key:
```dart
class NotificationKeys {
  static const String config = 'config';
}
```

3. Send/receive:
```dart
// Send
await notificationService.sendConfig(config);

// Receive
if (key.contains(NotificationKeys.config)) {
  final config = TransmitterConfig.fromJson(jsonData);
}
```

### Adding More Receivers

Simply add to authorized list:
```dart
static const List<String> authorizedReceivers = [
  '@kryz_mobile',
  '@bob',
  '@alice',
  '@charlie',
];
```

### Two-Way Communication

For command & control:

```dart
// Mobile app sends command
await atClient.notify(
  NotificationParams.forUpdate(
    AtKey()..key = 'command'..sharedWith = '@snmp_collector',
    value: jsonEncode({'action': 'restart'}),
  )
);

// Collector receives and acts
atClient.notificationService.subscribe().listen((notification) {
  if (notification.key.contains('command')) {
    final command = jsonDecode(notification.value);
    handleCommand(command);
  }
});
```

## Resources

### Documentation
- [atPlatform Docs](https://docs.atsign.com)
- [Dart atSDK](https://docs.atsign.com/sdk)
- [Flutter Examples](https://github.com/atsign-foundation/at_demos)

### Sample Code
- [at_client Examples](https://github.com/atsign-foundation/at_client_sdk)
- [Notification Examples](https://docs.atsign.com/sdk/events)

### Community
- [Discord](https://discord.atsign.com)
- [GitHub](https://github.com/atsign-foundation)
- [YouTube](https://www.youtube.com/@atsigncompany)

## Conclusion

The atPlatform provides KRYZ with:
- ✅ Secure, encrypted communication
- ✅ Real-time data delivery
- ✅ Simple identity management
- ✅ No server infrastructure required
- ✅ Privacy by design

This makes it perfect for IoT monitoring applications where security and privacy are paramount.
