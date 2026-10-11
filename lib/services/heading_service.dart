import 'dart:math' as math;

import '../models/positioning_config.dart';
import '../utils/geometry_utils.dart';
import '../utils/smoothing_utils.dart';

class _V3 {
  const _V3(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;

  double get norm => math.sqrt(x * x + y * y + z * z);
  double dot(_V3 o) => x * o.x + y * o.y + z * o.z;
  _V3 cross(_V3 o) =>
      _V3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x);
  _V3 operator +(_V3 o) => _V3(x + o.x, y + o.y, z + o.z);
  _V3 operator -(_V3 o) => _V3(x - o.x, y - o.y, z - o.z);
  _V3 scale(double s) => _V3(x * s, y * s, z * s);
  _V3 normalized() {
    final n = norm;
    return n < 1e-9 ? const _V3(0, 0, 0) : _V3(x / n, y / n, z / n);
  }
}

/// Heading estimator: gyroscope (smooth, drifts) + accelerometer gravity
/// (tilt) + magnetometer (absolute, noisy indoors) in a complementary filter.
///
/// * Gyro yaw rate is measured about the gravity axis, so it works in any
///   phone orientation.
/// * The magnetometer slowly pulls the heading back (cancels gyro drift) and
///   is ignored when its field strength looks disturbed.
/// * If the gyro is missing the magnetometer drives the heading alone; if the
///   magnetometer is missing the gyro integrates alone (confidence decays).
///
/// heading: radians, 0 = magnetic north, clockwise, of the phone's forward
/// axis (top edge when held flat, camera direction when held upright).
class HeadingService {
  HeadingService(this.config) : _yawRateEma = Ema(0.3);

  final HeadingConfig config;
  final Ema _yawRateEma;

  _V3? _up; // unit "up" in device coordinates (low-passed accelerometer)
  _V3? _mag; // low-passed magnetometer
  double? _heading;
  bool _magValid = false;

  DateTime? _lastAcc;
  DateTime? _lastGyro;
  DateTime? _lastMag;
  DateTime? _lastValidMag;

  static const double _gravityTauSec = 0.3;
  static const double _magTauSec = 0.2;
  static const Duration _freshWindow = Duration(milliseconds: 700);

  double? get headingRad => _heading;
  double get yawRate => _yawRateEma.value ?? 0.0;

  bool gyroFresh(DateTime now) =>
      _lastGyro != null && now.difference(_lastGyro!) < _freshWindow;

  bool magFresh(DateTime now) =>
      _lastValidMag != null && now.difference(_lastValidMag!) < _freshWindow * 3;

  bool isTurning(DateTime now) =>
      gyroFresh(now) &&
      yawRate.abs() > degToRad(config.turnRateThresholdDegPerSec);

  /// 0..1. High when the gyro is live and a valid magnetometer reading was seen
  /// recently; decays when only the gyro is integrating.
  double confidence(DateTime now) {
    if (_heading == null) return 0.0;
    final lastMag = _lastValidMag;
    final magAgeSec =
        lastMag == null ? 1e9 : now.difference(lastMag).inMilliseconds / 1000.0;
    final magPart = 0.8 * expDecay(magAgeSec, 20.0);
    final gyroPart = gyroFresh(now) ? 0.2 : 0.0;
    return clamp01(magPart + gyroPart);
  }

  // --------------------------------------------------------------------------

  void onAccelerometer(double x, double y, double z, DateTime now) {
    final raw = _V3(x, y, z);
    if (raw.norm < 1.0) return; // free fall / invalid
    final unit = raw.normalized();
    final last = _lastAcc;
    _lastAcc = now;
    if (_up == null || last == null) {
      _up = unit;
      return;
    }
    final dt = now.difference(last).inMicroseconds / 1e6;
    final a = timeGain(dt.clamp(0.0, 0.5).toDouble(), _gravityTauSec);
    final u = _up!;
    _up = (u + (unit - u).scale(a)).normalized();
  }

  void onGyroscope(double gx, double gy, double gz, DateTime now) {
    final up = _up;
    final last = _lastGyro;
    _lastGyro = now;
    if (up == null || last == null) return;
    final dt = (now.difference(last).inMicroseconds / 1e6).clamp(0.0, 0.1).toDouble();

    // Rotation rate about the vertical (CCW positive seen from above).
    final w = gx * up.x + gy * up.y + gz * up.z;
    _yawRateEma.update(w);

    final h = _heading;
    if (h != null && dt > 0) {
      // Compass heading grows clockwise, hence the minus sign.
      _heading = wrapAngle(h - w * dt);
    }
  }

  void onMagnetometer(double mx, double my, double mz, DateTime now) {
    final raw = _V3(mx, my, mz);
    final last = _lastMag;
    _lastMag = now;

    if (_mag == null || last == null) {
      _mag = raw;
    } else {
      final dt = (now.difference(last).inMicroseconds / 1e6).clamp(0.0, 0.5).toDouble();
      final a = timeGain(dt, _magTauSec);
      _mag = _mag! + (raw - _mag!).scale(a);
    }

    final field = _mag!.norm;
    _magValid =
        field >= config.minFieldMicroTesla && field <= config.maxFieldMicroTesla;
    final up = _up;
    if (!_magValid || up == null) return;

    final hm = _magneticHeading(up, _mag!);
    if (hm == null) return;
    _lastValidMag = now;

    final h = _heading;
    if (h == null) {
      _heading = hm;
      return;
    }

    final dt = last == null
        ? 0.05
        : (now.difference(last).inMicroseconds / 1e6).clamp(0.0, 0.5).toDouble();
    // Trust the magnetometer much more when there is no live gyro.
    final rate = gyroFresh(now) ? config.magCorrectionPerSecond : 5.0;
    final gain = 1.0 - math.exp(-dt * rate);
    _heading = wrapAngle(h + gain * angleDiff(hm, h));
  }

  /// Tilt-compensated magnetic heading of the phone's forward axis.
  double? _magneticHeading(_V3 up, _V3 mag) {
    final east = mag.cross(up).normalized(); // M x U points east
    if (east.norm < 0.5) return null; // field parallel to up: degenerate
    final north = up.cross(east);

    // Forward axis: top edge when flat, back-camera direction when upright.
    final fwd = up.z.abs() > 0.7 ? const _V3(0, 1, 0) : const _V3(0, 0, -1);
    final horiz = fwd - up.scale(fwd.dot(up));
    if (horiz.norm < 0.1) return null;
    return math.atan2(horiz.dot(east), horiz.dot(north));
  }

  void reset() {
    _heading = null;
    _up = null;
    _mag = null;
    _lastAcc = _lastGyro = _lastMag = _lastValidMag = null;
    _yawRateEma.reset();
  }
}
