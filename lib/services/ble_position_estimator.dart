import 'dart:math' as math;

import '../models/beacon_measurement.dart';
import '../models/building_config.dart';
import '../models/graph_location.dart';
import '../models/positioning_config.dart';
import '../utils/geometry_utils.dart';
import '../utils/pos_log.dart';
import '../utils/smoothing_utils.dart';
import 'graph_position_service.dart';

/// A BLE-derived position candidate, already ON the graph.
class BleFix {
  const BleFix({
    required this.location,
    required this.confidence,
    required this.usedBeaconIds,
    required this.residualRms,
    required this.ambiguityMeters,
    required this.method,
    required this.time,
  });

  final GraphLocation location;

  /// 0..1
  final double confidence;
  final List<String> usedBeaconIds;

  /// RMS disagreement (m) between beacon ranges and the chosen point.
  final double residualRms;

  /// Spread (m) of equally-good candidates: large = ambiguous.
  final double ambiguityMeters;

  /// 'ratio' | 'least-squares' | 'proximity'
  final String method;
  final DateTime time;
}

class _Scored {
  _Scored(this.m, this.anchor, this.score);
  final BeaconMeasurement m;
  final GraphLocation anchor;
  final double score;
}

/// Turns the set of current beacon ranges into ONE position on the graph.
///
///  1. rank beacons (strength, stability, freshness, agreement with the
///     current position) and keep the best few - never "just the strongest";
///  2. exactly two beacons whose ranges bracket the user:
///       position = path-distance ratio  dA / (dA + dB)  along the graph path
///       between the two beacons (curved paths measured along the polyline);
///  3. otherwise: weighted least squares over the graph - the point whose
///     along-graph distances best match all ranges;
///  4. a candidate whose ranges are mutually inconsistent is rejected.
class BlePositionEstimator {
  BlePositionEstimator({required this.graph, required this.config}) {
    for (final b in config.beacons) {
      if (!b.enabled) continue;
      final a = graph.anchorForBeacon(b);
      if (a != null) {
        _anchors[b.id] = a;
      } else {
        PosLog.d('BLE', () => 'beacon ${b.id} has no graph anchor - unusable');
      }
    }
  }

  final GraphPositionService graph;
  final BuildingConfig config;
  final Map<String, GraphLocation> _anchors = {};

  /// Why the last call returned null (diagnostics).
  String? lastRejectReason;

  PositioningParams get _p => config.positioning.params;

  GraphLocation? anchorOf(String beaconId) => _anchors[beaconId];

  // --------------------------------------------------------------------------
  // beacon selection
  // --------------------------------------------------------------------------

