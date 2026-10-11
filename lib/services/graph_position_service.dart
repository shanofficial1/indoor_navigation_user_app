import 'dart:math' as math;
import 'dart:ui';

import '../models/building_config.dart';
import '../models/graph_location.dart';
import '../models/navigation_beacon.dart';
import '../utils/geometry_utils.dart';
import '../utils/pos_log.dart';

/// One walkable corridor segment between two nodes.
///
/// Geometry is a polyline in map pixels; the walking length is in METRES
/// (the configured `distanceMeters`, else derived from the polyline and map
/// scale). Positions along the edge are metres measured along the polyline,
/// NOT straight-line displacement.
class GraphEdge {
  GraphEdge({
    required this.index,
    required this.id,
    required this.fromId,
    required this.toId,
    required this.fromIdx,
    required this.toIdx,
    required this.points,
    required this.lengthMeters,
  }) : cumPx = cumulativeLengths(points);

  final int index;
  final String? id;
  final String fromId;
  final String toId;
  final int fromIdx;
  final int toIdx;
  final List<Offset> points;
  final List<double> cumPx;
  final double lengthMeters;

  double get lengthPx => cumPx.last;

  /// Pixels per metre on THIS edge (accounts for a configured distance that
  /// differs slightly from the drawn geometry).
  double get pxPerMeter => lengthMeters > 0 ? lengthPx / lengthMeters : 0.0;

  Offset pointAt(double d) => pointAtLength(
        points,
        cumPx,
        d.clamp(0.0, lengthMeters).toDouble() * pxPerMeter,
      );

  /// Map bearing of travel at distance [d]; dir +1 = towards `to`, -1 = `from`.
  double bearingAt(double d, int dir) {
    final px = (d * pxPerMeter).clamp(0.0, lengthPx).toDouble();
    final b = mapBearing(tangentAtLength(points, cumPx, px));
    return dir >= 0 ? b : wrapAngle(b + math.pi);
  }
}

class GraphProjection {
  const GraphProjection(this.location, this.point, this.offGraphMeters);
  final GraphLocation location;
  final Offset point;

  /// How far (m) the query point was from the graph before projection.
  final double offGraphMeters;
}

class PathLeg {
  const PathLeg(this.edge, this.from, this.to);
  final int edge;
  final double from;
  final double to;
  double get length => (to - from).abs();
}

class GraphPath {
  GraphPath(this.legs) : length = legs.fold(0.0, (s, l) => s + l.length);
  final List<PathLeg> legs;
  final double length;
}

/// Guidance used when movement reaches a node with several ways onward.
class TurnPolicy {
  const TurnPolicy({this.routeNext = const {}, this.headingBearing});

  /// nodeId -> next nodeId on the active route.
  final Map<String, String> routeNext;

  /// Map-frame bearing the user is facing, if known.
  final double? headingBearing;

  static const TurnPolicy none = TurnPolicy();
}

class MoveResult {
  const MoveResult({
    required this.location,
    required this.direction,
    required this.deadEnd,
    required this.turnAngleRad,
    required this.nodesPassed,
  });
  final GraphLocation location;

  /// +1 towards the edge's `to` node, -1 towards `from`.
  final int direction;
  final bool deadEnd;

  /// Signed turn (rad) taken at the last node passed; 0 if none.
  final double turnAngleRad;
  final int nodesPassed;
}

class _Row {
  _Row(this.dist, this.prevNode, this.prevEdge);
  final List<double> dist;
  final List<int> prevNode;
  final List<int> prevEdge;
}

class _Choice {
  _Choice(this.edge, this.dir, this.bearing, this.score);
  final int edge;
  final int dir;
  final double bearing;
  final double score;
}

/// The navigation graph and everything that keeps a position ON it:
/// projection, path distances (along polylines), shortest paths, and
/// graph-constrained movement with turn handling.
class GraphPositionService {
  GraphPositionService(this.config)
      : pixelsPerMeter = config.pixelsPerMeter {
    _build();
  }

  final BuildingConfig config;
  final double pixelsPerMeter;

