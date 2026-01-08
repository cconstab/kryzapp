import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:logging/logging.dart';
import 'screens/onboarding_screen.dart';
import 'screens/dashboard_screen.dart';
import 'services/at_service.dart';
import 'services/config_service.dart';
import 'providers/transmitter_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Set up logging
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    debugPrint('${record.level.name}: ${record.time}: ${record.message}');
  });

  // Initialize config service (will load from local first, then sync with atProtocol when connected)
  final configService = ConfigService();
  await configService.loadConfig();

  runApp(KryzApp(configService: configService));
}

class KryzApp extends StatelessWidget {
  final ConfigService configService;

  const KryzApp({Key? key, required this.configService}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AtService()),
        ChangeNotifierProvider(create: (_) => TransmitterProvider()),
        ChangeNotifierProvider<ConfigService>.value(value: configService),
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
