import 'dart:math' as math;

import '../models/building_config.dart';
import '../models/graph_location.dart';
import '../models/motion_state.dart';
import '../models/positioning_config.dart';
import '../models/positioning_state.dart';
import '../utils/geometry_utils.dart';
import '../utils/pos_log.dart';
import '../utils/smoothing_utils.dart';
import 'ble_position_estimator.dart';
import 'graph_position_service.dart';

class _Pending {
  _Pending(this.location, DateTime now, this.confidence)
      : first = now,
        last = now;
  GraphLocation location;
  final DateTime first;
  DateTime last;
  double confidence;
  int samples = 1;
}

class _TimedLoc {
  _TimedLoc(this.time, this.loc);
  final DateTime time;
  final GraphLocation loc;
}

class _TimedMeters {
  _TimedMeters(this.time, this.meters);
  final DateTime time;
  final double meters;
}

class FusionOutput {
  const FusionOutput({
    required this.location,
    required this.predicted,
    required this.state,
    required this.confidence,
    required this.bleConfidence,
    required this.pdrConfidence,
    required this.graphConfidence,
    required this.motionConfidence,
    required this.pendingCandidate,
  });

  final GraphLocation? location;

  /// Dead-reckoned position of this tick (before BLE correction).
  final GraphLocation? predicted;
  final PositioningState state;
  final double confidence;
  final double bleConfidence;
  final double pdrConfidence;
  final double graphConfidence;
  final double motionConfidence;
  final bool pendingCandidate;
}

/// Fuses BLE fixes with PDR movement on the navigation graph.
///
///   PDR prediction  -> BLE innovation -> gate / confirm -> gradual correction
///   -> speed validation -> confidence -> state machine
///
/// BLE is the (noisy) absolute reference; PDR gives short-term continuity.
/// The fused position lives ON the graph (edge + metres along it), and is
/// never set directly from a BLE fix except at initialisation and when
/// recovering from LOST with strong, confirmed evidence.
class PositionFusionService {
  PositionFusionService({required this.graph, required this.config})
      : _offsetEma = AngleEma(0.25) {
    _configuredOffset = _motion.heading.mapNorthOffsetDegrees == null
        ? null
        : degToRad(_motion.heading.mapNorthOffsetDegrees!);
  }

  final GraphPositionService graph;
  final BuildingConfig config;

  PositioningParams get _p => config.positioning.params;
  PositionSmoothingConfig get _s => config.positioning.smoothing;
  MotionConfig get _motion => config.positioning.motion;

  // ---- position state -----------------------------------------------------
  GraphLocation? _loc;
  int _dir = 1;
  DateTime? _lastTick;
  DateTime? _lastFixTime;
  BleFix? _lastFix;
  double _distSinceBle = 0.0;
  int _ticks = 0;

  // ---- candidate handling ---------------------------------------------------
  _Pending? _pending;
  GraphLocation? _target;
  bool _targetConfirmed = false;
  bool _wasLost = false;

  // ---- heading alignment (map frame vs compass frame) ----------------------
  final AngleEma _offsetEma;
  double? _configuredOffset;
  int _offsetSamples = 0;
  GraphLocation? _learnLoc;
  DateTime? _learnTime;

  // ---- context validation windows -------------------------------------------
  final List<_TimedMeters> _pdrWindow = [];
  final List<_TimedLoc> _fixWindow = [];
  static const int _contextWindowMs = 6000;
  static const double _contextMinPdrMeters = 4.0;
  static const double _contextMinProgressRatio = 0.2;
  static const double _contextPenalty = 0.3;

  // ---- exposed ---------------------------------------------------------------
  GraphLocation? get location => _loc;

  /// Read-only: current map-vs-compass offset (configured, else learned).
  double? get mapHeadingOffsetRad => _mapOffset();
  bool get hasPendingCandidate => _pending != null;

  void reset() {
    _loc = null;
    _lastTick = null;
    _lastFixTime = null;
    _lastFix = null;
    _distSinceBle = 0.0;
    _ticks = 0;
    _pending = null;
    _target = null;
    _targetConfirmed = false;
    _wasLost = false;
    _pdrWindow.clear();
    _fixWindow.clear();
  }

  // ==========================================================================
  // main update
  // ==========================================================================

