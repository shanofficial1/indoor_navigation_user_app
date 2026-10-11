import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import '../models/motion_state.dart';
import '../models/positioning_config.dart';
import '../utils/pos_log.dart';
import 'heading_service.dart';
import 'step_detector_service.dart';

/// Owns the motion sensors (accelerometer, gyroscope, magnetometer) and the
/// step / heading estimators built on them. Exposes one [MotionSnapshot].
///
/// Each sensor degrades independently: if one is missing or its stream fails
/// the rest keep working and the snapshot reports what is available.
class MotionService {
  MotionService({
    required this.config,
    StepDetectorService? stepDetector,
    HeadingService? heading,
  })  : stepDetector =
            stepDetector ?? StepDetectorService(config: config.stepDetection),
        heading = heading ?? HeadingService(config.heading);

  final MotionConfig config;
  final StepDetectorService stepDetector;
  final HeadingService heading;

  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyroSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  bool _running = false;
  bool _gyroFailed = false;
  bool _magFailed = false;

  Stream<StepDetectorEvent> get steps => stepDetector.events;

  void start() {
    if (_running) return;
    _running = true;
    _gyroFailed = false;
    _magFailed = false;

    stepDetector.start();

    final period = Duration(milliseconds: config.heading.samplingIntervalMs);

    _accSub = accelerometerEventStream(samplingPeriod: period).listen(
      (e) => heading.onAccelerometer(e.x, e.y, e.z, DateTime.now()),
      onError: (Object e) => PosLog.d('MOTION', () => 'accelerometer error: $e'),
    );

    _gyroSub = gyroscopeEventStream(samplingPeriod: period).listen(
      (e) {
        final now = DateTime.now();
        heading.onGyroscope(e.x, e.y, e.z, now);
        stepDetector.feedGyro(math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z), now);
      },
      onError: (Object e) {
        _gyroFailed = true;
        PosLog.d('MOTION', () => 'gyroscope unavailable: $e');
      },
    );

    _magSub = magnetometerEventStream(samplingPeriod: period).listen(
      (e) => heading.onMagnetometer(e.x, e.y, e.z, DateTime.now()),
      onError: (Object e) {
        _magFailed = true;
        PosLog.d('MOTION', () => 'magnetometer unavailable: $e');
      },
    );
  }

  void stop() {
    _running = false;
    _accSub?.cancel();
    _gyroSub?.cancel();
    _magSub?.cancel();
    _accSub = _gyroSub = null;
    _magSub = null;
    stepDetector.stop();
  }

  MotionSnapshot snapshot(DateTime now) {
    final st = stepDetector.stateAt(now);
    return MotionSnapshot(
      time: now,
      state: st,
      stepCount: stepDetector.stepCount,
      cadenceHz: stepDetector.cadenceHz,
      stepRegularity: stepDetector.regularity,
      headingRad: heading.headingRad,
      headingConfidence: heading.confidence(now),
      turnRateRadPerSec: heading.yawRate,
      isTurning: heading.isTurning(now),
      shakeSuspected: stepDetector.shakeSuspected(now),
      gyroAvailable: !_gyroFailed && heading.gyroFresh(now),
      magnetometerAvailable: !_magFailed && heading.magFresh(now),
    );
  }

  void dispose() {
    stop();
    stepDetector.dispose();
  }
}
