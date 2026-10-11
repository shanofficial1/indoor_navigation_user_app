import 'dart:math' as math;
import 'dart:ui';

const double kTwoPi = 2 * math.pi;

/// Wraps an angle into (-pi, pi].
double wrapAngle(double a) {
  var r = a % kTwoPi; // Dart's % is non-negative for a positive divisor.
  if (r > math.pi) r -= kTwoPi;
  return r;
}

/// Smallest signed difference a - b, in (-pi, pi].
double angleDiff(double a, double b) => wrapAngle(a - b);

double degToRad(double d) => d * math.pi / 180.0;
double radToDeg(double r) => r * 180.0 / math.pi;

/// Bearing of a map-space vector. 0 = "up" on the map image, clockwise
/// positive (so +x on the image is pi/2). Image y grows downward, hence -dy.
double mapBearing(Offset v) => math.atan2(v.dx, -v.dy);

double clamp01(double v) => v < 0 ? 0.0 : (v > 1 ? 1.0 : v);

double polylineLength(List<Offset> p) {
  var total = 0.0;
  for (var i = 1; i < p.length; i++) {
    total += (p[i] - p[i - 1]).distance;
  }
  return total;
}

/// cum[i] = length of the polyline from point 0 to point i.
List<double> cumulativeLengths(List<Offset> p) {
  final cum = <double>[0.0];
  for (var i = 1; i < p.length; i++) {
    cum.add(cum.last + (p[i] - p[i - 1]).distance);
  }
  return cum;
}

int _segmentIndexAt(List<double> cum, double d) {
  // Returns i such that segment (i-1 -> i) contains distance d. i in [1, n-1].
  var i = 1;
  while (i < cum.length - 1 && cum[i] < d) {
    i++;
  }
  return i;
}

/// Point at arc-length [d] along the polyline (clamped to its ends).
Offset pointAtLength(List<Offset> p, List<double> cum, double d) {
  if (p.isEmpty) return Offset.zero;
  if (p.length == 1 || d <= 0) return p.first;
  if (d >= cum.last) return p.last;
  final i = _segmentIndexAt(cum, d);
  final seg = cum[i] - cum[i - 1];
  final t = seg <= 0 ? 0.0 : (d - cum[i - 1]) / seg;
  return Offset(
    p[i - 1].dx + (p[i].dx - p[i - 1].dx) * t,
    p[i - 1].dy + (p[i].dy - p[i - 1].dy) * t,
  );
}

/// Direction vector (not normalised) of the polyline segment at arc-length [d].
Offset tangentAtLength(List<Offset> p, List<double> cum, double d) {
  if (p.length < 2) return const Offset(0, -1);
  final i = _segmentIndexAt(cum, d.clamp(0.0, cum.last));
  return p[i] - p[i - 1];
}

class PolylineProjection {
  const PolylineProjection(this.distance, this.point, this.offset);

  /// Arc-length (px) of the projected point from the start of the polyline.
  final double distance;

  /// Projected point.
  final Offset point;

  /// Euclidean distance (px) from the query point to the projected point.
  final double offset;
}

/// Orthogonal projection of [q] onto the polyline (nearest point on it).
PolylineProjection projectOntoPolyline(
  Offset q,
  List<Offset> p,
  List<double> cum,
) {
  if (p.length < 2) {
    final pt = p.isEmpty ? Offset.zero : p.first;
    return PolylineProjection(0, pt, (q - pt).distance);
  }
  double bestOffset = double.infinity;
  double bestDist = 0;
  Offset bestPoint = p.first;
  for (var i = 1; i < p.length; i++) {
    final a = p[i - 1];
    final b = p[i];
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len2 = dx * dx + dy * dy;
    var t = len2 <= 0 ? 0.0 : ((q.dx - a.dx) * dx + (q.dy - a.dy) * dy) / len2;
    t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
    final proj = Offset(a.dx + dx * t, a.dy + dy * t);
    final off = (q - proj).distance;
    if (off < bestOffset) {
      bestOffset = off;
      bestPoint = proj;
      bestDist = cum[i - 1] + (cum[i] - cum[i - 1]) * t;
    }
  }
  return PolylineProjection(bestDist, bestPoint, bestOffset);
}
