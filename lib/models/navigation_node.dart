import 'dart:ui';

class NavigationNode {
  final String id;
  final Offset position;
  final List<String> roomIds;

  NavigationNode({
    required this.id,
    required this.position,
    required this.roomIds,
  });

  factory NavigationNode.fromJson(Map<String, dynamic> json) {
    return NavigationNode(
      id: json['id'] as String,
      position: Offset(
        (json['x'] as num).toDouble(),
        (json['y'] as num).toDouble(),
      ),
      roomIds: List<String>.from(json['rooms'] ?? json['roomIds'] ?? []),
    );
  }
}
