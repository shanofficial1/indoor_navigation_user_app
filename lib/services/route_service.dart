import '../models/building_config.dart';
import 'graph_position_service.dart';

/// Shortest-route lookup. Now weighted by real walking distance (metres along
/// each edge's geometry) rather than by number of hops. Same call signature
/// as before.
class RouteService {
  RouteService({GraphPositionService? graph})
      // ignore: prefer_initializing_formals
      : _graph = graph;

  GraphPositionService? _graph;
  BuildingConfig? _graphConfig;

  GraphPositionService _graphFor(BuildingConfig config) {
    final g = _graph;
    if (g != null && identical(g.config, config)) return g;
    if (_graph == null || !identical(_graphConfig, config)) {
      _graph = GraphPositionService(config);
      _graphConfig = config;
    }
    return _graph!;
  }

  List<String> findShortestPath(
    BuildingConfig config,
    String startNodeId,
    String destinationNodeId,
  ) {
    if (startNodeId == destinationNodeId) return [startNodeId];
    return _graphFor(config).shortestNodePath(startNodeId, destinationNodeId);
  }
}
