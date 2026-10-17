import 'dart:convert';

import '../models/beacon_measurement.dart';
import '../models/building_config.dart';
import '../models/graph_location.dart';
import '../models/motion_state.dart';
import '../models/positioning_state.dart';
import '../services/ble_position_estimator.dart';
import '../services/graph_position_service.dart';
import '../services/position_fusion_service.dart';

/// One replayed tick.
class ReplayResult {
  const ReplayResult({
    required this.timeMs,
    required this.location,
    required this.state,
    required this.confidence,
    required this.fixMethod,
    required this.recorded,
    required this.mark,
  });

  final int timeMs;

  /// Position produced by the CURRENT code / config for this tick.
  final GraphLocation? location;
  final PositioningState state;
  final double confidence;

  /// 'ratio' | 'least-squares' | 'proximity' | null (no BLE fix this tick).
  final String? fixMethod;

  /// Position the phone actually showed when the walk was recorded (if any).
  final GraphLocation? recorded;

  /// Ground-truth label set during the walk (e.g. a node id), if any.
  final String? mark;
}

/// Re-runs a recording made by [TickRecorder] through the real
/// BlePositionEstimator + PositionFusionService, with whatever parameters the
/// given [BuildingConfig] holds. Pure Dart: no sensors, no BLE, no UI - so it
/// can be used from a unit test or a developer page.
///
/// Typical use:
///   final runner = ReplayRunner(config);
///   final results = runner.run(ReplayRunner.parseLog(logcatText));
///
/// Change a parameter in the config, build a new ReplayRunner, run the same
/// recording again, and compare the results against the marks.
class ReplayRunner {
  ReplayRunner(this.config) : graph = GraphPositionService(config) {
    estimator = BlePositionEstimator(graph: graph, config: config);
    fusion = PositionFusionService(graph: graph, config: config);
  }

  final BuildingConfig config;
  final GraphPositionService graph;
  late final BlePositionEstimator estimator;
  late final PositionFusionService fusion;

  /// Extracts the JSON records from raw logcat text (lines containing `[REC] `).
  static List<Map<String, dynamic>> parseLog(String text) {
    const tag = '[REC] ';
    final out = <Map<String, dynamic>>[];
    for (final line in const LineSplitter().convert(text)) {
      final i = line.indexOf(tag);
      if (i < 0) continue;
      try {
        final v = jsonDecode(line.substring(i + tag.length));
        if (v is Map) out.add(Map<String, dynamic>.from(v));
      } catch (_) {
        // truncated / interleaved line: skip it
      }
    }
    return out;
  }

  List<ReplayResult> run(Iterable<Map<String, dynamic>> records) {
    var route = <String, String>{};
    final results = <ReplayResult>[];

    for (final r in records) {
      final timeMs = (r['t'] as num).toInt();
      final now = DateTime.fromMillisecondsSinceEpoch(timeMs);

      final rt = r['route'];
      if (rt is Map) {
        route = rt.map((k, v) => MapEntry(k.toString(), v.toString()));
      }

      // ---- measurements -----------------------------------------------------
      final measurements = <BeaconMeasurement>[];
      final bl = r['b'];
      if (bl is List) {
        for (final raw in bl) {
          final b = raw as Map;
          final ageMs = (b['age'] as num).toDouble();
          measurements.add(BeaconMeasurement(
            beaconId: b['id'] as String,
            macAddress: '',
            nodeId: null,
            rawRssi: (b['raw'] as num).toInt(),
            filteredRssi: (b['f'] as num).toDouble(),
            estimatedDistance: (b['d'] as num).toDouble(),
            rssiStdDev: (b['sd'] as num).toDouble(),
            sampleCount: (b['n'] as num).toInt(),
            timestamp: now.subtract(Duration(microseconds: (ageMs * 1000).round())),
            quality: (b['q'] as num).toDouble(),
          ));
        }
      }

      // ---- motion -----------------------------------------------------------
      final m = Map<String, dynamic>.from(r['m'] as Map);
      final stateIdx = (m['s'] as num).toInt();
      final motion = MotionSnapshot(
        time: now,
        state: MotionState.values[stateIdx.clamp(0, MotionState.values.length - 1).toInt()],
        stepCount: (m['sc'] as num).toInt(),
        cadenceHz: (m['cad'] as num).toDouble(),
        stepRegularity: (m['reg'] as num).toDouble(),
        headingRad: m['hd'] is num ? (m['hd'] as num).toDouble() : null,
        headingConfidence: (m['hc'] as num).toDouble(),
        turnRateRadPerSec: (m['tr'] as num).toDouble(),
        isTurning: m['turn'] == true,
        shakeSuspected: m['shake'] == true,
        gyroAvailable: m['gyro'] == true,
        magnetometerAvailable: m['mag'] == true,
      );

      final step = (r['step'] as num).toDouble();

      // ---- exactly what PositioningService.tick does ------------------------
      final fix = estimator.estimate(measurements, now, prior: fusion.location);
      final out = fusion.update(
        now: now,
        fix: fix,
        motion: motion,
        stepDistanceMeters: step,
        routeNext: route,
      );

      GraphLocation? recorded;
      final ro = r['out'];
      if (ro is Map) {
        recorded =
            GraphLocation((ro['e'] as num).toInt(), (ro['d'] as num).toDouble());
      }

      results.add(ReplayResult(
        timeMs: timeMs,
        location: out.location,
        state: out.state,
        confidence: out.confidence,
        fixMethod: fix?.method,
        recorded: recorded,
        mark: r['mark'] as String?,
      ));
    }
    return results;
  }
}
