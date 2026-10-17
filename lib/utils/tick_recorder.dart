import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/beacon_measurement.dart';
import '../models/motion_state.dart';
import '../services/ble_position_estimator.dart';
import '../services/position_fusion_service.dart';

/// Records the INPUTS and OUTPUT of every fusion tick as one compact JSON line:
///
///   [REC] {"t":..., "b":[...beacons...], "m":{...motion...}, "step":0.12,
///          "fix":{...}, "out":{...}, "mark":"N3"}
///
/// Lines go to logcat (`adb logcat -s flutter`), so no extra plugin is needed
/// and nothing leaves the phone. Feed the captured lines to
/// `ReplayRunner.parseLog` / `ReplayRunner.run` to re-run the exact same walk
/// with different parameters.
///
/// Turn on with `"debug": {"recording": true}` in the building JSON.
class TickRecorder {
  /// Last [maxLines] records, kept in memory for a future "copy log" button.
  final List<String> lines = <String>[];
  static const int maxLines = 3000;

  String? _pendingMark;
  String _lastRouteKey = '';

  /// Ground truth: call when the user is standing at a known place (e.g. a
  /// node id). The label is attached to the next record.
  void mark(String label) => _pendingMark = label;

  static double _r(double v, [int digits = 3]) =>
      v.isFinite ? double.parse(v.toStringAsFixed(digits)) : 0.0;

  void record({
    required DateTime now,
    required List<BeaconMeasurement> measurements,
    required MotionSnapshot motion,
    required double stepMeters,
    required Map<String, String> routeNext,
    required BleFix? fix,
    required FusionOutput out,
  }) {
    final routeKey =
        routeNext.entries.map((e) => '${e.key}>${e.value}').join(',');

    final loc = out.location;
    final rec = <String, dynamic>{
      't': now.millisecondsSinceEpoch,
      'b': [
        for (final b in measurements)
          {
            'id': b.beaconId,
            'raw': b.rawRssi,
            'f': _r(b.filteredRssi, 2),
            'sd': _r(b.rssiStdDev, 2),
            'n': b.sampleCount,
            'age': _r(b.ageMs(now), 0),
            'q': _r(b.quality, 3),
            'd': _r(b.estimatedDistance, 2),
          },
      ],
      'm': {
        's': motion.state.index,
        'sc': motion.stepCount,
        'cad': _r(motion.cadenceHz, 2),
        'reg': _r(motion.stepRegularity, 2),
        if (motion.headingRad != null) 'hd': _r(motion.headingRad!, 3),
        'hc': _r(motion.headingConfidence, 2),
        'tr': _r(motion.turnRateRadPerSec, 3),
        'turn': motion.isTurning,
        'shake': motion.shakeSuspected,
        'gyro': motion.gyroAvailable,
        'mag': motion.magnetometerAvailable,
      },
      'step': _r(stepMeters, 3),
      if (routeKey != _lastRouteKey) 'route': routeNext,
      if (fix != null)
        'fix': {
          'e': fix.location.edge,
          'd': _r(fix.location.distance, 2),
          'c': _r(fix.confidence, 3),
          'meth': fix.method,
        },
      if (loc != null)
        'out': {
          'e': loc.edge,
          'd': _r(loc.distance, 2),
          'st': out.state.name,
          'c': _r(out.confidence, 3),
        },
      if (_pendingMark != null) 'mark': _pendingMark,
    };
    _lastRouteKey = routeKey;
    _pendingMark = null;

    final line = jsonEncode(rec);
    lines.add(line);
    if (lines.length > maxLines) lines.removeRange(0, lines.length - maxLines);
    debugPrint('[REC] $line');
  }
}
