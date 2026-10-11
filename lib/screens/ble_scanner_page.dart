import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../models/building_config.dart';
import '../services/ble_scanner_service.dart';
import '../services/rssi_filter_service.dart';

class BleScannerPage extends StatefulWidget {
  final BuildingConfig config;

  const BleScannerPage({
    super.key,
    required this.config,
  });

  @override
  State<BleScannerPage> createState() => _BleScannerPageState();
}

class _BleScannerPageState extends State<BleScannerPage> {
  final BleScannerService _scanner = BleScannerService();

 final RssiFilterService _rssiFilter =
    RssiFilterService(
  maxSamples: 10,
  expirationTime: const Duration(seconds: 2),
);
StreamSubscription<bool>? _scanStateSubscription;
  StreamSubscription<List<ScanResult>>? _subscription;
  Timer? _uiTimer;

  // Latest raw RSSI for each configured beacon.
  final Map<String, int> _liveRssi = {};

  // Latest filtered RSSI.
  final Map<String, double> _filteredRssi = {};

  // Time when the last BLE packet was received.
  final Map<String, DateTime> _lastUpdate = {};

final Map<String, int> _sampleCount = {};
final Map<String, int> _lastIntervalMs = {};
final Map<String, int> _lastSampleTimeUs = {};

  bool _scanning = false;

  @override
  void initState() {
    super.initState();

    // Listen continuously to BLE scan results.
   _subscription = _scanner.results.listen((results) {
  for (final result in results) {
    final mac = result.device.remoteId.str;

    final configuredBeacon = widget.config.beacons.where(
      (beacon) =>
          beacon.mac.toUpperCase() == mac.toUpperCase(),
    );

    if (configuredBeacon.isEmpty) {
      continue;
    }

    final now = DateTime.now();

    final nowUs =
        now.microsecondsSinceEpoch;

    // Calculate time since previous sample.
    final previousUs =
        _lastSampleTimeUs[mac];

    final intervalMs = previousUs == null
        ? 0
        : ((nowUs - previousUs) / 1000).round();

    // Store EVERY sample.
    _lastSampleTimeUs[mac] = nowUs;

    // Increase sample count even if RSSI is identical.
    _sampleCount[mac] =
        (_sampleCount[mac] ?? 0) + 1;

    _lastIntervalMs[mac] = intervalMs;

    // Moving average.
    final filtered =
        _rssiFilter.addSample(
      mac,
      result.rssi,
    );

    debugPrint(
      'RSSI SAMPLE | '
      'MAC: $mac | '
      'RSSI: ${result.rssi} dBm | '
'INTERVAL: $intervalMs ms | '
      'SAMPLE: ${_sampleCount[mac]}',
    );

    if (mounted) {
      setState(() {
        _liveRssi[mac] = result.rssi;
        _filteredRssi[mac] = filtered;
        _lastUpdate[mac] = now;
      });
    }
  }
});

_scanStateSubscription =
    _scanner.scanState.listen((scanning) {
  if (!mounted) return;

  setState(() {
    _scanning = scanning;
  });

  debugPrint(
    'APP BLE STATE: '
    '${scanning ? "SCANNING" : "STOPPED"}',
  );
});


    // UI heartbeat.
    //
    // This does NOT create fake RSSI measurements.
    // It only refreshes "Updated X ms ago" every 100 ms.
   _uiTimer = Timer.periodic(
  const Duration(milliseconds: 100),
  (_) {
    if (mounted && _scanning) {
      _removeExpiredBeacons();

      setState(() {});
    }
  },
);
  }

  Future<void> _startScan() async {
    if (_scanning) {
      return;
    }

    setState(() {
      _scanning = true;
      _liveRssi.clear();
      _filteredRssi.clear();
      _lastUpdate.clear();
      _sampleCount.clear();
_lastIntervalMs.clear();
_lastSampleTimeUs.clear();
      _rssiFilter.clearAll();
    });

    try {
      await _scanner.startScan();

      debugPrint('BLE SCANNING STARTED');
    } catch (e) {
      debugPrint('BLE START ERROR: $e');

      if (mounted) {
        setState(() {
          _scanning = false;
        });
      }
    }
  }

