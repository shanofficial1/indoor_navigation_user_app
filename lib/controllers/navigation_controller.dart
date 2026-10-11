import 'package:flutter/foundation.dart';

import '../models/building_config.dart';
import '../models/destination.dart';
import '../services/config_service.dart';
import '../services/route_service.dart';
import 'positioning_controller.dart';

/// Current location + destination -> route, remaining distance, arrival.
///
/// The route starts at whichever end of the user's current edge gives the
/// shortest total walk to the destination, so it never makes the user walk
/// backwards when the destination is ahead.
class NavigationController extends ChangeNotifier {
  NavigationController({
    required this.config,
    required this.positioning,
    ConfigService? configService,
  })  : _configService = configService ?? ConfigService(),
        _routeService = RouteService(graph: positioning.graph) {
    positioning.addListener(_onPosition);
  }

  final BuildingConfig config;
  final PositioningController positioning;
  final ConfigService _configService;
  final RouteService _routeService;

  String? destinationNodeId;
  String? destinationName;
  List<String> route = const [];
  double totalDistanceMeters = 0.0;
  double remainingDistanceMeters = 0.0;
  bool arrived = false;
  String? _lastStartNode;

  bool get isNavigating => destinationNodeId != null;

  /// Returns false if the destination has no node.
  bool setDestination(Destination destination) {
    final node = _configService.findNodeForDestination(config, destination.id);
    if (node == null) return false;
    destinationNodeId = node.id;
    destinationName = destination.name;
    arrived = false;
    route = const [];
    _lastStartNode = null;
    totalDistanceMeters = 0.0;
    remainingDistanceMeters = 0.0;
    _recompute(force: true);
    notifyListeners();
    return true;
  }

  void stop() {
    destinationNodeId = null;
    destinationName = null;
    route = const [];
    arrived = false;
    _lastStartNode = null;
    positioning.setRouteHint(const {});
    notifyListeners();
  }

  void _onPosition() {
    if (!isNavigating) return;
    _recompute();
    notifyListeners();
  }

  void _recompute({bool force = false}) {
    final dest = destinationNodeId;
    final loc = positioning.snapshot?.location;
    if (dest == null || loc == null) return;

    final g = positioning.graph;
    final destLoc = g.nodeLocation(dest);
    if (destLoc == null) return;

    remainingDistanceMeters = g.graphDistance(loc, destLoc);
    if (totalDistanceMeters <= 0 || force) {
      totalDistanceMeters = remainingDistanceMeters;
    }

    if (remainingDistanceMeters <= config.positioning.params.arrivalRadiusMeters) {
      arrived = true;
      route = [dest];
      positioning.setRouteHint(const {});
      return;
    }
    arrived = false;

    final start = g.bestRouteStartNode(loc, dest);
    if (start == null) {
      route = const [];
      return;
    }
    if (force || start != _lastStartNode || route.isEmpty) {
      _lastStartNode = start;
      route = _routeService.findShortestPath(config, start, dest);
      final hint = <String, String>{};
      for (var i = 0; i < route.length - 1; i++) {
        hint[route[i]] = route[i + 1];
      }
      positioning.setRouteHint(hint);
    }
  }

  @override
  void dispose() {
    positioning.removeListener(_onPosition);
    super.dispose();
  }
}
