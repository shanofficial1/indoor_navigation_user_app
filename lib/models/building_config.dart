import 'navigation_node.dart';
import 'navigation_edge.dart';
import 'navigation_beacon.dart';
import 'destination.dart';
import 'positioning_config.dart';

class BuildingConfig {
  final int version;

  final String buildingId;
  final String buildingName;
  final int floor;

  final String mapImage;
  final double mapWidth;
  final double mapHeight;
  final double mapLengthMeters;

  final List<NavigationNode> nodes;
  final List<NavigationEdge> edges;
  final List<NavigationBeacon> beacons;
  final List<Destination> rooms;

  /// Optional positioning sections of the JSON (rssiFilter, distanceModel,
  /// ble, positioning, positionSmoothing, motion, debug). Defaults are used
  /// for anything missing, so older JSON files load unchanged.
  final PositioningConfig positioning;

  BuildingConfig({
    required this.version,
    required this.buildingId,
    required this.buildingName,
    required this.floor,
    required this.mapImage,
    required this.mapWidth,
    required this.mapHeight,
    required this.mapLengthMeters,
    required this.nodes,
    required this.edges,
    required this.beacons,
    required this.rooms,
    this.positioning = const PositioningConfig(),
  });

  /// Map pixels per real-world metre.
  double get pixelsPerMeter =>
      mapLengthMeters > 0 ? mapWidth / mapLengthMeters : 1.0;

  late final Map<String, NavigationNode> nodeById = {
    for (final n in nodes) n.id: n,
  };

  late final Map<String, NavigationBeacon> beaconByMac = {
    for (final b in beacons) b.normalizedMac: b,
  };

  factory BuildingConfig.fromJson(Map<String, dynamic> json) {
    final building = json['building'] as Map<String, dynamic>;
    final map = json['map'] as Map<String, dynamic>;

    return BuildingConfig(
      version: json['version'] as int,

      buildingId: building['id'] as String,
      buildingName: building['name'] as String,
      floor: building['floor'] as int,

      mapImage: map['image'] as String,
      mapWidth: (map['width'] as num).toDouble(),
      mapHeight: (map['height'] as num).toDouble(),
      mapLengthMeters: (map['lengthMeters'] as num).toDouble(),

      nodes: (json['nodes'] as List)
          .map((node) => NavigationNode.fromJson(
                Map<String, dynamic>.from(node),
              ))
          .toList(),

      edges: (json['edges'] as List)
          .map((edge) => NavigationEdge.fromJson(
                Map<String, dynamic>.from(edge),
              ))
          .toList(),

      rooms: (json['rooms'] as List)
          .map((room) => Destination.fromJson(
                Map<String, dynamic>.from(room),
              ))
          .toList(),

      beacons: (json['beacons'] as List)
          .map((beacon) => NavigationBeacon.fromJson(
                Map<String, dynamic>.from(beacon),
              ))
          .toList(),

      positioning: PositioningConfig.fromJson(json),
    );
  }
}