  FusionOutput update({
    required DateTime now,
    required BleFix? fix,
    required MotionSnapshot motion,
    required double stepDistanceMeters,
    required Map<String, String> routeNext,
  }) {
    final dt = _lastTick == null
        ? _p.fusionIntervalMs / 1000.0
        : (now.difference(_lastTick!).inMicroseconds / 1e6).clamp(0.02, 1.0).toDouble();
    _lastTick = now;
    _ticks++;

    final stationary = motion.state == MotionState.stationary;
    final usable =
        (fix != null && fix.confidence >= _p.minimumFixConfidence) ? fix : null;

    // ---- 1. initial position --------------------------------------------
    if (_loc == null) {
      if (usable != null) {
        final accepted = _confirm(usable, now);
        if (accepted != null) {
          _loc = accepted;
          _lastFixTime = now;
          _lastFix = usable;
          _distSinceBle = 0.0;
          PosLog.d('POSITION', () => 'initial fix accepted: $accepted');
        }
      }
      if (_loc == null) {
        return _output(now, null, null, motion, usable, 0.0, false);
      }
    }

    final prevLoc = _loc!;

    // ---- 2. PDR prediction -----------------------------------------------
    if (stepDistanceMeters > 0 && !motion.shakeSuspected) {
      final dist = stepDistanceMeters * _contextFactor(now);
      _dir = _decideDirection(motion, routeNext);
      final res = graph.moveAlong(
        _loc!,
        dist,
        _dir,
        policy: TurnPolicy(
          routeNext: routeNext,
          headingBearing: _headingBearing(motion),
        ),
      );
      _loc = res.location;
      _dir = res.direction;
      _distSinceBle += dist;
      _pdrWindow.add(_TimedMeters(now, dist));
      PosLog.d(
        'PDR',
        () => 'previous=$prevLoc predicted=${res.location} step=${dist.toStringAsFixed(2)}m',
      );
    }
    final predicted = _loc;

    // ---- 3. BLE innovation, gating, temporal confirmation ----------------
    var innovation = 0.0;
    if (usable != null) {
      _lastFixTime = now;
      _lastFix = usable;
      innovation = graph.graphDistance(_loc!, usable.location);
      final deadband =
          stationary ? _p.stationaryHoldRadiusMeters : _p.bleDeadbandMeters;
      _learnHeading(usable, motion, now);
      if (usable.method != 'proximity') {
        _fixWindow.add(_TimedLoc(now, usable.location));
      }

      if (innovation <= deadband) {
        // BLE and dead reckoning agree: nothing to correct, drift reset.
        _pending = null;
        _target = null;
        _targetConfirmed = false;
        _distSinceBle = 0.0;
      } else if (innovation <= _s.maxJumpMeters && !_wasLost) {
        // Plausible small correction: blend in gradually.
        _pending = null;
        _target = usable.location;
        _targetConfirmed = false;
      } else {
        // Suspicious jump: needs sustained, consistent evidence first.
        final accepted = _confirm(usable, now);
        if (accepted != null) {
          final dist = graph.graphDistance(_loc!, accepted);
          if (_wasLost && dist > _p.recoveryTeleportMeters) {
            PosLog.d('POSITION', () => 'recovery snap ${dist.toStringAsFixed(1)} m');
            _loc = accepted;
            _target = null;
            _targetConfirmed = false;
            _distSinceBle = 0.0;
          } else {
            _target = accepted;
            _targetConfirmed = true;
          }
        } else if (_target != null && !_targetConfirmed) {
          _target = null;
        }
      }
    } else {
      final p = _pending;
      if (p != null && now.difference(p.last).inMilliseconds > _s.confirmationDurationMs) {
        _pending = null;
      }
      if (!_targetConfirmed) _target = null; // never chase a stale fix
    }

    // ---- 4. weights ----------------------------------------------------------
    final bleAgeMs = _lastFixTime == null
        ? double.infinity
        : now.difference(_lastFixTime!).inMicroseconds / 1000.0;
    final bleConf = usable != null
        ? usable.confidence
        : (_lastFix?.confidence ?? 0.0) * expDecay(bleAgeMs.isFinite ? bleAgeMs : 1e9, 2000.0);
    final pdrConf = _pdrConfidence(motion, bleAgeMs, now);

    // ---- 5. gradual correction towards the accepted target -----------------
    if (_target != null) {
      final remaining = graph.graphDistance(_loc!, _target!);
      if (remaining < 0.05) {
        _target = null;
        _targetConfirmed = false;
        _distSinceBle = 0.0;
      } else {
        final wSum = bleConf + pdrConf;
        final k = wSum <= 0 ? 0.0 : bleConf / wSum;
        final tau = _p.correctionTimeConstantMs /
            1000.0 *
            (stationary ? _p.stationaryCorrectionScale : 1.0);
        var move = remaining * k * timeGain(dt, tau);
        final cap = _p.maxCorrectionSpeedMps *
            dt *
            (motion.state == MotionState.running ? 2.0 : 1.0);
        move = math.min(move, cap);
        if (move > 0) _loc = graph.moveToward(_loc!, _target!, move);
      }
    }

    // ---- 6. speed validation ---------------------------------------------------
    final moved = graph.graphDistance(prevLoc, _loc!);
    final maxMove = _p.maxSpeedMps * dt;
    if (moved > maxMove + 1e-6 && _loc!.edge >= 0) {
      PosLog.d('POSITION', () => 'clamped ${moved.toStringAsFixed(2)} -> ${maxMove.toStringAsFixed(2)} m');
      _loc = graph.moveToward(prevLoc, _loc!, maxMove);
    }

    _trimWindows(now);
    return _output(now, predicted, _loc, motion, usable, innovation, true);
  }

