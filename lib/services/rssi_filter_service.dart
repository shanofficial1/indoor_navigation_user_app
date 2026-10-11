import 'dart:async';

import '../models/positioning_config.dart';
import '../utils/smoothing_utils.dart';

class _Track {
  /// Accepted (non-outlier) raw samples, newest last.
  final List<int> samples = <int>[];
  double? emaRaw;
  double? emaMean;
  int consecutiveOutliers = 0;
  int totalSamples = 0;
  int rejected = 0;
  int lastRaw = 0;
  DateTime lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
}

/// Per-beacon RSSI filter:
///
///   raw -> outlier rejection -> moving average / EMA -> filtered RSSI
///
/// The original public API (addSample, getFilteredRssi, getActiveFilteredRssi,
/// isActive, getSamples, getLastSeen, clear, clearAll, dispose) is unchanged.
class RssiFilterService {
  /// Minimum samples in the window before outlier rejection starts.
  static const int _minSamplesForOutlier = 3;

  final int maxSamples;

  /// Beacon is considered disconnected if no new RSSI is received for this long.
  final Duration expirationTime;

  final RssiFilterConfig config;
  final DateTime Function() _clock;

  final Map<String, _Track> _tracks = {};
  Timer? _cleanupTimer;

  RssiFilterService({
    int maxSamples = 5,
    this.expirationTime = const Duration(seconds: 3),
    RssiFilterConfig? config,
    DateTime Function()? clock,
    bool enableCleanupTimer = true,
  })  : config = config ?? const RssiFilterConfig(),
        maxSamples = config?.windowSize ?? maxSamples,
        _clock = clock ?? DateTime.now {
    if (enableCleanupTimer) {
      _cleanupTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _removeExpired(),
      );
    }
  }

  /// Add a NEW raw RSSI value; returns the current filtered RSSI.
  double addSample(String beaconId, int rssi) {
    final t = _tracks.putIfAbsent(beaconId, () => _Track());
    t.lastSeen = _clock();
    t.lastRaw = rssi;
    t.totalSamples++;

    if (config.enabled && t.samples.length >= _minSamplesForOutlier) {
      final ref = median(t.samples.map((e) => e.toDouble()).toList());
      if ((rssi - ref).abs() > config.outlierThresholdDb) {
        t.consecutiveOutliers++;
        if (t.consecutiveOutliers < config.outlierMaxConsecutive) {
          // Isolated spike (body shadow, multipath): ignore it.
          t.rejected++;
          return _output(t);
        }
        // Sustained change: the user really moved. Restart from this value.
        t.samples.clear();
        t.emaRaw = null;
        t.emaMean = null;
      }
    }
    t.consecutiveOutliers = 0;

    t.samples.add(rssi);
    while (t.samples.length > maxSamples) {
      t.samples.removeAt(0);
    }

    final a = config.emaAlpha;
    t.emaRaw = t.emaRaw == null ? rssi.toDouble() : t.emaRaw! + a * (rssi - t.emaRaw!);
    final m = _mean(t);
    t.emaMean = t.emaMean == null ? m : t.emaMean! + a * (m - t.emaMean!);

    return _output(t);
  }

  double _mean(_Track t) {
    if (t.samples.isEmpty) return t.lastRaw.toDouble();
    var s = 0;
    for (final v in t.samples) {
      s += v;
    }
    return s / t.samples.length;
  }

  double _output(_Track t) {
    if (!config.enabled) return t.lastRaw.toDouble();
    switch (config.mode) {
      case RssiFilterMode.movingAverage:
        return _mean(t);
      case RssiFilterMode.ema:
        return t.emaRaw ?? t.lastRaw.toDouble();
      case RssiFilterMode.movingAverageEma:
        return t.emaMean ?? t.lastRaw.toDouble();
    }
  }

  /// Current filtered RSSI, or null if the beacon expired / was never seen.
  double? getFilteredRssi(String beaconId) {
    final t = _tracks[beaconId];
    if (t == null) return null;
    if (_clock().difference(t.lastSeen) > expirationTime) {
      clear(beaconId);
      return null;
    }
    if (t.samples.isEmpty) return null;
    return _output(t);
  }

  Map<String, double> getActiveFilteredRssi() {
    _removeExpired();
    final result = <String, double>{};
    for (final id in _tracks.keys.toList()) {
      final v = getFilteredRssi(id);
      if (v != null) result[id] = v;
    }
    return result;
  }

  bool isActive(String beaconId) {
    final t = _tracks[beaconId];
    if (t == null) return false;
    if (_clock().difference(t.lastSeen) > expirationTime) {
      clear(beaconId);
      return false;
    }
    return true;
  }

  List<int> getSamples(String beaconId) =>
      List.unmodifiable(_tracks[beaconId]?.samples ?? const <int>[]);

  DateTime? getLastSeen(String beaconId) => _tracks[beaconId]?.lastSeen;

  /// Std-dev (dB) of the accepted window; a stability indicator.
  double stdDevOf(String beaconId) {
    final t = _tracks[beaconId];
    if (t == null) return 0.0;
    return stdDev(t.samples.map((e) => e.toDouble()).toList());
  }

  int sampleCountOf(String beaconId) => _tracks[beaconId]?.samples.length ?? 0;
  int rejectedCountOf(String beaconId) => _tracks[beaconId]?.rejected ?? 0;
  int? lastRawOf(String beaconId) => _tracks[beaconId]?.lastRaw;

  void clear(String beaconId) => _tracks.remove(beaconId);

  void clearAll() => _tracks.clear();

  void _removeExpired() {
    final now = _clock();
    _tracks.removeWhere(
      (_, t) => now.difference(t.lastSeen) > expirationTime,
    );
  }

  void dispose() {
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
    clearAll();
  }
}
