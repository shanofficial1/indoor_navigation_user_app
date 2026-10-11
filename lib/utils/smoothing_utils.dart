import 'dart:math' as math;

import 'geometry_utils.dart';

/// Exponential moving average. value += alpha * (sample - value).
class Ema {
  Ema(this.alpha);

  final double alpha;
  double? _value;

  double? get value => _value;

  double update(double sample) {
    final v = _value;
    _value = v == null ? sample : v + alpha * (sample - v);
    return _value!;
  }

  void reset() => _value = null;
}

/// EMA for angles (radians); always takes the short way round.
class AngleEma {
  AngleEma(this.alpha);

  final double alpha;
  double? _value;

  double? get value => _value;

  double update(double angle) {
    final v = _value;
    _value = v == null ? wrapAngle(angle) : wrapAngle(v + alpha * angleDiff(angle, v));
    return _value!;
  }

  void reset() => _value = null;
}

double mean(List<double> v) {
  if (v.isEmpty) return 0.0;
  var s = 0.0;
  for (final x in v) {
    s += x;
  }
  return s / v.length;
}

double median(List<double> v) {
  if (v.isEmpty) return 0.0;
  final s = List<double>.from(v)..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2.0;
}

double stdDev(List<double> v) {
  if (v.length < 2) return 0.0;
  final m = mean(v);
  var s = 0.0;
  for (final x in v) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / v.length);
}

/// exp(-x / scale): 1 at x = 0, decaying towards 0.
double expDecay(double x, double scale) {
  if (scale <= 0) return 0.0;
  return math.exp(-x / scale);
}

/// First-order low-pass gain for a time step [dtSec] and time constant [tauSec].
double timeGain(double dtSec, double tauSec) {
  if (tauSec <= 0) return 1.0;
  return 1.0 - math.exp(-dtSec / tauSec);
}