  final List<GraphEdge> edges = [];
  final List<String> _nodeIds = [];
  final List<Offset> _nodePos = [];
  final Map<String, int> _nodeIndex = {};
  final List<List<int>> _incident = [];
  final Map<int, _Row> _rows = {};

  double totalLengthMeters = 0.0;

  List<GraphLocation>? _samples;
  double _samplesStep = 0.0;

  bool get isEmpty => edges.isEmpty;

  // --------------------------------------------------------------------------
  // construction
  // --------------------------------------------------------------------------

  void _build() {
    for (final n in config.nodes) {
      _nodeIndex[n.id] = _nodeIds.length;
      _nodeIds.add(n.id);
      _nodePos.add(n.position);
      _incident.add(<int>[]);
    }

    for (final e in config.edges) {
      final fi = _nodeIndex[e.from];
      final ti = _nodeIndex[e.to];
      if (fi == null || ti == null || fi == ti) {
        PosLog.d('GRAPH', () => 'skipping invalid edge ${e.from}->${e.to}');
        continue;
      }
      final a = _nodePos[fi];
      final b = _nodePos[ti];

      final pts = <Offset>[...e.polyline];
      if (pts.isEmpty) {
        pts.addAll([a, b]);
      } else {
        if ((pts.first - a).distance > 1.0) pts.insert(0, a);
        if ((pts.last - b).distance > 1.0) pts.add(b);
      }

      final px = polylineLength(pts);
      final dm = e.distanceMeters;
      final meters = (dm != null && dm > 0) ? dm : px / pixelsPerMeter;
      if (meters <= 0.01) continue;

      final edge = GraphEdge(
        index: edges.length,
        id: e.id,
        fromId: e.from,
        toId: e.to,
        fromIdx: fi,
        toIdx: ti,
        points: pts,
        lengthMeters: meters,
      );
      edges.add(edge);
      _incident[fi].add(edge.index);
      _incident[ti].add(edge.index);
      totalLengthMeters += meters;
    }
  }

  // --------------------------------------------------------------------------
  // basic queries
  // --------------------------------------------------------------------------

  Offset pointOf(GraphLocation l) => edges[l.edge].pointAt(l.distance);

  GraphLocation? nodeLocation(String nodeId) {
    final idx = _nodeIndex[nodeId];
    if (idx == null || _incident[idx].isEmpty) return null;
    final e = edges[_incident[idx].first];
    return e.fromIdx == idx
        ? GraphLocation(e.index, 0.0)
        : GraphLocation(e.index, e.lengthMeters);
  }

  String nearestNodeId(GraphLocation l) {
    final e = edges[l.edge];
    return l.distance <= e.lengthMeters / 2 ? e.fromId : e.toId;
  }

  double distanceToNearestNode(GraphLocation l) {
    final e = edges[l.edge];
    return math.min(l.distance, e.lengthMeters - l.distance);
  }

  double travelBearing(GraphLocation l, int dir) =>
      edges[l.edge].bearingAt(l.distance, dir);

  /// Orthogonal projection of a map-pixel point onto the nearest edge.
  GraphProjection? project(Offset px) {
    GraphProjection? best;
    for (final e in edges) {
      final p = projectOntoPolyline(px, e.points, e.cumPx);
      final offM = p.offset / pixelsPerMeter;
      if (best == null || offM < best.offGraphMeters) {
        final d = e.pxPerMeter > 0 ? p.distance / e.pxPerMeter : 0.0;
        best = GraphProjection(
          GraphLocation(e.index, d.clamp(0.0, e.lengthMeters).toDouble()),
          p.point,
          offM,
        );
      }
    }
    return best;
  }

  /// Legacy-compatible helper: snap a map point to the graph.
  Offset constrainPositionToGraph(Offset px) => project(px)?.point ?? px;

