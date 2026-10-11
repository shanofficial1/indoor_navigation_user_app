/// A position expressed ON the navigation graph: which edge, and how many
/// metres along that edge (measured from the edge's `from` node along its
/// polyline). This is the engine's native position representation, so the
/// user can never be "off the graph".
class GraphLocation {
  const GraphLocation(this.edge, this.distance);

  /// Index into `GraphPositionService.edges`.
  final int edge;

  /// Metres from the `from` end of the edge, in [0, edge length].
  final double distance;

  GraphLocation copyWith({int? edge, double? distance}) =>
      GraphLocation(edge ?? this.edge, distance ?? this.distance);

  @override
  String toString() => 'GraphLocation(edge=$edge, d=${distance.toStringAsFixed(2)}m)';
}
