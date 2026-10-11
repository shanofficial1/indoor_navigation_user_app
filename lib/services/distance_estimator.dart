import 'dart:math' as math;

import '../models/navigation_beacon.dart';
import '../models/positioning_config.dart';

/// Log-distance path-loss model:
///
///   d = d0 * 10 ^ ((txPower - rssi) / (10 * n))
///
/// txPower = RSSI at the reference distance d0, n = path-loss exponent.
/// A beacon may override txPower / n with its own calibration.
class DistanceEstimator {
  DistanceEstimator(this.model);

  final DistanceModelConfig model;

  double estimate(
    double filteredRssi, {
    double? txPower,
    double? pathLossExponent,
  }) {
    final tx = txPower ?? model.defaultTxPower;
    final n = pathLossExponent ?? model.pathLossExponent;
    final d = model.referenceDistanceMeters *
        math.pow(10.0, (tx - filteredRssi) / (10.0 * n));
    if (d.isNaN) return model.maxDistanceMeters;
    return d.clamp(model.minDistanceMeters, model.maxDistanceMeters).toDouble();
  }

  double estimateForBeacon(NavigationBeacon beacon, double filteredRssi) =>
      estimate(
        filteredRssi,
        txPower: beacon.txPower,
        pathLossExponent: beacon.pathLossExponent,
      );
}