  Future<void> _stopScan() async {
    if (!_scanning) {
      return;
    }

    try {
      await _scanner.stopScan();

      debugPrint('BLE SCANNING STOPPED');
    } catch (e) {
      debugPrint('BLE STOP ERROR: $e');
    }

    if (mounted) {
      setState(() {
        _scanning = false;
      });
    }
  }

void _removeExpiredBeacons() {
  final now = DateTime.now();

  final expiredMacs = <String>[];

  for (final entry in _lastUpdate.entries) {
    final age = now.difference(entry.value);

    if (age > const Duration(seconds: 2)) {
      expiredMacs.add(entry.key);
    }
  }

  if (expiredMacs.isEmpty) {
    return;
  }

  for (final mac in expiredMacs) {
    _liveRssi.remove(mac);
    _filteredRssi.remove(mac);
    _lastUpdate.remove(mac);
    _sampleCount.remove(mac);
    _lastIntervalMs.remove(mac);
    _lastSampleTimeUs.remove(mac);

    _rssiFilter.clear(mac);

    debugPrint(
      'BEACON EXPIRED | MAC: $mac',
    );
  }

  if (mounted) {
    setState(() {});
  }
}


  @override
  void dispose() {
    _uiTimer?.cancel();
    _subscription?.cancel();
    _scanStateSubscription?.cancel();
    _scanner.dispose();

    super.dispose();
  }

  // Convert RSSI to progress-bar value.
  double _signalLevel(int rssi) {
    const minRssi = -110;
    const maxRssi = -40;

    final value =
        (rssi - minRssi) / (maxRssi - minRssi);

    return value.clamp(0.0, 1.0);
  }

  // Human-readable signal level.
  String _signalText(int rssi) {
    if (rssi >= -60) {
      return 'STRONG';
    }

    if (rssi >= -75) {
      return 'MEDIUM';
    }

    if (rssi >= -90) {
      return 'WEAK';
    }

    return 'VERY WEAK';
  }

  // How long since the last BLE packet arrived.
  String _updateAge(String mac) {
    final last = _lastUpdate[mac];

    if (last == null) {
      return 'waiting';
    }

    final difference =
        DateTime.now().difference(last);

    if (difference.inMilliseconds < 1000) {
      return '${difference.inMilliseconds} ms ago';
    }

    return '${difference.inSeconds}.${difference.inMilliseconds % 1000 ~/ 100}s ago';
  }

