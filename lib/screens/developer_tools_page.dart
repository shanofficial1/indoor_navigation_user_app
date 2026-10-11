import 'package:flutter/material.dart';

/// Admin / developer tools, hidden from normal users.
/// Open it by tapping the app-bar title 5 times on the home screen.
class DeveloperToolsPage extends StatelessWidget {
  const DeveloperToolsPage({
    super.key,
    required this.diagnosticsOn,
    required this.onToggleDiagnostics,
    required this.onOpenStepTest,
    required this.onOpenBleScanner,
  });

  final bool diagnosticsOn;
  final VoidCallback onToggleDiagnostics;
  final VoidCallback onOpenStepTest;
  final VoidCallback onOpenBleScanner;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Developer Tools')),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.bug_report_outlined),
            title: const Text('Positioning diagnostics overlay'),
            subtitle: const Text('RSSI, distances, confidence, fusion state'),
            value: diagnosticsOn,
            onChanged: (_) {
              onToggleDiagnostics();
              Navigator.pop(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('Step test log'),
            subtitle: const Text('Live step detector, thresholds, shake rejection'),
            onTap: onOpenStepTest,
          ),
          ListTile(
            leading: const Icon(Icons.bluetooth_searching),
            title: const Text('BLE scanner'),
            subtitle: const Text('Raw scan of nearby beacons (pauses positioning)'),
            onTap: onOpenBleScanner,
          ),
        ],
      ),
    );
  }
}
