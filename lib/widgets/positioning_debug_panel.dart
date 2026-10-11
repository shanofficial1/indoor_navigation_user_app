import 'package:flutter/material.dart';

import '../models/positioning_state.dart';
import '../utils/geometry_utils.dart';

/// Optional diagnostics overlay (enable via the bug icon or debug.enabled).
class PositioningDebugPanel extends StatelessWidget {
  const PositioningDebugPanel({super.key, required this.snapshot});

  final PositioningSnapshot? snapshot;

  String _pt(Offset? o) =>
      o == null ? '-' : '(${o.dx.toStringAsFixed(0)}, ${o.dy.toStringAsFixed(0)})';

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
      color: Colors.white,
      fontSize: 11,
      fontFamily: 'monospace',
      height: 1.25,
    );
    final s = snapshot;
    final lines = <String>[];

    if (s == null) {
      lines.add('waiting for first tick...');
    } else {
      final m = s.motion;
      lines
        ..add('STATE ${s.state.name.toUpperCase()}  conf ${s.confidence.toStringAsFixed(2)}')
        ..add('conf  BLE ${s.bleConfidence.toStringAsFixed(2)}  '
            'PDR ${s.pdrConfidence.toStringAsFixed(2)}  '
            'GRAPH ${s.graphConfidence.toStringAsFixed(2)}  '
            'MOTION ${s.motionConfidence.toStringAsFixed(2)}')
        ..add('node ${s.nearestNodeId ?? '-'}  '
            'edge ${s.edgeFromId ?? '-'}->${s.edgeToId ?? '-'}  '
            'along ${s.distanceAlongEdge?.toStringAsFixed(2) ?? '-'}'
            '/${s.edgeLengthMeters?.toStringAsFixed(1) ?? '-'} m')
        ..add('raw BLE ${_pt(s.rawBlePosition)} (${s.bleMethod ?? s.bleRejectReason ?? '-'})')
        ..add('PDR ${_pt(s.pdrPosition)}  final ${_pt(s.position)}'
            '${s.pendingCandidate ? '  [candidate pending]' : ''}')
        ..add('motion ${m?.state.name ?? '-'}  steps ${m?.stepCount ?? 0}  '
            'cadence ${m?.cadenceHz.toStringAsFixed(2) ?? '-'} Hz'
            '${m != null && m.shakeSuspected ? '  SHAKE' : ''}')
        ..add('heading ${m?.headingRad == null ? '-' : '${radToDeg(m!.headingRad!).toStringAsFixed(0)}°'}'
            ' (conf ${m?.headingConfidence.toStringAsFixed(2) ?? '-'})'
            '  gyro ${m?.gyroAvailable == true ? 'ok' : 'no'}'
            '  mag ${m?.magnetometerAvailable == true ? 'ok' : 'no'}')
        ..add('beacons seen: ${s.beacons.length}');
      for (final b in s.beacons) {
        lines.add('${b.used ? '*' : ' '}${b.beaconId} ${b.mac} '
            'raw ${b.rawRssi} flt ${b.filteredRssi.toStringAsFixed(1)} '
            '${b.distance.toStringAsFixed(1)}m q${b.quality.toStringAsFixed(2)}');
      }
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Text(lines.join('\n'), style: style),
      ),
    );
  }
}
