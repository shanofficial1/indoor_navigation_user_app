import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/building_config.dart';
import '../utils/geometry_utils.dart';
import '../utils/smoothing_utils.dart';
import 'positioning_controller.dart';

/// Where the user is facing, ready to draw as a Google-Maps-style beam.
///
/// Reuses the existing heading estimator (gyro + gravity + magnetometer
/// complementary filter) - no new sensor subscriptions. This controller only
///   * converts the compass heading to a MAP bearing using the building's
///     orientation (`mapBearing = compassHeading + offset`),
///   * smooths it (wrap-safe, so 359 deg -> 0 deg never swings the long way),
///   * fades the beam out when the compass is not trustworthy.
///
/// It is a Listenable used as the painter's `repaint` source, so beam updates
/// repaint only the map overlay and never rebuild the page.
class DirectionBeamController extends ChangeNotifier {
  DirectionBeamController({
    required this.config,
    required this.positioning,
  });

  final BuildingConfig config;
  final PositioningController positioning;

  // ---- tuning ---------------------------------------------------------------
  static const int _tickMs = 33; // ~30 Hz
  static const double _smoothingTauSec = 0.12; // rotation low-pass
  static const double _fadeSec = 0.3;
  static const double _notifyDeadbandRad = 0.007; // ~0.4 deg
  static const double _baseSpreadRad = 0.80; // ~46 deg cone when confident
  static const double _extraSpreadRad = 0.60; // wider when less sure
  static const double _unverifiedOpacity = 0.45;

  Timer? _timer;
  DateTime? _last;
  double? _bearing; // smoothed map bearing, wrapped to (-pi, pi]
  double _opacity = 0.0;
  double _spread = _baseSpreadRad;
  double _lastNotifiedBearing = 0.0;
  double _lastNotifiedOpacity = 0.0;

  /// Smoothed bearing in the map frame: 0 = map "up", clockwise positive.
  double get bearingRad => _bearing ?? 0.0;

  /// 0..1, includes fade in/out.
  double get opacity => _opacity;

  /// Full opening angle of the cone (radians).
  double get spreadRad => _spread;

  bool get visible => _bearing != null && _opacity > 0.01;

  void start() {
    _timer ??= Timer.periodic(
      const Duration(milliseconds: _tickMs),
      (_) => tick(DateTime.now()),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _last = null;
  }

  /// One update step; public so it can be driven deterministically in tests.
  void tick(DateTime now) {
    final dt = _last == null
        ? _tickMs / 1000.0
        : (now.difference(_last!).inMicroseconds / 1e6).clamp(0.005, 0.25).toDouble();
    _last = now;

    final heading = positioning.motion.heading;
    final hCfg = config.positioning.motion.heading;

    final compass = heading.headingRad;
    final confidence = heading.confidence(now);
    final compassOk = compass != null && confidence >= hCfg.minimumConfidence;

    // Map orientation: configured value, else the one learned while walking,
    // else assume "map up = north" and show the beam dimmed (unverified).
    final configured = hCfg.mapNorthOffsetDegrees;
    final double? learned = positioning.service.fusion.mapHeadingOffsetRad;
    final double? offset =
        configured != null ? degToRad(configured) : learned;
    final verified = offset != null;

    double targetOpacity = 0.0;
    if (compassOk) {
      final target = wrapAngle(compass + (offset ?? 0.0));
      final b = _bearing;
      if (b == null) {
        _bearing = target;
      } else {
        // angleDiff takes the SHORT way round, so 359 -> 0 is a +1 deg move.
        _bearing = wrapAngle(
          b + timeGain(dt, _smoothingTauSec) * angleDiff(target, b),
        );
      }
      final uncertainty = 1.0 - clamp01(confidence);
      _spread = _baseSpreadRad + _extraSpreadRad * uncertainty +
          (verified ? 0.0 : 0.25);
      targetOpacity = (verified ? 1.0 : _unverifiedOpacity) *
          clamp01(0.4 + confidence);
    }

    // Ease opacity towards its target (fade in / out instead of popping).
    final step = dt / _fadeSec;
    if (_opacity < targetOpacity) {
      _opacity = math.min(targetOpacity, _opacity + step);
    } else {
      _opacity = math.max(targetOpacity, _opacity - step);
    }

    final moved = _bearing == null
        ? false
        : angleDiff(_bearing!, _lastNotifiedBearing).abs() > _notifyDeadbandRad;
    if (moved || (_opacity - _lastNotifiedOpacity).abs() > 0.01) {
      _lastNotifiedBearing = _bearing ?? 0.0;
      _lastNotifiedOpacity = _opacity;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