  /// Where a beacon sits on the graph. A configured node association wins
  /// (BEACON != NODE, but the node is the beacon's logical graph anchor);
  /// otherwise its map position is projected if it is near the graph.
  GraphLocation? anchorForBeacon(NavigationBeacon b, {double maxSnapMeters = 5.0}) {
    final nid = b.nodeId;
    if (nid != null) {
      final loc = nodeLocation(nid);
      if (loc != null) return loc;
    }
    if (b.hasPosition) {
      final pr = project(b.position);
      if (pr != null && pr.offGraphMeters <= maxSnapMeters) return pr.location;
    }
    return null;
  }

  // --------------------------------------------------------------------------
  // shortest paths (Dijkstra, cached per source node)
  // --------------------------------------------------------------------------

  _Row _row(int src) => _rows.putIfAbsent(src, () => _dijkstra(src));

  _Row _dijkstra(int src) {
    final n = _nodeIds.length;
    final dist = List<double>.filled(n, double.infinity);
    final prevNode = List<int>.filled(n, -1);
    final prevEdge = List<int>.filled(n, -1);
    final done = List<bool>.filled(n, false);
    dist[src] = 0.0;
    for (var iter = 0; iter < n; iter++) {
      var u = -1;
      var best = double.infinity;
      for (var i = 0; i < n; i++) {
        if (!done[i] && dist[i] < best) {
          best = dist[i];
          u = i;
        }
      }
      if (u < 0) break;
      done[u] = true;
      for (final ei in _incident[u]) {
        final e = edges[ei];
        final v = e.fromIdx == u ? e.toIdx : e.fromIdx;
        final nd = dist[u] + e.lengthMeters;
        if (nd < dist[v]) {
          dist[v] = nd;
          prevNode[v] = u;
          prevEdge[v] = ei;
        }
      }
    }
    return _Row(dist, prevNode, prevEdge);
  }

  /// Node ids of the shortest route (by metres) from [startId] to [endId].
  /// Empty if either is unknown or they are not connected.
  List<String> shortestNodePath(String startId, String endId) {
    final s = _nodeIndex[startId];
    final t = _nodeIndex[endId];
    if (s == null || t == null) return const [];
    if (s == t) return [startId];
    final row = _row(t);
    if (row.dist[s].isInfinite) return const [];
    final out = <String>[startId];
    var cur = s;
    var guard = 0;
    while (cur != t && guard++ < _nodeIds.length + 2) {
      cur = row.prevNode[cur];
      if (cur < 0) return const [];
      out.add(_nodeIds[cur]);
    }
    return out;
  }

  double nodeDistance(String a, String b) {
    final ia = _nodeIndex[a];
    final ib = _nodeIndex[b];
    if (ia == null || ib == null) return double.infinity;
    return _row(ib).dist[ia];
  }

  /// Distance along the graph between two locations (metres).
  double graphDistance(GraphLocation a, GraphLocation b) {
    final ea = edges[a.edge];
    final eb = edges[b.edge];
    var best = a.edge == b.edge ? (a.distance - b.distance).abs() : double.infinity;

    final aNodes = [ea.fromIdx, ea.toIdx];
    final aOff = [a.distance, ea.lengthMeters - a.distance];
    final bNodes = [eb.fromIdx, eb.toIdx];
    final bOff = [b.distance, eb.lengthMeters - b.distance];

    for (var i = 0; i < 2; i++) {
      for (var j = 0; j < 2; j++) {
        final nd = _row(bNodes[j]).dist[aNodes[i]];
        final total = aOff[i] + nd + bOff[j];
        if (total < best) best = total;
      }
    }
    return best;
  }

