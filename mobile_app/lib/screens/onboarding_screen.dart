import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:at_client_flutter/at_client_flutter.dart';
import 'package:at_auth/at_auth.dart';
import 'package:path_provider/path_provider.dart';
import '../services/at_service.dart';
import '../services/config_service.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({Key? key}) : super(key: key);

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool _isLoading = false;
  final KeychainStorage _keychainStorage = KeychainStorage();

  Future<AtClientPreference> _getAtClientPreference() async {
    final dir = await getApplicationSupportDirectory();
    return AtClientPreference()
      ..rootDomain = 'root.atsign.org'
      ..namespace = 'kryz'
      ..hiveStoragePath = dir.path
      ..commitLogPath = dir.path
      ..isLocalStoreRequired = true
      ..fetchOfflineNotifications = false
      ..syncIntervalMins = -1
      ..maxDataSize = 512000;
  }

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
              const SizedBox(height: 24),
              Consumer<AtService>(
                builder: (context, atService, child) {
                  final currentAtSign = atService.currentAtSign;
                  if (currentAtSign != null) {
                    return Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.withOpacity(0.3)),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.person,
                              color: Colors.blue, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Currently logged in as $currentAtSign',
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
              const SizedBox(height: 24),
              if (_isLoading)
                const Center(child: CircularProgressIndicator())
              else ...[
                // Primary action: Login with existing atSign
                Consumer<AtService>(
                  builder: (context, atService, child) {
                    final currentAtSign = atService.currentAtSign;
                    if (currentAtSign != null) {
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.blue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border:
                              Border.all(color: Colors.blue.withOpacity(0.3)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.person,
                                color: Colors.blue, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              'Currently logged in as $currentAtSign',
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w500),
                            ),
                          ],
                        ),
                      );
                    }
                    return const SizedBox.shrink();
                  },
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => _selectExistingAtSign(context),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.blue,
                  ),
                  child: const Text('Login with Existing atSign',
                      style: TextStyle(fontSize: 18, color: Colors.white)),
                ),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                const Text(
                  'Don\'t have an atSign stored?',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _addNewAtSign(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Add atSign from File',
                      style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => _activateNewAtSign(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('Activate New atSign',
                      style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => _managePairedAtsigns(context),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('Manage Paired atSigns',
                      style: TextStyle(fontSize: 16)),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Don\'t have an atSign yet?',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey[700],
                    fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 8),
              Text(
                'Get a free atSign at atsign.com',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 14,
                    color: Colors.blue[700],
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Add a new atSign by picking an .atKeys file
  /// We can determine the atSign from the file itself, so no need to ask user
  /// 1. Show AtKeysFileDialog to pick the atKeys file
  /// 2. Read atSign from file metadata
  /// 3. Show PkamDialog to complete authentication (handles both PKAM and APKAM)
  Future<void> _addNewAtSign(BuildContext context) async {
    setState(() => _isLoading = true);

    try {
      // Step 1: Show AtKeysFileDialog to pick the atKeys file from device storage
      var atKeysIo = await AtKeysFileDialog.show(context);

      if (!mounted) return;

      if (atKeysIo == null) {
        // User cancelled
        return;
      }

      // Step 2: Extract atSign from the file
      // The atSign is typically in the filename (e.g., @alice_key.atKeys)
      // We'll try to get it from the file path first
      String? atSign;

      // FileAtKeysIo has a filePath function - try to extract atSign from filename
      try {
        // Try to extract atSign from filename pattern: @<atsign>_key.atKeys
        final pathGetter =
            (atKeysIo as dynamic).filePath as String Function(String);
        final testPath =
            pathGetter('test'); // Get path with a test value to see the pattern

        // Extract filename from path
        final filename = testPath.split('/').last;

        // Try to extract atSign from filename (e.g., @alice_key.atKeys -> @alice)
        // Match @ followed by word chars, but stop before _key or .atKeys
        final match =
            RegExp(r'(@[a-zA-Z0-9_-]+?)(?:_key|\.atKeys)').firstMatch(filename);
        if (match != null) {
          atSign = match.group(1);
        }
      } catch (e) {
        // Ignore errors, we'll prompt the user instead
      }

      // If we couldn't extract atSign from filename, prompt the user
      if (atSign == null || atSign.isEmpty) {
        if (!mounted) return;

        // Show dialog to ask for atSign
        atSign = await showDialog<String>(
          context: context,
          builder: (context) {
            final controller = TextEditingController();
            return AlertDialog(
              backgroundColor: Colors.white,
              title: const Text(
                'Enter atSign',
                style: TextStyle(
                    color: Colors.black87, fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Please enter the atSign for this keys file:',
                    style: TextStyle(fontSize: 14, color: Colors.black87),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: controller,
                    style: const TextStyle(color: Colors.black87),
                    decoration: const InputDecoration(
                      hintText: '@alice',
                      labelText: 'atSign',
                      border: OutlineInputBorder(),
                    ),
                    autofocus: true,
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    var value = controller.text.trim();
                    if (!value.startsWith('@')) {
                      value = '@$value';
                    }
                    Navigator.of(context).pop(value);
                  },
                  child: const Text('Continue'),
                ),
              ],
            );
          },
        );

        if (!mounted) return;

        if (atSign == null || atSign.isEmpty) {
          // User cancelled
          return;
        }
      }

      // Ensure atSign starts with @
      if (!atSign.startsWith('@')) {
        atSign = '@$atSign';
      }

      if (!mounted) return;

      // Step 3: Create auth request with the file and show PkamDialog
      final request = AtAuthRequest(
        atSign,
        atKeysIo: atKeysIo,
        rootDomain: AtRootDomain.atsignDomain,
      );

      // Authenticate using PKAM dialog (handles both PKAM and APKAM automatically)
      // backupKeys saves the keys to keychain after successful authentication
      final response = await PkamDialog.show(
        context,
        request: request,
        backupKeys: [KeychainAtKeysIo()],
      );

      if (!mounted) return;

      if (response != null && response.isSuccessful) {
        // Initialize AtService with AtClientPreference
        final atService = Provider.of<AtService>(context, listen: false);
        final preference = await _getAtClientPreference();
        await atService.initializeWithAuthResponse(response, preference);

        // Set up config service
        if (atService.atClient != null) {
          final configService =
              Provider.of<ConfigService>(context, listen: false);
          configService.setAtClient(atService.atClient);
          await configService.loadConfig();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to add atSign: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Select an existing atSign from keychain storage
  Future<void> _selectExistingAtSign(BuildContext context) async {
    setState(() => _isLoading = true);

    try {
      // Get existing atSigns from keychain
      final existingAtSigns = await _keychainStorage.getAllAtsigns();

      if (!mounted) return;

      if (existingAtSigns.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('No paired atSigns found. Please add a new atSign first.'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      // Show simple list dialog to select atSign
      final selectedAtSign = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select atSign'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: existingAtSigns.length,
              itemBuilder: (context, index) {
                final atSign = existingAtSigns[index];
                return ListTile(
                  leading: const Icon(Icons.person, color: Colors.blue),
                  title: Text(
                    atSign,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500),
                  ),
                  onTap: () => Navigator.of(context).pop(atSign),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );

      if (!mounted) return;

      if (selectedAtSign == null) {
        // User cancelled
        return;
      }

      // Create auth request with keychain storage
      final request = AtAuthRequest(
        selectedAtSign,
        atKeysIo: KeychainAtKeysIo(),
        rootDomain: AtRootDomain.atsignDomain,
      );

      // Authenticate using PKAM dialog
      final response = await PkamDialog.show(
        context,
        request: request,
      );

      if (!mounted) return;

      if (response != null && response.isSuccessful) {
        // Initialize AtService with AtClientPreference
        final atService = Provider.of<AtService>(context, listen: false);
        final preference = await _getAtClientPreference();
        await atService.initializeWithAuthResponse(response, preference);

        // Set up config service
        if (atService.atClient != null) {
          final configService =
              Provider.of<ConfigService>(context, listen: false);
          configService.setAtClient(atService.atClient);
          await configService.loadConfig();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to select atSign: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Show custom atSign selection dialog for activation
  Future<AuthRequest?> _showAtSignSelectionDialog(BuildContext context) async {
    final atSignController = TextEditingController();
    final rootDomainController = TextEditingController(text: 'root.atsign.org');

    return showDialog<AuthRequest>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.white,
        title: const Text(
          'Select atSign',
          style: TextStyle(
              color: Colors.black87, fontSize: 20, fontWeight: FontWeight.bold),
        ),
        content: SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: atSignController,
                style: const TextStyle(color: Colors.black87, fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'atSign',
                  hintText: '@yourname',
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: const OutlineInputBorder(),
                  labelStyle: const TextStyle(color: Colors.black87),
                  hintStyle: TextStyle(color: Colors.grey.shade600),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: rootDomainController,
                style: const TextStyle(color: Colors.black87, fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'Root Domain',
                  filled: true,
                  fillColor: Colors.grey.shade100,
                  border: const OutlineInputBorder(),
                  labelStyle: const TextStyle(color: Colors.black87),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.black87)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              final atSign = atSignController.text.trim();
              if (atSign.isEmpty) return;

              final authRequest = AtAuthRequest(
                atSign.startsWith('@') ? atSign : '@$atSign',
                rootDomain: AtRootDomain(rootDomainController.text.trim(), 64),
              );
              Navigator.of(dialogContext).pop(authRequest);
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  /// Activate a new atSign using CRAM authentication
  Future<void> _activateNewAtSign(BuildContext context) async {
    setState(() => _isLoading = true);

    try {
      // Show custom atSign selection dialog
      final authRequest = await _showAtSignSelectionDialog(context);

      if (!mounted) return;

      if (authRequest == null) {
        // User cancelled
        return;
      }

      // Get CRAM secret from registrar
      // Note: You can optionally use RegistrarService and RegistrarCramDialog
      // For now, show a dialog to get CRAM secret manually
      final cramSecret =
          await _showCramSecretDialog(context, authRequest.atSign);

      if (!mounted) return;

      if (cramSecret == null || cramSecret.isEmpty) {
        // User cancelled
        return;
      }

      // Create AtOnboardingRequest from the auth request
      final onboardingRequest = AtOnboardingRequest(
        authRequest.atSign,
        rootDomain: authRequest.rootDomain,
      );

      // Perform CRAM onboarding
      // Note: CramDialog automatically saves keys to keychain via its internal storage
      final response = await CramDialog.show(
        context,
        request: onboardingRequest,
        cramKey: cramSecret,
      );

      if (!mounted) return;

      if (response != null && response.isSuccessful) {
        // Initialize AtService with AtClientPreference
        final atService = Provider.of<AtService>(context, listen: false);
        final preference = await _getAtClientPreference();

        // CramDialog returns AtOnboardingResponse, convert to AtAuthResponse
        final authResponse = AtAuthResponse(response.atSign)
          ..isSuccessful = response.isSuccessful
          ..atAuthKeys = response.atAuthKeys
          ..atChops = response.atChops
          ..atLookUp = response.atLookUp;

        await atService.initializeWithAuthResponse(authResponse, preference);

        // Set up config service
        if (atService.atClient != null) {
          final configService =
              Provider.of<ConfigService>(context, listen: false);
          configService.setAtClient(atService.atClient);
          await configService.loadConfig();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to activate atSign: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Show dialog to get CRAM secret
  Future<String?> _showCramSecretDialog(
      BuildContext context, String atSign) async {
    final controller = TextEditingController();

    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        title: Text(
          'CRAM Secret for $atSign',
          style: const TextStyle(
              color: Colors.black87, fontWeight: FontWeight.bold),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Enter the CRAM secret for this atSign. You can find this in your email or atSign dashboard.',
              style: TextStyle(fontSize: 14, color: Colors.black87),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.black87),
              decoration: const InputDecoration(
                hintText: 'CRAM Secret',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  /// Manage paired atSigns - show list with delete options
  Future<void> _managePairedAtsigns(BuildContext context) async {
    try {
      // Get all atSigns
      final existingAtSigns = await _keychainStorage.getAllAtsigns();

      if (!mounted) return;

      if (existingAtSigns.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No paired atSigns found'),
            backgroundColor: Colors.orange,
          ),
        );
        return;
      }

      // Show dialog with list of atSigns and delete options - improved colors
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: Colors.white,
          title: const Text(
            'Manage Paired atSigns',
            style:
                TextStyle(color: Colors.black87, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: existingAtSigns.length,
              itemBuilder: (context, index) {
                final atSign = existingAtSigns[index];
                return Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: ListTile(
                    leading: const Icon(Icons.account_circle,
                        color: Colors.blue, size: 28),
                    title: Text(
                      atSign,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.black87,
                      ),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () async {
                        // Confirm deletion
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            backgroundColor: Colors.white,
                            title: const Text(
                              'Delete atSign',
                              style: TextStyle(
                                  color: Colors.black87,
                                  fontWeight: FontWeight.bold),
                            ),
                            content: Text(
                              'Are you sure you want to remove $atSign from this device?\n\nThis will not delete your atSign account, only remove the stored keys from this device.',
                              style: const TextStyle(color: Colors.black87),
                            ),
                            actions: [
                              TextButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(false),
                                child: const Text('Cancel'),
                              ),
                              ElevatedButton(
                                onPressed: () =>
                                    Navigator.of(context).pop(true),
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red),
                                child: const Text('Delete',
                                    style: TextStyle(color: Colors.white)),
                              ),
                            ],
                          ),
                        );

                        if (confirmed == true) {
                          try {
                            await _keychainStorage
                                .removeAtsignFromKeychain(atSign);
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Removed $atSign'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                              // Close the manage dialog and refresh
                              Navigator.of(context).pop();
                              _managePairedAtsigns(context);
                            }
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Failed to remove $atSign: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        }
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load atSigns: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}