  // ==========================================================================
  // temporal confirmation
  // ==========================================================================

  /// Registers support for a candidate. Returns the candidate once it has been
  /// repeatedly supported for the configured time, otherwise null.
  GraphLocation? _confirm(BleFix fix, DateTime now) {
    final p = _pending;
    if (p == null ||
        now.difference(p.last).inMilliseconds > _s.confirmationDurationMs ||
        graph.graphDistance(p.location, fix.location) > _s.confirmationRadiusMeters) {
      _pending = _Pending(fix.location, now, fix.confidence);
      return null;
    }

    p.samples++;
    p.last = now;
    p.location = fix.location;
    p.confidence = fix.confidence;

    final elapsed = now.difference(p.first).inMilliseconds;
    if (elapsed >= _s.confirmationDurationMs &&
        p.samples >= _s.confirmationMinSamples) {
      _pending = null;
      return p.location;
    }
    return null;
  }

  // ==========================================================================
  // direction / heading
  // ==========================================================================

  double? _mapOffset() {
    if (_configuredOffset != null) return _configuredOffset;
    return _offsetSamples >= 2 ? _offsetEma.value : null;
  }

  /// Map-frame bearing the user is facing, if heading is trustworthy.
  double? _headingBearing(MotionSnapshot m) {
    if (!m.headingUsable(_motion.heading.minimumConfidence)) return null;
    final off = _mapOffset();
    if (off == null) return null;
    return wrapAngle(m.headingRad! + off);
  }

  /// +1 / -1 along the current edge. Heading first, then the active route,
  /// else keep going the way we were.
  int _decideDirection(MotionSnapshot motion, Map<String, String> routeNext) {
    final loc = _loc!;
    final e = graph.edges[loc.edge];
    final hb = _headingBearing(motion);
    if (hb != null && !motion.isTurning) {
      final c = math.cos(angleDiff(hb, graph.travelBearing(loc, 1)));
      if (c > _motion.heading.directionHysteresis) return 1;
      if (c < -_motion.heading.directionHysteresis) return -1;
    }
    if (routeNext[e.fromId] == e.toId) return 1;
    if (routeNext[e.toId] == e.fromId) return -1;
    return _dir;
  }

  /// Learns the map-vs-compass offset: while walking, if BLE fixes progress
  /// consistently along one edge, the edge direction tells us what the
  /// compass heading means on the map.
  void _learnHeading(BleFix fix, MotionSnapshot motion, DateTime now) {
    if (_configuredOffset != null) return;
    if (!motion.isMoving ||
        !motion.headingUsable(_motion.heading.minimumConfidence) ||
        fix.method == 'proximity') {
      _learnLoc = null;
      return;
    }
    final ref = _learnLoc;
    final refTime = _learnTime;
    if (ref == null || refTime == null) {
      _learnLoc = fix.location;
      _learnTime = now;
      return;
    }
    if (now.difference(refTime).inMilliseconds < 3000) return;

    if (fix.location.edge == ref.edge && fix.confidence >= 0.45) {
      final delta = fix.location.distance - ref.distance;
      if (delta.abs() >= 1.5) {
        final tb = graph.travelBearing(fix.location, delta > 0 ? 1 : -1);
        _offsetEma.update(wrapAngle(tb - motion.headingRad!));
        _offsetSamples++;
        PosLog.d('HEADING', () => 'map offset learned: ${radToDeg(_offsetEma.value!).toStringAsFixed(0)} deg');
      }
    }
    _learnLoc = fix.location;
    _learnTime = now;
  }

  // ==========================================================================
  // confidence, context, state
  // ==========================================================================