  /// Shortest path between two locations as a list of edge legs.
  GraphPath? pathBetween(GraphLocation a, GraphLocation b) {
    final ea = edges[a.edge];
    final eb = edges[b.edge];

    var best = a.edge == b.edge ? (a.distance - b.distance).abs() : double.infinity;
    var bestSa = -1;
    var bestSb = -1;

    for (var sa = 0; sa < 2; sa++) {
      for (var sb = 0; sb < 2; sb++) {
        final na = sa == 0 ? ea.fromIdx : ea.toIdx;
        final nb = sb == 0 ? eb.fromIdx : eb.toIdx;
        final da = sa == 0 ? a.distance : ea.lengthMeters - a.distance;
        final db = sb == 0 ? b.distance : eb.lengthMeters - b.distance;
        final total = da + _row(nb).dist[na] + db;
        if (total < best) {
          best = total;
          bestSa = sa;
          bestSb = sb;
        }
      }
    }
    if (best.isInfinite) return null;

    if (bestSa < 0) {
      return GraphPath([PathLeg(a.edge, a.distance, b.distance)]);
    }

    final legs = <PathLeg>[
      PathLeg(a.edge, a.distance, bestSa == 0 ? 0.0 : ea.lengthMeters),
    ];
    final na = bestSa == 0 ? ea.fromIdx : ea.toIdx;
    final nb = bestSb == 0 ? eb.fromIdx : eb.toIdx;
    final row = _row(nb);
    var cur = na;
    var guard = 0;
    while (cur != nb && guard++ < _nodeIds.length + 2) {
      final ei = row.prevEdge[cur];
      final nxt = row.prevNode[cur];
      if (ei < 0 || nxt < 0) return null;
      final e = edges[ei];
      legs.add(e.fromIdx == cur
          ? PathLeg(ei, 0.0, e.lengthMeters)
          : PathLeg(ei, e.lengthMeters, 0.0));
      cur = nxt;
    }
    legs.add(PathLeg(b.edge, bestSb == 0 ? 0.0 : eb.lengthMeters, b.distance));
    return GraphPath(legs);
  }

  /// Location reached after walking [meters] along [path] (clamped to its end).
  GraphLocation advanceAlongPath(GraphPath path, double meters) {
    var remaining = meters;
    for (final leg in path.legs) {
      final len = leg.length;
      if (remaining <= len) {
        final sign = leg.to >= leg.from ? 1.0 : -1.0;
        return GraphLocation(leg.edge, leg.from + sign * remaining);
      }
      remaining -= len;
    }
    final last = path.legs.last;
    return GraphLocation(last.edge, last.to);
  }

  /// Move from [a] towards [b] along the shortest path by at most [meters].
  GraphLocation moveToward(GraphLocation a, GraphLocation b, double meters) {
    final path = pathBetween(a, b);
    if (path == null || meters <= 0) return a;
    return advanceAlongPath(path, meters);
  }

  // --------------------------------------------------------------------------
  // graph-constrained movement (PDR)
  // --------------------------------------------------------------------------

  /// Walk [meters] from [start] in direction [direction] (+1 towards the
  /// edge's `to` node). On reaching a node, continues onto the connected edge
  /// preferred by the route, the user's heading and path continuity, so turns
  /// follow the configured geometry (never a straight line between nodes).
  MoveResult moveAlong(
    GraphLocation start,
    double meters,
    int direction, {
    TurnPolicy policy = TurnPolicy.none,
  }) {
    var edgeIdx = start.edge;
    var d = start.distance;
    var dir = direction >= 0 ? 1 : -1;
    var remaining = meters;
    var deadEnd = false;
    var turn = 0.0;
    var passed = 0;
    var guard = 0;

    while (remaining > 1e-9 && guard++ < 64) {
      final e = edges[edgeIdx];
      final target = dir > 0 ? e.lengthMeters : 0.0;
      final room = (target - d).abs();
      if (remaining <= room) {
        d += dir * remaining;
        remaining = 0.0;
        break;
      }
      remaining -= room;
      d = target;
      final nodeIdx = dir > 0 ? e.toIdx : e.fromIdx;
      passed++;

      final arrivalBearing = e.bearingAt(d, dir);
      final next = _chooseNext(nodeIdx, edgeIdx, arrivalBearing, policy);
      if (next == null) {
        deadEnd = true;
        break;
      }
      turn = angleDiff(next.bearing, arrivalBearing);
      edgeIdx = next.edge;
      dir = next.dir;
      d = dir > 0 ? 0.0 : edges[edgeIdx].lengthMeters;
    }

    final len = edges[edgeIdx].lengthMeters;
    return MoveResult(
      location: GraphLocation(edgeIdx, d.clamp(0.0, len).toDouble()),
      direction: dir,
      deadEnd: deadEnd,
      turnAngleRad: turn,
      nodesPassed: passed,
    );
  }

