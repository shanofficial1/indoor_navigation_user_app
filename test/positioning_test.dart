// Pure-logic tests for the positioning engine. Run with:  flutter test
//
// Map scale used below: mapWidth 3000 px / 40.5 m  => 74.07 px per metre.
// The test graph is:  N1 --(8 m, horizontal)-- N2 --(6 m, vertical)-- N3
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:indoor_nav_user/models/beacon_measurement.dart';
import 'package:indoor_nav_user/models/building_config.dart';
import 'package:indoor_nav_user/models/graph_location.dart';
import 'package:indoor_nav_user/models/motion_state.dart';
import 'package:indoor_nav_user/models/positioning_config.dart';
import 'package:indoor_nav_user/services/ble_position_estimator.dart';
import 'package:indoor_nav_user/services/graph_position_service.dart';
import 'package:indoor_nav_user/services/position_fusion_service.dart';
import 'package:indoor_nav_user/services/rssi_filter_service.dart';
import 'package:indoor_nav_user/services/step_detector_service.dart';
import 'package:indoor_nav_user/services/distance_estimator.dart';

const double ppm = 3000.0 / 40.5;

Map<String, dynamic> _json() => {
      'version': 1,
      'building': {'id': 'B', 'name': 'Test', 'floor': 1},
      'map': {'image': 'x.png', 'width': 3000, 'height': 3000, 'lengthMeters': 40.5},
      'nodes': [
        {'id': 'N1', 'x': 0, 'y': 0, 'rooms': []},
        {'id': 'N2', 'x': 8 * ppm, 'y': 0, 'rooms': []},
        {'id': 'N3', 'x': 8 * ppm, 'y': 6 * ppm, 'rooms': []},
      ],
      'edges': [
        {'from': 'N1', 'to': 'N2', 'distanceMeters': 8.0},
        {'from': 'N2', 'to': 'N3', 'distanceMeters': 6.0},
      ],
      'rooms': [],
      'beacons': [
        {'id': 'B1', 'mac': 'AA:BB:CC:DD:EE:01', 'nodeId': 'N1', 'range': 5},
        {'id': 'B2', 'mac': 'aa-bb-cc-dd-ee-02', 'nodeId': 'N2', 'range': 5},
        {'id': 'B3', 'mac': 'AA:BB:CC:DD:EE:03', 'nodeId': 'N3', 'range': 5},
      ],
    };

BeaconMeasurement _m(String id, double dist, DateTime t) => BeaconMeasurement(
      beaconId: id,
      macAddress: id,
      nodeId: null,
      rawRssi: -65,
      filteredRssi: -65,
      estimatedDistance: dist,
      rssiStdDev: 1.0,
      sampleCount: 5,
      timestamp: t,
      quality: 0.9,
    );

