import 'dart:ui';

class NavigationBeacon {
  final String id;
  final String name;
  final String mac;

  /// Physical position on the map. Optional in newer JSON (the associated node
  /// then defines where the beacon is) - see [hasPosition].
  final Offset position;
  final bool hasPosition;
  final double range;

  /// The logical navigation node this beacon is associated with.
  /// BEACON != NODE: a beacon is a physical ESP32, a node is a graph vertex.
  final String? nodeId;

  /// Calibrated RSSI at the reference distance (dBm). null => global default.
  final double? txPower;

  /// Per-beacon path-loss exponent override. null => global default.
  final double? pathLossExponent;

  /// Disabled beacons never enter the positioning pipeline.
  final bool enabled;

  NavigationBeacon({
    required this.id,
    required this.name,
    required this.mac,
    required this.position,
    required this.range,
    required this.nodeId,
    this.hasPosition = true,
    this.txPower,
    this.pathLossExponent,
    this.enabled = true,
  });

  /// MAC in canonical form (upper case, ':' separated) for comparisons.
  String get normalizedMac => normalizeMac(mac);

  static String normalizeMac(String mac) =>
      mac.trim().toUpperCase().replaceAll('-', ':');

  factory NavigationBeacon.fromJson(Map<String, dynamic> json) {
    final x = json['x'];
    final y = json['y'];
    final hasPos = x is num && y is num;

    final tx = json['txPower'];
    final n = json['pathLossExponent'];
    final range = json['range'];

    final id = json['id'] as String;

    return NavigationBeacon(
      id: id,
      name: (json['name'] as String?) ?? id,
      mac: ((json['mac'] ?? json['macAddress']) as String),
      position: hasPos
          ? Offset(x.toDouble(), y.toDouble())
          : Offset.zero,
      hasPosition: hasPos,
      range: range is num ? range.toDouble() : 0.0,
      nodeId: json['nodeId'] as String?,
      txPower: tx is num ? tx.toDouble() : null,
      pathLossExponent: n is num ? n.toDouble() : null,
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
    );
  }
}