  _Choice? _chooseNext(
    int nodeIdx,
    int arrivedEdge,
    double arrivalBearing,
    TurnPolicy policy,
  ) {
    _Choice? best;
    final nodeId = _nodeIds[nodeIdx];
    for (final ei in _incident[nodeIdx]) {
      if (ei == arrivedEdge) continue;
      final e = edges[ei];
      final atFrom = e.fromIdx == nodeIdx;
      final dir = atFrom ? 1 : -1;
      final startD = atFrom ? 0.0 : e.lengthMeters;
      final b = e.bearingAt(startD, dir);

      // Prefer going straight on...
      var score = math.cos(angleDiff(b, arrivalBearing));
      // ...but follow the user's heading if known...
      final hb = policy.headingBearing;
      if (hb != null) score += 0.8 * math.cos(angleDiff(b, hb));
      // ...and the active route above all.
      final other = atFrom ? _nodeIds[e.toIdx] : _nodeIds[e.fromIdx];
      if (policy.routeNext[nodeId] == other) score += 10.0;

      if (best == null || score > best.score) {
        best = _Choice(ei, dir, b, score);
      }
    }
    return best;
  }

  // --------------------------------------------------------------------------
  // sampling (used by the BLE least-squares search)
  // --------------------------------------------------------------------------

  List<GraphLocation> samples(double stepMeters) {
    if (_samples != null && _samplesStep == stepMeters) return _samples!;
    final out = <GraphLocation>[];
    for (final e in edges) {
      var d = 0.0;
      while (d < e.lengthMeters) {
        out.add(GraphLocation(e.index, d));
        d += stepMeters;
      }
      out.add(GraphLocation(e.index, e.lengthMeters));
    }
    _samples = out;
    _samplesStep = stepMeters;
    return out;
  }

  // --------------------------------------------------------------------------
  // routing helpers
  // --------------------------------------------------------------------------

  /// Which end of the user's current edge is the best first node of a route to
  /// [destNodeId] (accounts for the metres still to walk to reach it).
  String? bestRouteStartNode(GraphLocation loc, String destNodeId) {
    final dest = _nodeIndex[destNodeId];
    if (dest == null) return null;
    final e = edges[loc.edge];
    final row = _row(dest);
    final viaFrom = loc.distance + row.dist[e.fromIdx];
    final viaTo = (e.lengthMeters - loc.distance) + row.dist[e.toIdx];
    if (viaFrom.isInfinite && viaTo.isInfinite) return null;
    return viaFrom <= viaTo ? e.fromId : e.toId;
  }

  /// Total walking length of a node route, in metres.
  double calculateRouteLength(List<String> route) {
    var total = 0.0;
    for (var i = 0; i < route.length - 1; i++) {
      final d = nodeDistance(route[i], route[i + 1]);
      if (d.isFinite) total += d;
    }
    return total;
  }

  /// Map-pixel polyline following the real corridor geometry of a node route.
  List<Offset> routePolyline(List<String> route) {
    final out = <Offset>[];
    for (var i = 0; i < route.length - 1; i++) {
      final a = _nodeIndex[route[i]];
      final b = _nodeIndex[route[i + 1]];
      if (a == null || b == null) continue;
      GraphEdge? best;
      for (final ei in _incident[a]) {
        final e = edges[ei];
        final other = e.fromIdx == a ? e.toIdx : e.fromIdx;
        if (other == b && (best == null || e.lengthMeters < best.lengthMeters)) {
          best = e;
        }
      }
      if (best == null) {
        if (out.isEmpty) out.add(_nodePos[a]);
        out.add(_nodePos[b]);
        continue;
      }
      final pts = best.fromIdx == a ? best.points : best.points.reversed.toList();
      out.addAll(out.isEmpty ? pts : pts.skip(1));
    }
    if (out.isEmpty && route.length == 1) {
      final a = _nodeIndex[route.first];
      if (a != null) out.add(_nodePos[a]);
    }
    return out;
  }
}
