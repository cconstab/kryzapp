import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import 'screens/onboarding_screen.dart';
import 'screens/dashboard_screen.dart';
import 'services/at_service.dart';
import 'providers/transmitter_provider.dart';

void main() {
  // Set up logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  runApp(const KryzApp());
}

class KryzApp extends StatelessWidget {
  const KryzApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AtService()),
        ChangeNotifierProvider(create: (_) => TransmitterProvider()),
      ],
      child: MaterialApp(
        title: 'KRYZ Transmitter Monitor',
        theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true, brightness: Brightness.light),
        darkTheme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true, brightness: Brightness.dark),
        home: const AppEntryPoint(),
      ),
    );
  }
}

class AppEntryPoint extends StatelessWidget {
  const AppEntryPoint({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Consumer<AtService>(
      builder: (context, atService, child) {
        if (!atService.isInitialized) {
          return const OnboardingScreen();
        }
        return const DashboardScreen();
      },
    );
  }
}
