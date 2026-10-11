import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// Thin wrapper around FlutterBluePlus scanning.
///
/// Guarantees: one results listener, one scan-state listener, never two
/// concurrent startScan calls, and `isScanning` follows the REAL scanner state
/// (so it is correct after Android or the user stops the scan).
class BleScannerService {
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _scanStateSubscription;

  final StreamController<List<ScanResult>> _resultsController =
      StreamController<List<ScanResult>>.broadcast();

  final StreamController<bool> _scanStateController =
      StreamController<bool>.broadcast();

  bool _isScanning = false;
  bool _starting = false;
  bool _disposed = false;

  Stream<List<ScanResult>> get results => _resultsController.stream;

  Stream<bool> get scanState => _scanStateController.stream;

  bool get isScanning => _isScanning;

  void _attachListeners() {
    _scanSubscription ??= FlutterBluePlus.onScanResults.listen(
      (results) {
        if (results.isEmpty || _resultsController.isClosed) return;
        _resultsController.add(results);
      },
      onError: (error) => debugPrint('BLE SCAN ERROR: $error'),
    );

    _scanStateSubscription ??= FlutterBluePlus.isScanning.listen(
      (scanning) {
        _isScanning = scanning;
        if (!_scanStateController.isClosed) {
          _scanStateController.add(scanning);
        }
      },
      onError: (error) => debugPrint('BLE STATE ERROR: $error'),
    );
  }

  Future<void> startScan() async {
    if (_disposed || _isScanning || _starting) return;
    _starting = true;

    try {
      _attachListeners();

      await FlutterBluePlus.startScan(
        androidScanMode: AndroidScanMode.lowLatency,
        continuousUpdates: true,
        continuousDivisor: 1,
        oneByOne: true,
        timeout: null,
      );
      _isScanning = true;
    } catch (e) {
      _isScanning = false;
      debugPrint('BLE START ERROR: $e');
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> stopScan() async {
    try {
      if (_isScanning || FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (e) {
      debugPrint('BLE STOP ERROR: $e');
    }
    _isScanning = false;
  }

  Future<void> restart() async {
    await stopScan();
    await startScan();
  }

  Future<void> dispose() async {
    _disposed = true;
    await stopScan();

    await _scanSubscription?.cancel();
    _scanSubscription = null;

    await _scanStateSubscription?.cancel();
    _scanStateSubscription = null;

    await _resultsController.close();
    await _scanStateController.close();
  }
}