  List<_Scored> _select(
    List<BeaconMeasurement> all,
    DateTime now,
    GraphLocation? prior,
  ) {
    final timeoutMs = config.positioning.ble.measurementTimeoutMs;
    final scored = <_Scored>[];

    for (final m in all) {
      final anchor = _anchors[m.beaconId];
      if (anchor == null) continue;
      if (m.estimatedDistance > _p.maxUsableDistanceMeters) continue;

      final strength = clamp01((m.filteredRssi + 100.0) / 50.0);
      final stability = expDecay(m.rssiStdDev, _p.rssiStabilityScaleDb);
      final freshness = clamp01(1.0 - m.ageMs(now) / timeoutMs);
      final consistency = prior == null
          ? 0.5
          : expDecay(
              (graph.graphDistance(prior, anchor) - m.estimatedDistance).abs(),
              _p.consistencyScaleMeters,
            );

      final score = _p.selectionRssiWeight * strength +
          _p.selectionStabilityWeight * stability +
          _p.selectionFreshnessWeight * freshness +
          _p.selectionConsistencyWeight * consistency;
      scored.add(_Scored(m, anchor, score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    if (scored.length > _p.maximumBeacons) {
      return scored.sublist(0, _p.maximumBeacons);
    }
    return scored;
  }

  // --------------------------------------------------------------------------
  // estimate
  // --------------------------------------------------------------------------

  BleFix? estimate(
    List<BeaconMeasurement> measurements,
    DateTime now, {
    GraphLocation? prior,
  }) {
    lastRejectReason = null;
    if (graph.isEmpty) {
      lastRejectReason = 'empty graph';
      return null;
    }

    final sel = _select(measurements, now, prior);
    if (sel.isEmpty) {
      lastRejectReason = 'no usable beacons';
      return null;
    }

    if (sel.length < _p.minimumBeacons) {
      return _proximityFix(sel, now);
    }

    if (sel.length == 2) {
      final r = _ratioFix(sel[0], sel[1], now);
      if (r != null) return r;
    }

    return _leastSquares(sel, prior, now);
  }

  /// One beacon only: if the user is very close to it, "near beacon X" is still
  /// a useful (but low-confidence) statement. Otherwise the ranges are too
  /// ambiguous to give a position.
  BleFix? _proximityFix(List<_Scored> sel, DateTime now) {
    _Scored nearest = sel.first;
    for (final s in sel) {
      if (s.m.estimatedDistance < nearest.m.estimatedDistance) nearest = s;
    }
    if (nearest.m.estimatedDistance > _p.singleBeaconProximityMeters) {
      lastRejectReason = 'insufficient beacons (${sel.length})';
      return null;
    }
    return BleFix(
      location: nearest.anchor,
      confidence: clamp01(_p.bleConfidence * 0.5 * (0.5 + 0.5 * nearest.m.quality)),
      usedBeaconIds: [nearest.m.beaconId],
      residualRms: 0.0,
      ambiguityMeters: nearest.m.estimatedDistance,
      method: 'proximity',
      time: now,
    );
  }

  /// Two-beacon relative positioning along the beacon-to-beacon path:
  ///   t = L * dA / (dA + dB)
  /// e.g. 8 m path, ranges 2 m / 6 m  ->  t = 2 m (25 % from A).
  /// Uses the along-graph (polyline) length L, never the straight line.
  BleFix? _ratioFix(_Scored a, _Scored b, DateTime now) {
    final path = graph.pathBetween(a.anchor, b.anchor);
    if (path == null) return null;
    final length = path.length;
    if (length < 0.5) return null;

    final dA = a.m.estimatedDistance;
    final dB = b.m.estimatedDistance;
    final sum = dA + dB;
    // Only valid when the user is plausibly BETWEEN the two beacons.
    if ((sum - length).abs() > _p.ratioConsistencyTolerance * length) {
      return null;
    }

    final t = (length * dA / sum).clamp(0.0, length).toDouble();
    final loc = graph.advanceAlongPath(path, t);
    final rms = math.sqrt((math.pow(t - dA, 2) + math.pow((length - t) - dB, 2)) / 2.0);
    if (rms > _p.maxResidualMeters) return null;

    return BleFix(
      location: loc,
      confidence: _confidence([a, b], rms, 0.0),
      usedBeaconIds: [a.m.beaconId, b.m.beaconId],
      residualRms: rms,
      ambiguityMeters: 0.0,
      method: 'ratio',
      time: now,
    );
  }

  /// Weighted least squares over the graph. Range error grows with distance,
  /// so each residual is normalised by sigma = 0.3 d + 0.5 m and weighted by
  /// beacon quality. A weak pull towards the current position resolves
  /// left/right ambiguity.
  BleFix? _leastSquares(List<_Scored> sel, GraphLocation? prior, DateTime now) {
    final samples = graph.samples(_p.sampleStepMeters);
    if (samples.isEmpty) return null;

    final n = samples.length;
    final costs = List<double>.filled(n, 0.0);
    var bestIdx = 0;
    var bestCost = double.infinity;

    for (var i = 0; i < n; i++) {
      final s = samples[i];
      var cost = 0.0;
      for (final b in sel) {
        final d = b.m.estimatedDistance;
        final sigma = 0.3 * d + 0.5;
        final g = graph.graphDistance(s, b.anchor);
        final r = (g - d) / sigma;
        cost += b.m.quality * r * r;
      }
      if (prior != null) {
        final dp = graph.graphDistance(s, prior);
        cost += _p.priorWeight * dp * dp;
      }
      costs[i] = cost;
      if (cost < bestCost) {
        bestCost = cost;
        bestIdx = i;
      }
    }

    final best = samples[bestIdx];

    // RMS range residual at the chosen point.
    var sq = 0.0;
    for (final b in sel) {
      final g = graph.graphDistance(best, b.anchor);
      sq += math.pow(g - b.m.estimatedDistance, 2).toDouble();
    }
    final rms = math.sqrt(sq / sel.length);
    if (sel.length >= 2 && rms > _p.maxResidualMeters) {
      lastRejectReason = 'inconsistent ranges (rms ${rms.toStringAsFixed(1)} m)';
      return null;
    }

    // Ambiguity: how far apart are the near-optimal candidates?
    var spread = 0.0;
    for (var i = 0; i < n; i++) {
      if (costs[i] <= bestCost + _p.ambiguityCostMargin) {
        final d = graph.graphDistance(samples[i], best);
        if (d > spread) spread = d;
      }
    }

    return BleFix(
      location: best,
      confidence: _confidence(sel, rms, spread),
      usedBeaconIds: sel.map((s) => s.m.beaconId).toList(),
      residualRms: rms,
      ambiguityMeters: spread,
      method: 'least-squares',
      time: now,
    );
  }

  /// Confidence 0..1 from beacon count, range consistency, ambiguity, quality.
  double _confidence(List<_Scored> used, double rms, double ambiguity) {
    final count = used.length;
    final pref = _p.preferredBeacons;
    final countF = count >= pref
        ? 1.0
        : 0.55 + 0.45 * (count - 1) / math.max(1, pref - 1);
    final residF = expDecay(rms, _p.maxResidualMeters / 2.0);
    final ambF = 1.0 / (1.0 + ambiguity / _p.ambiguityScaleMeters);
    final qual = mean(used.map((u) => u.m.quality).toList());
    final c = 0.4 * countF + 0.3 * residF + 0.3 * ambF;
    return clamp01(_p.bleConfidence * c * (0.6 + 0.4 * qual));
  }
}
