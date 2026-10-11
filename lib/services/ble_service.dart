import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/beacon_measurement.dart';
import '../models/building_config.dart';
import '../models/navigation_beacon.dart';
import '../utils/geometry_utils.dart';
import '../utils/pos_log.dart';
import '../utils/smoothing_utils.dart';
import 'ble_scanner_service.dart';
import 'distance_estimator.dart';
import 'rssi_filter_service.dart';

enum BleStatus { idle, scanning, bluetoothOff, unsupported, error }

class _BeaconState {
  _BeaconState(this.beacon);
  final NavigationBeacon beacon;
  int lastRaw = 0;
  DateTime lastTime = DateTime.fromMillisecondsSinceEpoch(0);
}

/// BLE layer. Turns raw scan packets into normalised [BeaconMeasurement]s.
///
///   scan -> MAC filter (configured+enabled only) -> RSSI filter -> distance
///
/// UI code never sees raw packets. Unknown devices are dropped at the door and
/// can never influence distance, position, route or UI.
class BleService {
  BleService({
    required this.config,
    BleScannerService? scanner,
    DateTime Function()? clock,
    bool enableCleanupTimer = true,
  })  : _scanner = scanner ?? BleScannerService(),
        _clock = clock ?? DateTime.now {
    final cfg = config.positioning;
    _filter = RssiFilterService(
      config: cfg.rssiFilter,
      expirationTime: Duration(milliseconds: cfg.ble.beaconTimeoutMs),
      clock: _clock,
      enableCleanupTimer: enableCleanupTimer,
    );
    _distance = DistanceEstimator(cfg.distanceModel);

    for (final b in config.beacons) {
      if (!b.enabled) continue;
      if (b.normalizedMac.isEmpty) {
        PosLog.d('BLE', () => 'beacon ${b.id} has an invalid MAC - ignored');
        continue;
      }
      _beaconsByMac[b.normalizedMac] = _BeaconState(b);
      _beaconsById[b.id] = _beaconsByMac[b.normalizedMac]!;
    }
  }

  final BuildingConfig config;
  final BleScannerService _scanner;
  final DateTime Function() _clock;

  late final RssiFilterService _filter;
  late final DistanceEstimator _distance;

  final Map<String, _BeaconState> _beaconsByMac = {};
  final Map<String, _BeaconState> _beaconsById = {};

  StreamSubscription<List<ScanResult>>? _resultsSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  StreamSubscription<bool>? _scanStateSub;
  Timer? _watchdog;

  bool _wanted = false;
  bool _disposed = false;
  bool? _adapterOn;
  DateTime? _lastStartAttempt;

  /// Number of distinct non-configured devices ignored (diagnostics only).
  int ignoredPackets = 0;

  final ValueNotifier<BleStatus> status = ValueNotifier(BleStatus.idle);

  // --------------------------------------------------------------------------
  // lifecycle
  // --------------------------------------------------------------------------

  Future<void> start() async {
    if (_disposed || _wanted) return;
    _wanted = true;

    _resultsSub ??= _scanner.results.listen(
      _onScanResults,
      onError: (Object e) => PosLog.d('BLE', () => 'results error: $e'),
    );

    _adapterSub ??= FlutterBluePlus.adapterState.listen(
      _onAdapterState,
      onError: (Object e) => PosLog.d('BLE', () => 'adapter error: $e'),
    );

    _scanStateSub ??= _scanner.scanState.listen((scanning) {
      if (scanning) {
        status.value = BleStatus.scanning;
      } else if (_wanted && _adapterOn != false) {
        status.value = BleStatus.idle;
      }
    });

    _watchdog ??= Timer.periodic(const Duration(seconds: 3), (_) {
      _ensureScanning();
    });

    await _tryStartScan();
  }

  Future<void> stop() async {
    _wanted = false;
    _watchdog?.cancel();
    _watchdog = null;
    await _scanner.stopScan();
    if (!_disposed) status.value = BleStatus.idle;
  }

  void _onAdapterState(BluetoothAdapterState s) {
    _adapterOn = s == BluetoothAdapterState.on;
    if (s == BluetoothAdapterState.unavailable) {
      status.value = BleStatus.unsupported;
      return;
    }
    if (!_adapterOn!) {
      status.value = BleStatus.bluetoothOff;
      _filter.clearAll(); // nothing we hold is current any more
      return;
    }
    if (_wanted) {
      _tryStartScan();
    }
  }