  double _pdrConfidence(MotionSnapshot motion, double bleAgeMs, DateTime now) {
    final ageTerm = bleAgeMs.isFinite ? bleAgeMs / (_p.lostTimeoutMs * 1.5) : 1.0;
    final drift = _distSinceBle / _p.pdrDriftScaleMeters + ageTerm;
    var c = _p.pdrConfidence * math.exp(-drift);
    if (motion.isMoving) {
      c *= (0.5 + 0.5 * motion.stepRegularity) * _contextFactor(now);
    }
    return clamp01(c);
  }

  /// BLE/context validation of the step stream: if PDR claims several metres
  /// but reliable BLE fixes show essentially no progress, the "steps" are
  /// probably not real walking - trust them less.
  double _contextFactor(DateTime now) {
    final cutoff = now.subtract(const Duration(milliseconds: _contextWindowMs));
    var pdr = 0.0;
    for (final s in _pdrWindow) {
      if (s.time.isAfter(cutoff)) pdr += s.meters;
    }
    if (pdr < _contextMinPdrMeters) return 1.0;
    final fixes = _fixWindow.where((f) => f.time.isAfter(cutoff)).toList();
    if (fixes.length < 2) return 1.0;
    final progress = graph.graphDistance(fixes.first.loc, fixes.last.loc);
    return progress < _contextMinProgressRatio * pdr ? _contextPenalty : 1.0;
  }

  void _trimWindows(DateTime now) {
    final cutoff = now.subtract(const Duration(milliseconds: _contextWindowMs));
    _pdrWindow.removeWhere((s) => s.time.isBefore(cutoff));
    _fixWindow.removeWhere((f) => f.time.isBefore(cutoff));
  }

  FusionOutput _output(
    DateTime now,
    GraphLocation? predicted,
    GraphLocation? loc,
    MotionSnapshot motion,
    BleFix? usable,
    double innovation,
    bool positioned,
  ) {
    if (!positioned || loc == null) {
      return FusionOutput(
        location: null,
        predicted: null,
        state: _ticks <= 1 ? PositioningState.initializing : PositioningState.searching,
        confidence: 0.0,
        bleConfidence: usable?.confidence ?? 0.0,
        pdrConfidence: 0.0,
        graphConfidence: 0.0,
        motionConfidence: 0.0,
        pendingCandidate: _pending != null,
      );
    }

    final bleAgeMs = _lastFixTime == null
        ? double.infinity
        : now.difference(_lastFixTime!).inMicroseconds / 1000.0;
    final bleConf = usable != null
        ? usable.confidence
        : (_lastFix?.confidence ?? 0.0) * expDecay(bleAgeMs.isFinite ? bleAgeMs : 1e9, 2000.0);
    final pdrConf = _pdrConfidence(motion, bleAgeMs, now);
    final graphConf = usable != null
        ? expDecay(innovation, _s.maxJumpMeters * 2)
        : 0.5;
    final motionConf = motion.isMoving
        ? motion.stepRegularity
        : (motion.state == MotionState.stationary ? 0.9 : 0.5);

    // Two partly independent sources: best one plus a bonus for agreement.
    final hi = math.max(bleConf, pdrConf);
    final lo = math.min(bleConf, pdrConf);
    final overall = clamp01(hi + 0.25 * lo);

    // ---- state machine ---------------------------------------------------
    final lost = bleAgeMs > _p.lostTimeoutMs && overall < _p.lowConfidenceThreshold;
    PositioningState state;
    if (lost) {
      _wasLost = true;
      state = PositioningState.lost;
    } else if (_wasLost &&
        !(usable != null && _pending == null && _target == null)) {
      state = PositioningState.recovering;
    } else {
      _wasLost = false;
      final turning = motion.isMoving &&
          motion.isTurning &&
          graph.distanceToNearestNode(loc) <= _p.graphTransitionThresholdMeters;
      if (overall < _p.lowConfidenceThreshold) {
        state = PositioningState.lowConfidence;
      } else if (turning) {
        state = PositioningState.turning;
      } else if (motion.isMoving) {
        state = PositioningState.moving;
      } else if (motion.state == MotionState.stationary) {
        state = PositioningState.stationary;
      } else {
        state = PositioningState.positioned;
      }
    }

    PosLog.d(
      'FUSION',
      () => 'BLE conf=${bleConf.toStringAsFixed(2)} PDR conf=${pdrConf.toStringAsFixed(2)} '
          'overall=${overall.toStringAsFixed(2)} state=${state.name}',
    );

    return FusionOutput(
      location: loc,
      predicted: predicted,
      state: state,
      confidence: overall,
      bleConfidence: bleConf,
      pdrConfidence: pdrConf,
      graphConfidence: graphConf,
      motionConfidence: motionConf,
      pendingCandidate: _pending != null,
    );
  }
}
