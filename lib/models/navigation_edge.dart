import 'dart:ui';

class NavigationEdge {
  final String? id;
  final String from;
  final String to;

  /// Real walking distance along the edge. Optional: when absent it is derived
  /// from the (poly)line geometry and the map scale.
  final double? distanceMeters;

  /// Optional geometry of the walkable path in map-pixel coordinates. It may
  /// contain just the intermediate bends or the full from..to line; missing
  /// end points are completed from the node positions. Empty = straight line.
  final List<Offset> polyline;

  NavigationEdge({
    this.id,
    required this.from,
    required this.to,
    this.distanceMeters,
    this.polyline = const [],
  });

  factory NavigationEdge.fromJson(Map<String, dynamic> json) {
    final points = <Offset>[];
    final raw = json['polyline'];
    if (raw is List) {
      for (final p in raw) {
        if (p is Map && p['x'] is num && p['y'] is num) {
          points.add(Offset(
            (p['x'] as num).toDouble(),
            (p['y'] as num).toDouble(),
          ));
        } else if (p is List &&
            p.length >= 2 &&
            p[0] is num &&
            p[1] is num) {
          points.add(Offset(
            (p[0] as num).toDouble(),
            (p[1] as num).toDouble(),
          ));
        }
      }
    }

    final dist = json['distanceMeters'];

    return NavigationEdge(
      id: json['id'] as String?,
      from: json['from'] as String,
      to: json['to'] as String,
      distanceMeters: dist is num && dist > 0 ? dist.toDouble() : null,
      polyline: points,
    );
  }
}