void main() {
  final t0 = DateTime(2026, 1, 1, 12);

  group('config compatibility', () {
    test('old JSON (no positioning sections) loads with defaults', () {
      final c = BuildingConfig.fromJson(_json());
      expect(c.positioning.params.minimumBeacons, 2);
      expect(c.positioning.rssiFilter.windowSize, 5);
      expect(c.beaconByMac.containsKey('AA:BB:CC:DD:EE:02'), isTrue); // normalised
    });

    test('partial/garbage sections fall back safely', () {
      final j = _json()..['positioning'] = {'minimumBeacons': 'x', 'maximumBeacons': 4};
      final c = BuildingConfig.fromJson(j);
      expect(c.positioning.params.minimumBeacons, 2);
      expect(c.positioning.params.maximumBeacons, 4);
    });
  });

  group('RSSI + distance', () {
    test('TEST 4: spike -60 -> -85 -> -59 is rejected', () {
      var now = t0;
      final f = RssiFilterService(clock: () => now, enableCleanupTimer: false);
      for (var i = 0; i < 6; i++) {
        now = now.add(const Duration(milliseconds: 100));
        f.addSample('B1', -60);
      }
      final before = f.addSample('B1', -60);
      final during = f.addSample('B1', -85);
      final after = f.addSample('B1', -59);
      expect((during - before).abs(), lessThan(1.0));
      expect((after - before).abs(), lessThan(1.5));
    });

    test('sustained RSSI change is accepted (user really moved)', () {
      final f = RssiFilterService(clock: () => t0, enableCleanupTimer: false);
      for (var i = 0; i < 6; i++) {
        f.addSample('B1', -60);
      }
      double v = 0;
      for (var i = 0; i < 12; i++) {
        v = f.addSample('B1', -80);
      }
      expect(v, lessThan(-75));
    });

    test('distance model', () {
      final d = DistanceEstimator(const DistanceModelConfig());
      expect(d.estimate(-59.0), closeTo(1.0, 0.01));
      expect(d.estimate(-79.0), closeTo(10.0, 0.05));
    });
  });

  group('graph + BLE position', () {
    late BuildingConfig cfg;
    late GraphPositionService g;
    late BlePositionEstimator est;
    setUp(() {
      cfg = BuildingConfig.fromJson(_json());
      g = GraphPositionService(cfg);
      est = BlePositionEstimator(graph: g, config: cfg);
    });

    test('TEST 5: 8 m apart, 4 m / 4 m -> midpoint', () {
      final fix = est.estimate([_m('B1', 4, t0), _m('B2', 4, t0)], t0)!;
      expect(fix.method, 'ratio');
      expect(fix.location.edge, 0);
      expect(fix.location.distance, closeTo(4.0, 0.05));
    });

    test('TEST 6: 2 m / 6 m -> 25 % from A', () {
      final fix = est.estimate([_m('B1', 2, t0), _m('B2', 6, t0)], t0)!;
      expect(fix.location.distance / 8.0, closeTo(0.25, 0.01));
    });

    test('TEST 7: curved edge uses polyline length, not straight line', () {
      final j = _json();
      // Edge N1->N2 now bends: (0,0) -> (300,0) -> (300,300) px, declared 8 m.
      (j['nodes'] as List)[1] = {'id': 'N2', 'x': 300, 'y': 300, 'rooms': []};
      (j['nodes'] as List)[2] = {'id': 'N3', 'x': 300, 'y': 700, 'rooms': []};
      (j['edges'] as List)[0] = {
        'from': 'N1',
        'to': 'N2',
        'distanceMeters': 8.0,
        'polyline': [
          {'x': 0, 'y': 0},
          {'x': 300, 'y': 0},
          {'x': 300, 'y': 300},
        ],
      };
      final c = BuildingConfig.fromJson(j);
      final gg = GraphPositionService(c);
      expect(gg.edges[0].lengthMeters, 8.0); // path distance, not Euclidean (~5.7 m)
      final p = gg.pointOf(const GraphLocation(0, 4.0)); // half-way along polyline
      expect(p.dx, closeTo(300, 0.5));
      expect(p.dy, closeTo(0, 0.5));
    });

    test('TEST 8: turn N1->N2->N3 continues onto the next edge', () {
      final r = g.moveAlong(const GraphLocation(0, 7.0), 2.0, 1);
      expect(r.location.edge, 1);
      expect(r.location.distance, closeTo(1.0, 1e-6));
      expect(r.turnAngleRad.abs(), greaterThan(1.0)); // ~90 degree turn
    });

    test('unknown beacons never produce a fix; stale input yields none', () {
      expect(est.estimate([_m('ZZ', 2, t0)], t0), isNull);
      expect(est.estimate(const [], t0), isNull);
    });
  });

  group('fusion', () {
    late BuildingConfig cfg;
    late GraphPositionService g;
    late PositionFusionService fusion;
    final walk = MotionSnapshot(time: t0, state: MotionState.stationary);

    BleFix fixAt(double d, DateTime t) => BleFix(
          location: GraphLocation(0, d),
          confidence: 0.7,
          usedBeaconIds: const ['B1', 'B2'],
          residualRms: 0.3,
          ambiguityMeters: 0.5,
          method: 'ratio',
          time: t,
        );

    FusionOutput tick(DateTime t, BleFix? f, {double steps = 0}) => fusion.update(
          now: t,
          fix: f,
          motion: walk,
          stepDistanceMeters: steps,
          routeNext: const {},
        );

    setUp(() {
      cfg = BuildingConfig.fromJson(_json());
      g = GraphPositionService(cfg);
      fusion = PositionFusionService(graph: g, config: cfg);
    });

    DateTime initialise() {
      var t = t0;
      for (var i = 0; i < 12; i++) {
        t = t.add(const Duration(milliseconds: 200));
        tick(t, fixAt(2.0, t));
      }
      return t;
    }

    test('first position needs temporal confirmation, then is accepted', () {
      var t = t0;
      final o1 = tick(t, fixAt(2.0, t));
      expect(o1.location, isNull);
      t = initialise();
      expect(fusion.location, isNotNull);
      expect(fusion.location!.distance, closeTo(2.0, 0.01));
    });

    test('TEST 4b: brief BLE jump is ignored (no teleport)', () {
      var t = initialise();
      for (var i = 0; i < 3; i++) {
        t = t.add(const Duration(milliseconds: 200));
        tick(t, fixAt(7.0, t)); // 0.6 s of a wild reading
      }
      for (var i = 0; i < 5; i++) {
        t = t.add(const Duration(milliseconds: 200));
        tick(t, fixAt(2.1, t));
      }
      expect(fusion.location!.distance, closeTo(2.0, 0.3));
    });

    test('sustained far candidate is accepted only gradually', () {
      var t = initialise();
      var maxStep = 0.0;
      var prev = fusion.location!.distance;
      for (var i = 0; i < 40; i++) {
        t = t.add(const Duration(milliseconds: 200));
        tick(t, fixAt(7.0, t));
        final d = fusion.location!.distance;
        if ((d - prev).abs() > maxStep) maxStep = (d - prev).abs();
        prev = d;
      }
      expect(maxStep, lessThan(0.35)); // never a jump
      expect(fusion.location!.distance, greaterThan(2.5)); // but it moves
    });

    test('TEST 9: BLE loss -> PDR keeps the position moving', () {
      var t = initialise();
      final start = fusion.location!.distance;
      for (var i = 0; i < 10; i++) {
        t = t.add(const Duration(milliseconds: 200));
        fusion.update(
          now: t,
          fix: null,
          motion: MotionSnapshot(
            time: t,
            state: MotionState.walking,
            cadenceHz: 1.8,
            stepRegularity: 0.9,
          ),
          stepDistanceMeters: 0.2,
          routeNext: const {'N1': 'N2'},
        );
      }
      expect(fusion.location!.distance, greaterThan(start + 1.5));
    });
  });

  group('step detector', () {
    DateTime clock = DateTime(2026, 1, 1, 12);
    void feed(StepDetectorService s, double Function(double t) x, double seconds,
        {double hz = 50}) {
      final n = (seconds * hz).round();
      for (var i = 0; i < n; i++) {
        clock = clock.add(Duration(microseconds: (1e6 / hz).round()));
        s.processSample(x(i / hz), 0.0, 0.0, clock);
      }
    }

    test('TEST 1: standing still counts nothing', () {
      final s = StepDetectorService();
      feed(s, (t) => 0.05 * (t % 0.3), 8);
      expect(s.stepCount, 0);
    });

    test('TEST 2: regular 2 Hz walking is counted', () {
      final s = StepDetectorService();
      // One 4 m/s^2 pulse every 500 ms.
      feed(s, (t) {
        final ph = (t % 0.5) - 0.1;
        return 4.0 * _gauss(ph, 0.04);
      }, 8);
      expect(s.stepCount, greaterThanOrEqualTo(10));
      expect(s.stepCount, lessThanOrEqualTo(17));
    });

    test('TEST 3: violent irregular shaking counts (almost) nothing', () {
      final s = StepDetectorService();
      var seed = 7;
      double rnd() {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return (seed % 2000) / 1000.0 - 1.0;
      }
      feed(s, (t) => 18.0 * rnd(), 6);
      expect(s.stepCount, lessThanOrEqualTo(1));
    });
  });
}

double _gauss(double x, double sigma) => math.exp(-(x * x) / (2 * sigma * sigma));