  void _ensureScanning() {
    if (!_wanted || _disposed) return;
    if (!(config.positioning.ble.autoRestartScan)) return;
    if (_adapterOn == false || _scanner.isScanning) return;
    final last = _lastStartAttempt;
    final backoff = config.positioning.ble.scanRestartBackoffMs;
    if (last != null && _clock().difference(last).inMilliseconds < backoff) {
      return;
    }
    _tryStartScan();
  }

  Future<void> _tryStartScan() async {
    if (!_wanted || _disposed) return;
    if (_adapterOn == false) {
      status.value = BleStatus.bluetoothOff;
      return;
    }
    _lastStartAttempt = _clock();
    try {
      await _scanner.startScan();
      if (_scanner.isScanning) status.value = BleStatus.scanning;
    } catch (e) {
      PosLog.d('BLE', () => 'scan start failed: $e');
      status.value = BleStatus.error;
    }
  }

  // --------------------------------------------------------------------------
  // ingestion
  // --------------------------------------------------------------------------

  void _onScanResults(List<ScanResult> results) {
    final now = _clock();
    for (final r in results) {
      final mac = NavigationBeacon.normalizeMac(r.device.remoteId.str);
      final st = _beaconsByMac[mac];
      if (st == null) {
        ignoredPackets++;
        continue; // MAC filter: unknown or disabled device -> ignored
      }
      _ingest(st, r.rssi, now);
    }
  }

  /// Feed one RSSI reading for a configured beacon (also used by tests).
  void ingestRssi(String beaconId, int rssi) {
    final st = _beaconsById[beaconId];
    if (st != null) _ingest(st, rssi, _clock());
  }

  void _ingest(_BeaconState st, int rssi, DateTime now) {
    final filtered = _filter.addSample(st.beacon.id, rssi);
    st.lastRaw = rssi;
    st.lastTime = now;
    PosLog.d(
      'BLE',
      () => '${st.beacon.id} RSSI=$rssi filtered=${filtered.toStringAsFixed(1)} '
          'distance=${_distance.estimateForBeacon(st.beacon, filtered).toStringAsFixed(1)}m',
    );
  }

  // --------------------------------------------------------------------------
  // measurements
  // --------------------------------------------------------------------------

  /// Current non-stale measurements of every configured beacon heard recently.
  List<BeaconMeasurement> snapshot(DateTime now) {
    final timeoutMs = config.positioning.ble.measurementTimeoutMs;
    final out = <BeaconMeasurement>[];

    for (final st in _beaconsById.values) {
      final ageMs = now.difference(st.lastTime).inMicroseconds / 1000.0;
      if (ageMs > timeoutMs) continue; // stale
      final filtered = _filter.getFilteredRssi(st.beacon.id);
      if (filtered == null) continue;

      final std = _filter.stdDevOf(st.beacon.id);
      final samples = _filter.sampleCountOf(st.beacon.id);

      // Intrinsic quality: strong, stable, fresh, well-sampled => close to 1.
      final strength = clamp01((filtered + 100.0) / 50.0); // -100..-50 dBm
      final stability =
          expDecay(std, config.positioning.params.rssiStabilityScaleDb);
      final freshness = clamp01(1.0 - ageMs / timeoutMs);
      final sampling = clamp01(samples / 3.0);
      final quality =
          0.4 * strength + 0.3 * stability + 0.2 * freshness + 0.1 * sampling;

      out.add(BeaconMeasurement(
        beaconId: st.beacon.id,
        macAddress: st.beacon.normalizedMac,
        nodeId: st.beacon.nodeId,
        rawRssi: st.lastRaw,
        filteredRssi: filtered,
        estimatedDistance: _distance.estimateForBeacon(st.beacon, filtered),
        rssiStdDev: std,
        sampleCount: samples,
        timestamp: st.lastTime,
        quality: quality,
      ));
    }
    return out;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    // Synchronous part: stop all timers immediately.
    _disposed = true;
    _wanted = false;
    _watchdog?.cancel();
    _watchdog = null;
    _filter.dispose();

    // Asynchronous part: scanner and stream subscriptions.
    await _scanner.stopScan();
    await _resultsSub?.cancel();
    _resultsSub = null;
    await _adapterSub?.cancel();
    _adapterSub = null;
    await _scanStateSub?.cancel();
    _scanStateSub = null;
    await _scanner.dispose();
    status.dispose();
  }
}
