import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/at_service.dart';
import '../services/config_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.radio, size: 100, color: Colors.blue),
              const SizedBox(height: 24),
              const Text(
                'KRYZ Transmitter Monitor',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              const Text(
                'Real-time monitoring powered by atPlatform',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 48),
              if (_isLoading)
                const Center(child: CircularProgressIndicator())
              else
                ElevatedButton(
                  onPressed: () => _startOnboarding(context),
                  style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: const Text('Get Started', style: TextStyle(fontSize: 18)),
                ),
              const SizedBox(height: 24),
              const Text(
                'You\'ll need an @sign to continue.\nGet a free @sign at atsign.com',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _startOnboarding(BuildContext context) async {
    setState(() => _isLoading = true);

    try {
      final atService = Provider.of<AtService>(context, listen: false);
      await atService.initialize(context);

      // Now that we're connected, give ConfigService the AtClient and reload from atProtocol
      if (atService.atClient != null) {
        final configService = Provider.of<ConfigService>(context, listen: false);
        configService.setAtClient(atService.atClient);
        await configService.loadConfig(); // Reload to get config from atProtocol
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Onboarding failed: $e'), backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}
