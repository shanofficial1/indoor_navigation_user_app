// Tests for the facing-direction beam. Run with:  flutter test
//
// A flat phone (screen up, top edge = forward) is simulated: gravity along +z
// and a magnetic field whose horizontal part points to compass north. For a
// phone facing compass heading h, north in device coordinates is
// (-sin h, cos h), so  mag = (-25 sin h, 25 cos h, -35) uT.
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav_user/controllers/direction_beam_controller.dart';
import 'package:indoor_nav_user/controllers/positioning_controller.dart';
import 'package:indoor_nav_user/models/building_config.dart';
import 'package:indoor_nav_user/utils/geometry_utils.dart';

Map<String, dynamic> _json({Map<String, dynamic>? extra, Map<String, dynamic>? map}) {
  final j = <String, dynamic>{
    'version': 1,
    'building': {'id': 'B', 'name': 'Test', 'floor': 1},
    'map': {
      'image': 'x.png',
      'width': 3000,
      'height': 3000,
      'lengthMeters': 40.5,
      ...?map,
    },
    'nodes': [
      {'id': 'N1', 'x': 0, 'y': 0, 'rooms': []},
      {'id': 'N2', 'x': 592, 'y': 0, 'rooms': []},
    ],
    'edges': [
      {'from': 'N1', 'to': 'N2', 'distanceMeters': 8.0},
    ],
    'rooms': [],
    'beacons': [
      {'id': 'B1', 'mac': 'AA:BB:CC:DD:EE:01', 'nodeId': 'N1', 'range': 5},
    ],
  };
  if (extra != null) j.addAll(extra);
  return j;
}

class _Rig {
  _Rig(Map<String, dynamic> json) {
    cfg = BuildingConfig.fromJson(json);
    pos = PositioningController(cfg);
    beam = DirectionBeamController(config: cfg, positioning: pos);
  }

  late final BuildingConfig cfg;
  late final PositioningController pos;
  late final DirectionBeamController beam;
  DateTime t = DateTime(2026, 1, 1, 12);

  /// Phone facing [headingDeg] for [seconds]; ticks the beam every 30 ms.
  /// [onTick] sees the beam after every update.
  void face(double headingDeg, double seconds, {void Function()? onTick}) {
    final h = degToRad(headingDeg);
    final steps = (seconds / 0.03).round();
    for (var i = 0; i < steps; i++) {
      t = t.add(const Duration(milliseconds: 30));
      final heading = pos.motion.heading;
      heading.onAccelerometer(0.0, 0.0, 9.81, t);
      heading.onMagnetometer(-25.0 * math.sin(h), 25.0 * math.cos(h), -35.0, t);
      beam.tick(t);
      onTick?.call();
    }
  }

  void dispose() {
    beam.dispose();
    pos.dispose();
  }
}

void main() {
  test('facing north with map-up = north: beam points up', () {
    final r = _Rig(_json(extra: {
      'motion': {'heading': {'mapNorthOffsetDegrees': 0}},
    }));
    r.face(0, 2.0);
    expect(r.beam.visible, isTrue);
    expect(angleDiff(r.beam.bearingRad, 0.0).abs(), lessThan(0.05));
    r.dispose();
  });

  test('map orientation offset is applied (compass north -> map bearing 90)', () {
    final r = _Rig(_json(extra: {
      'motion': {'heading': {'mapNorthOffsetDegrees': 90}},
    }));
    r.face(0, 2.0);
    expect(angleDiff(r.beam.bearingRad, math.pi / 2).abs(), lessThan(0.05));
    // Turning the phone right by 30 deg turns the beam right by 30 deg.
    r.face(30, 3.0);
    expect(angleDiff(r.beam.bearingRad, degToRad(120)).abs(), lessThan(0.07));
    r.dispose();
  });

  test('map.northOffsetDegrees in the map block is accepted', () {
    final r = _Rig(_json(map: {'northOffsetDegrees': -90}));
    expect(r.cfg.positioning.motion.heading.mapNorthOffsetDegrees, -90);
    r.face(0, 2.0);
    expect(angleDiff(r.beam.bearingRad, -math.pi / 2).abs(), lessThan(0.05));
    r.dispose();
  });

  test('359 -> 0 deg crossing never swings the long way round', () {
    final r = _Rig(_json(extra: {
      'motion': {'heading': {'mapNorthOffsetDegrees': 0}},
    }));
    r.face(358, 3.0);
    var worst = 0.0;
    r.face(2, 3.0, onTick: () {
      worst = math.max(worst, angleDiff(r.beam.bearingRad, 0.0).abs());
    });
    // Always within a few degrees of north - never sweeps through south.
    expect(worst, lessThan(0.1));
    r.dispose();
  });

  test('no compass data -> no beam (graceful)', () {
    final r = _Rig(_json());
    for (var i = 0; i < 40; i++) {
      r.t = r.t.add(const Duration(milliseconds: 30));
      r.beam.tick(r.t);
    }
    expect(r.beam.visible, isFalse);
    r.dispose();
  });

  test('orientation not configured/learned -> beam shown dimmed', () {
    final r = _Rig(_json());
    r.face(0, 2.0);
    expect(r.beam.visible, isTrue);
    expect(r.beam.opacity, lessThan(0.5));
    r.dispose();
  });

  test('beam fades out when the compass becomes stale', () {
    final r = _Rig(_json(extra: {
      'motion': {'heading': {'mapNorthOffsetDegrees': 0}},
    }));
    r.face(0, 2.0);
    expect(r.beam.visible, isTrue);
    // Confidence decays over ~20 s without a valid magnetometer reading.
    for (var i = 0; i < 1200; i++) {
      r.t = r.t.add(const Duration(milliseconds: 30));
      r.beam.tick(r.t);
    }
    expect(r.beam.visible, isFalse);
    r.dispose();
  });
}
