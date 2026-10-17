import 'dart:async';

import '../models/beacon_measurement.dart';
import '../models/building_config.dart';
import '../models/motion_state.dart';
import '../models/positioning_state.dart';
import '../utils/pos_log.dart';
import '../utils/tick_recorder.dart';
import 'ble_position_estimator.dart';
import 'ble_service.dart';
import 'graph_position_service.dart';
import 'motion_service.dart';
import 'pdr_service.dart';
import 'position_fusion_service.dart';

/// Orchestrates the whole positioning pipeline.
///
///   BLE (periodic)  \
///                    -> fusion tick (controlled rate) -> PositioningSnapshot
///   Sensors (fast)  /                                      -> UI
///
/// Sensors and BLE are sampled at their own rates; the position is computed
/// at `positioning.fusionIntervalMs`; the UI animates between snapshots.
class PositioningService {
  PositioningService({
    required this.config,
    BleService? ble,
    MotionService? motion,
    DateTime Function()? clock,
  })  : _clock = clock ?? DateTime.now,
        graph = GraphPositionService(config),
        ble = ble ?? BleService(config: config, clock: clock),
        motion = motion ?? MotionService(config: config.positioning.motion),
        pdr = PdrService(config.positioning.motion) {
    // Enable logging BEFORE the estimator is built, so its start-up warnings
    // (e.g. "beacon has no graph anchor") are actually printed.
    PosLog.enabled = config.positioning.debug.logging;
    recorder = config.positioning.debug.recording ? TickRecorder() : null;
    estimator = BlePositionEstimator(graph: graph, config: config);
    fusion = PositionFusionService(graph: graph, config: config);
  }

  final BuildingConfig config;
  final DateTime Function() _clock;

  final GraphPositionService graph;
  final BleService ble;
  final MotionService motion;
  final PdrService pdr;
  late final BlePositionEstimator estimator;
  late final PositionFusionService fusion;

  /// Non-null when `debug.recording` is on: logs every tick for offline replay.
  late final TickRecorder? recorder;

  final StreamController<PositioningSnapshot> _controller =
      StreamController<PositioningSnapshot>.broadcast();

  Timer? _timer;
  StreamSubscription<dynamic>? _stepSub;
  DateTime? _lastTick;
  bool _running = false;
  bool _disposed = false;
  Map<String, String> _routeNext = const {};
  PositioningSnapshot? _latest;

  Stream<PositioningSnapshot> get snapshots => _controller.stream;
  PositioningSnapshot? get latest => _latest;
  bool get isRunning => _running;

  /// nodeId -> next nodeId on the active route; biases direction and turn
  /// choices. Pass an empty map when not navigating.
  void setRouteHint(Map<String, String> routeNext) => _routeNext = routeNext;

  Future<void> start() async {
    if (_disposed || _running) return;
    _running = true;
    PosLog.enabled = config.positioning.debug.logging;

    _stepSub ??= motion.steps.listen(pdr.onStep);
    motion.start();
    await ble.start();

    // The service may have been stopped/disposed while BLE was starting.
    if (_disposed || !_running) return;

    _timer ??= Timer.periodic(
      Duration(milliseconds: config.positioning.params.fusionIntervalMs),
      (_) => tick(_clock()),
    );
  }

  /// Stops sensors, scanning and the timer (e.g. app in background). The
  /// current position is kept so [start] resumes smoothly.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    _timer = null;
    await _stepSub?.cancel();
    _stepSub = null;
    motion.stop();
    await ble.stop();
    _lastTick = null;
  }

  /// One fusion step. Public so it can be driven deterministically in tests.
  void tick(DateTime now) {
    if (_disposed) return;
    final dt = _lastTick == null
        ? config.positioning.params.fusionIntervalMs / 1000.0
        : now.difference(_lastTick!).inMicroseconds / 1e6;
    _lastTick = now;

    final MotionSnapshot motionSnap = motion.snapshot(now);
    final List<BeaconMeasurement> measurements = ble.snapshot(now);

    final fix = estimator.estimate(measurements, now, prior: fusion.location);

    if (motionSnap.shakeSuspected) pdr.discard();
    final stepMeters = pdr.drain(dt, motionSnap);

    final out = fusion.update(
      now: now,
      fix: fix,
      motion: motionSnap,
      stepDistanceMeters: stepMeters,
      routeNext: _routeNext,
    );

    recorder?.record(
      now: now,
      measurements: measurements,
      motion: motionSnap,
      stepMeters: stepMeters,
      routeNext: _routeNext,
      fix: fix,
      out: out,
    );

    final loc = out.location;
    final usedIds = fix?.usedBeaconIds ?? const <String>[];

    String? bestId;
    var bestQ = -1.0;
    final diag = <BeaconDiagnostic>[];
    for (final m in measurements) {
      if (m.quality > bestQ) {
        bestQ = m.quality;
        bestId = m.beaconId;
      }
      diag.add(BeaconDiagnostic(
        beaconId: m.beaconId,
        mac: m.macAddress,
        rawRssi: m.rawRssi,
        filteredRssi: m.filteredRssi,
        distance: m.estimatedDistance,
        quality: m.quality,
        ageMs: m.ageMs(now),
        used: usedIds.contains(m.beaconId),
      ));
    }

    final snap = PositioningSnapshot(
      time: now,
      state: out.state,
      location: loc,
      position: loc == null ? null : graph.pointOf(loc),
      nearestNodeId: loc == null ? null : graph.nearestNodeId(loc),
      edgeFromId: loc == null ? null : graph.edges[loc.edge].fromId,
      edgeToId: loc == null ? null : graph.edges[loc.edge].toId,
      edgeLengthMeters: loc == null ? null : graph.edges[loc.edge].lengthMeters,
      confidence: out.confidence,
      bleConfidence: out.bleConfidence,
      pdrConfidence: out.pdrConfidence,
      graphConfidence: out.graphConfidence,
      motionConfidence: out.motionConfidence,
      rawBlePosition: fix == null ? null : graph.pointOf(fix.location),
      pdrPosition: out.predicted == null ? null : graph.pointOf(out.predicted!),
      motion: motionSnap,
      beacons: diag,
      bleMethod: fix?.method,
      bleRejectReason: fix == null ? estimator.lastRejectReason : null,
      pendingCandidate: out.pendingCandidate,
      bestBeaconId: bestId,
    );

    _latest = snap;
    if (!_controller.isClosed) _controller.add(snap);

    if (loc != null) {
      PosLog.d(
        'POSITION',
        () => 'edge=${graph.edges[loc.edge].fromId}->${graph.edges[loc.edge].toId} '
            'along=${loc.distance.toStringAsFixed(2)}m '
            'final=(${snap.position!.dx.toStringAsFixed(0)},${snap.position!.dy.toStringAsFixed(0)}) '
            'confidence=${out.confidence.toStringAsFixed(2)}',
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    // Cancel every timer / sensor subscription SYNCHRONOUSLY first, so nothing
    // keeps running (or stays pending) while the async clean-up below finishes.
    _disposed = true;
    _running = false;
    _timer?.cancel();
    _timer = null;
    _stepSub?.cancel();
    _stepSub = null;
    motion.dispose();
    final bleDone = ble.dispose();
    await bleDone;
    await _controller.close();
  }
}
