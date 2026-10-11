import 'dart:ui';

import 'graph_location.dart';
import 'motion_state.dart';

enum PositioningState {
  initializing,
  searching,
  positioned,
  moving,
  stationary,
  turning,
  lowConfidence,
  lost,
  recovering,
}

/// Per-beacon diagnostics for the debug panel.
class BeaconDiagnostic {
  const BeaconDiagnostic({
    required this.beaconId,
    required this.mac,
    required this.rawRssi,
    required this.filteredRssi,
    required this.distance,
    required this.quality,
    required this.ageMs,
    required this.used,
  });

  final String beaconId;
  final String mac;
  final int rawRssi;
  final double filteredRssi;
  final double distance;
  final double quality;
  final double ageMs;

  /// true if this beacon contributed to the current BLE fix.
  final bool used;
}

/// Immutable result of one fusion tick - what the UI renders.
class PositioningSnapshot {
  const PositioningSnapshot({
    required this.time,
    required this.state,
    this.location,
    this.position,
    this.nearestNodeId,
    this.edgeFromId,
    this.edgeToId,
    this.edgeLengthMeters,
    this.confidence = 0.0,
    this.bleConfidence = 0.0,
    this.pdrConfidence = 0.0,
    this.graphConfidence = 0.0,
    this.motionConfidence = 0.0,
    this.rawBlePosition,
    this.pdrPosition,
    this.motion,
    this.beacons = const [],
    this.bleMethod,
    this.bleRejectReason,
    this.pendingCandidate = false,
    this.bestBeaconId,
  });

  final DateTime time;
  final PositioningState state;

  /// Final, graph-constrained, smoothed position ON the graph.
  final GraphLocation? location;

  /// Same position in map pixels (what the marker draws).
  final Offset? position;
  final String? nearestNodeId;
  final String? edgeFromId;
  final String? edgeToId;
  final double? edgeLengthMeters;

  final double confidence;
  final double bleConfidence;
  final double pdrConfidence;
  final double graphConfidence;
  final double motionConfidence;

  /// Diagnostics: raw BLE fix, and dead-reckoned (pre-BLE-correction) position.
  final Offset? rawBlePosition;
  final Offset? pdrPosition;
  final MotionSnapshot? motion;
  final List<BeaconDiagnostic> beacons;
  final String? bleMethod;
  final String? bleRejectReason;

  /// A suspicious BLE candidate is waiting for temporal confirmation.
  final bool pendingCandidate;
  final String? bestBeaconId;

  double? get distanceAlongEdge => location?.distance;
}
