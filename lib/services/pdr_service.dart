import 'dart:math' as math;

import '../models/motion_state.dart';
import '../models/positioning_config.dart';
import '../utils/pos_log.dart';
import 'step_detector_service.dart';

/// Pedestrian dead reckoning: detected steps -> distance to walk.
///
/// A step queues `stepLength` metres. The queue is drained at a pace that
/// matches the user's current walking speed (cadence x step length, with a bit
/// of headroom) so the marker advances continuously instead of in 0.7 m hops.
/// Direction is NOT decided here - the fusion layer applies the distance along
/// the graph in the direction the user is travelling.
class PdrService {
  PdrService(this.config);

  final MotionConfig config;

  double _pendingMeters = 0.0;
  double _totalMeters = 0.0;

  /// Longest queue we tolerate; anything beyond is stale/garbage.
  static const double _maxPendingMeters = 4.0;

  /// Drain faster than the real speed so the queue never grows unbounded.
  static const double _drainHeadroom = 1.3;

  /// Cadence assumed before one has been measured.
  static const double _defaultCadenceHz = 1.8;

  double get totalMeters => _totalMeters;
  double get pendingMeters => _pendingMeters;

  double stepLengthFor(MotionState s) => s == MotionState.running
      ? config.stepLength.runningMeters
      : config.stepLength.walkingMeters;

  void onStep(StepDetectorEvent e) {
    final len = stepLengthFor(e.state);
    _pendingMeters = math.min(_pendingMeters + len, _maxPendingMeters);
    _totalMeters += len;
  }

  /// Metres to apply during this tick.
  double drain(double dtSec, MotionSnapshot motion) {
    if (_pendingMeters <= 0) return 0.0;
    final cadence = motion.cadenceHz > 0 ? motion.cadenceHz : _defaultCadenceHz;
    final speed = cadence * stepLengthFor(motion.state) * _drainHeadroom;
    final amount = math.min(_pendingMeters, speed * dtSec);
    _pendingMeters -= amount;
    PosLog.d('PDR', () => 'drain=${amount.toStringAsFixed(2)}m pending=${_pendingMeters.toStringAsFixed(2)}m');
    return amount;
  }

  /// Throw away queued movement (phone shaking: do not move the user).
  void discard() => _pendingMeters = 0.0;

  void reset() {
    _pendingMeters = 0.0;
    _totalMeters = 0.0;
  }
}