  Color _statusColor(String mac) {
    final last = _lastUpdate[mac];

    if (last == null) {
      return Colors.grey;
    }

    final age =
        DateTime.now().difference(last);

    if (age.inSeconds <= 2) {
      return Colors.green;
    }

    if (age.inSeconds <= 5) {
      return Colors.orange;
    }

    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final beacons = widget.config.beacons;

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE Scanner'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _scanning
                          ? Colors.green
                          : Colors.grey,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _scanning ? 'LIVE' : 'STOPPED',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // START / STOP BUTTON
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed:
                    _scanning ? _stopScan : _startScan,
                icon: Icon(
                  _scanning
                      ? Icons.stop
                      : Icons.bluetooth_searching,
                ),
                label: Text(
                  _scanning
                      ? 'STOP SCAN'
                      : 'START SCAN',
                ),
              ),
            ),
          ),

          // BEACON COUNT
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            child: Row(
              mainAxisAlignment:
                  MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Configured Beacons',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                Text(
                  '${beacons.length}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // BEACON LIST
          Expanded(
            child: beacons.isEmpty
                ? const Center(
                    child: Text(
                      'No configured beacons',
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(
                      bottom: 20,
                    ),
                    itemCount: beacons.length,
                    itemBuilder: (context, index) {
                      final beacon = beacons[index];

                      final rssi =
                          _liveRssi[beacon.mac];

                      final filtered =
                          _filteredRssi[beacon.mac];

                      final last =
                          _lastUpdate[beacon.mac];

                      final isDetected =
                          rssi != null;

                      return Card(
                        margin:
                            const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        child: Padding(
                          padding:
                              const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              // NAME + LIVE DOT
                              Row(
                                children: [
                                  Icon(
                                    Icons.bluetooth,
                                    color: isDetected
                                        ? Colors.blue
                                        : Colors.grey,
                                  ),
                                  const SizedBox(
                                    width: 10,
                                  ),
                                  Expanded(
                                    child: Text(
                                      beacon.name,
                                      style:
                                          const TextStyle(
                                        fontSize: 17,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 10,
                                    height: 10,
                                    decoration:
                                        BoxDecoration(
                                      shape:
                                          BoxShape.circle,
                                      color:
                                          _statusColor(
                                              beacon.mac),
                                    ),
                                  ),
                                ],
                              ),

                              const SizedBox(height: 5),

                              // MAC ADDRESS
                              Text(
                                beacon.mac,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),

                              const SizedBox(height: 14),

                              if (!isDetected)
                                const Row(
                                  children: [
                                    Icon(
                                      Icons
                                          .bluetooth_disabled,
                                      size: 20,
                                      color: Colors.grey,
                                    ),
                                    SizedBox(width: 8),
                                    Text(
                                      'Waiting for beacon...',
                                      style: TextStyle(
                                        color: Colors.grey,
                                      ),
                                    ),
                                  ],
                                )
                              else ...[
                                // RSSI VALUES
                                Row(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      '$rssi',
                                      style:
                                          const TextStyle(
                                        fontSize: 30,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(
                                      width: 4,
                                    ),
                                    const Padding(
                                      padding:
                                          EdgeInsets.only(
                                        bottom: 5,
                                      ),
                                      child: Text(
                                        'dBm',
                                        style:
                                            TextStyle(
                                          fontSize: 14,
                                          color:
                                              Colors.grey,
                                        ),
                                      ),
                                    ),
                                    const Spacer(),
                                    Text(
                                      _signalText(rssi),
                                      style:
                                          const TextStyle(
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 10),

                                // SIGNAL BAR
                                LinearProgressIndicator(
                                  value:
                                      _signalLevel(rssi),
                                  minHeight: 12,
                                  borderRadius:
                                      BorderRadius
                                          .circular(10),
                                ),

                                const SizedBox(height: 12),

                                // FILTERED RSSI
                              if (filtered != null)
  Row(
    mainAxisAlignment:
        MainAxisAlignment.spaceBetween,
    children: [
      const Text(
        'Filtered RSSI',
        style: TextStyle(
          color: Colors.grey,
        ),
      ),
      Text(
        '${filtered.toStringAsFixed(1)} dBm',
        style: const TextStyle(
          fontWeight: FontWeight.bold,
        ),
      ),
    ],
  ),

const SizedBox(height: 8),

// SAMPLE COUNT
Row(
  mainAxisAlignment:
      MainAxisAlignment.spaceBetween,
  children: [
    const Text(
      'Samples received',
      style: TextStyle(
        color: Colors.grey,
      ),
    ),
    Text(
      '${_sampleCount[beacon.mac] ?? 0}',
      style: const TextStyle(
        fontWeight: FontWeight.bold,
      ),
    ),
  ],
),

const SizedBox(height: 6),

// SAMPLE INTERVAL
Row(
  mainAxisAlignment:
      MainAxisAlignment.spaceBetween,
  children: [
    const Text(
      'Last sample interval',
      style: TextStyle(
        color: Colors.grey,
      ),
    ),
    Text(
      '${_lastIntervalMs[beacon.mac] ?? 0} ms',
      style: const TextStyle(
        fontWeight: FontWeight.bold,
      ),
    ),
  ],
),

const SizedBox(height: 8),

// LAST UPDATE
Row(
                                  children: [
                                    Icon(
                                      Icons.circle,
                                      size: 10,
                                      color:
                                          _statusColor(
                                              beacon.mac),
                                    ),
                                    const SizedBox(
                                      width: 7,
                                    ),
                                    Text(
                                      last == null
                                          ? 'Waiting'
                                          : 'LIVE • Updated ${_updateAge(beacon.mac)}',
                                      style:
                                          const TextStyle(
                                        fontSize: 12,
                                        fontWeight:
                                            FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}