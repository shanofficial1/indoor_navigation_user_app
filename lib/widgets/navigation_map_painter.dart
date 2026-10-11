import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../controllers/direction_beam_controller.dart';
import '../models/building_config.dart';

class NavigationMapPainter extends CustomPainter {
  final BuildingConfig config;
  final List<String> route;

  /// Route geometry following the corridor polylines (map-pixel coordinates).
  /// When null the route is drawn as straight node-to-node lines (old look).
  final List<Offset>? routePoints;
  final String? currentNodeId;
  final Offset? currentPosition;
  final Color markerColor;

  /// Facing direction beam. Also the repaint source: when the heading changes
  /// only this overlay repaints, the widget tree is not rebuilt.
  final DirectionBeamController? beam;

  NavigationMapPainter({
    required this.config,
    required this.route,
    this.routePoints,
    this.currentNodeId,
    this.currentPosition,
    this.markerColor = Colors.blue,
    this.beam,
  }) : super(repaint: beam);

  /// Beam length in canvas pixels (same units as the 6 px marker).
  static const double _beamLength = 40.0;

  @override
  void paint(Canvas canvas, Size size) {
    const double jsonWidth = 3000.0;
    const double jsonHeight = 3000.0;

    final double scaleX = size.width / jsonWidth;
    final double scaleY = size.height / jsonHeight;

    final pathPaint = Paint()
      ..color = Colors.blue
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final nodePaint = Paint()
      ..color = Colors.red
      ..style = PaintingStyle.fill;

    final nodeBorderPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    Offset convert(Offset position) {
      return Offset(
        position.dx * scaleX,
        position.dy * scaleY,
      );
    }

    // Draw only the calculated route.
    final pts = routePoints;
    if (pts != null && pts.length >= 2) {
      final path = Path()..moveTo(convert(pts.first).dx, convert(pts.first).dy);
      for (var i = 1; i < pts.length; i++) {
        final p = convert(pts[i]);
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, pathPaint);
    } else {
      for (int i = 0; i < route.length - 1; i++) {
        final fromNode = config.nodeById[route[i]];
        final toNode = config.nodeById[route[i + 1]];
        if (fromNode == null || toNode == null) continue;

        canvas.drawLine(
          convert(fromNode.position),
          convert(toNode.position),
          pathPaint,
        );
      }
    }

    // Draw nodes.
    for (final node in config.nodes) {
      final position = convert(node.position);

      canvas.drawCircle(position, 2, nodePaint);
      canvas.drawCircle(position, 2, nodeBorderPaint);
    }

    // User marker.
    if (currentPosition != null) {
      final point = convert(currentPosition!);

      // Direction beam, drawn UNDER the marker and anchored at its centre.
      // It lives in the same canvas as the marker, which sits inside the
      // InteractiveViewer child, so it follows zoom and pan automatically.
      final b = beam;
      if (b != null && b.visible) {
        // Bearing 0 = map up, clockwise  ->  canvas angle 0 = +x, clockwise.
        final centre = b.bearingRad - math.pi / 2;
        final half = b.spreadRad / 2;
        final rect = Rect.fromCircle(center: point, radius: _beamLength);
        final cone = Path()
          ..moveTo(point.dx, point.dy)
          ..arcTo(rect, centre - half, 2 * half, false)
          ..close();
        final shader = RadialGradient(
          colors: [
            markerColor.withValues(alpha: 0.65 * b.opacity),
            markerColor.withValues(alpha: 0.0),
          ],
        ).createShader(rect);
        canvas.drawPath(
          cone,
          Paint()
            ..shader = shader
            ..style = PaintingStyle.fill,
        );
      }

      canvas.drawCircle(
        point,
        9,
        Paint()
          ..color = markerColor.withValues(alpha: 0.2)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        point,
        6,
        Paint()
          ..color = markerColor
          ..style = PaintingStyle.fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant NavigationMapPainter oldDelegate) {
    return oldDelegate.config != config ||
        !listEquals(oldDelegate.route, route) ||
        !listEquals(oldDelegate.routePoints, routePoints) ||
        oldDelegate.currentNodeId != currentNodeId ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.markerColor != markerColor ||
        oldDelegate.beam != beam;
  }
}
