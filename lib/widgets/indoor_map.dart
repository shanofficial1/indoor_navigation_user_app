import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../controllers/direction_beam_controller.dart';
import '../models/building_config.dart';
import '../services/graph_position_service.dart';
import 'navigation_map_painter.dart';

/// The floor map. Fixed orientation, pan + pinch zoom.
///
/// Starts already zoomed to fill the screen (and centred on the user as soon
/// as a position is known) instead of a small map in the corner.
class IndoorMap extends StatefulWidget {
  final BuildingConfig config;
  final List<String> route;
  final String? currentNodeId;
  final Offset? currentPosition;

  /// Used to draw the route along the real corridor polylines.
  final GraphPositionService? graph;

  /// Marker colour (e.g. orange when confidence is low).
  final Color markerColor;

  /// Optional facing-direction beam drawn from the position marker.
  final DirectionBeamController? beam;

  /// Distance of the "my location" button from the bottom edge.
  final double bottomPadding;

  const IndoorMap({
    super.key,
    required this.config,
    this.route = const [],
    this.currentNodeId,
    this.currentPosition,
    this.graph,
    this.markerColor = Colors.blue,
    this.beam,
    this.bottomPadding = 24,
  });

  // Actual floor-plan PNG dimensions.
  static const double imageWidth = 1290.0;
  static const double imageHeight = 1219.0;

  /// Coordinate space of the node positions (same constant the painter uses).
  static const double mapSpace = 3000.0;

  /// Never start more zoomed-in than this.
  static const double maxInitialScale = 2.5;

  @override
  State<IndoorMap> createState() => _IndoorMapState();
}

class _IndoorMapState extends State<IndoorMap> {
  final TransformationController _tc = TransformationController();

  Size? _viewport;
  double _baseW = 0;
  double _baseH = 0;
  bool _interacted = false;
  bool _centeredOnUser = false;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  double _fitScale() => (_viewport!.height / _baseH)
      .clamp(1.0, IndoorMap.maxInitialScale)
      .toDouble();

  Offset _childPoint(Offset p) => Offset(
        p.dx * _baseW / IndoorMap.mapSpace,
        p.dy * _baseH / IndoorMap.mapSpace,
      );

  double _clampAxis(double v, double lo, double hi) =>
      lo > hi ? (lo + hi) / 2 : v.clamp(lo, hi).toDouble();

  /// Shows [focus] (child coordinates) in the middle of the viewport.
  void _setView(Offset focus, double scale) {
    final v = _viewport;
    if (v == null) return;
    final tx = _clampAxis(v.width / 2 - focus.dx * scale, v.width - _baseW * scale, 0);
    final ty = _clampAxis(v.height / 2 - focus.dy * scale, v.height - _baseH * scale, 0);
    _tc.value = Matrix4(
      scale, 0, 0, 0, //
      0, scale, 0, 0, //
      0, 0, 1, 0, //
      tx, ty, 0, 1,
    );
  }

  void _initialView() {
    if (!mounted || _viewport == null) return;
    final pos = widget.currentPosition;
    _setView(
      pos != null ? _childPoint(pos) : Offset(_baseW / 2, _baseH / 2),
      _fitScale(),
    );
    _centeredOnUser = pos != null;
    _interacted = false;
  }

  void _recenter() {
    final pos = widget.currentPosition;
    if (_viewport == null || pos == null) return;
    final current = _tc.value.getMaxScaleOnAxis();
    _setView(_childPoint(pos), math.max(current, _fitScale()));
    _interacted = false;
  }

  @override
  void didUpdateWidget(covariant IndoorMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    // First position fix: bring the user into view (unless they already
    // started moving the map themselves).
    if (!_centeredOnUser &&
        !_interacted &&
        widget.currentPosition != null &&
        _viewport != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _interacted) return;
        _setView(_childPoint(widget.currentPosition!), _fitScale());
        _centeredOnUser = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final routePoints = widget.graph?.routePolyline(widget.route);
    final animMs = widget.config.positioning.smoothing.displayAnimationMs;
    final pos = widget.currentPosition;

    return Container(
      color: const Color(0xFFEFF2F7),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final double w = constraints.maxWidth;
          final double h = w * (IndoorMap.imageHeight / IndoorMap.imageWidth);
          final double vh = constraints.hasBoundedHeight ? constraints.maxHeight : h;

          final viewport = Size(w, vh);
          if (_viewport != viewport) {
            _viewport = viewport;
            _baseW = w;
            _baseH = h;
            // Fit the map to the screen on first layout / rotation.
            WidgetsBinding.instance.addPostFrameCallback((_) => _initialView());
          }

          Widget painterFor(Offset? position) => CustomPaint(
                size: Size(w, h),
                painter: NavigationMapPainter(
                  config: widget.config,
                  route: widget.route,
                  routePoints: routePoints,
                  currentNodeId: widget.currentNodeId,
                  currentPosition: position,
                  markerColor: widget.markerColor,
                  beam: position == null ? null : widget.beam,
                ),
              );

          return Stack(
            children: [
              InteractiveViewer(
                transformationController: _tc,
                minScale: 1.0,
                maxScale: 5.0,
                boundaryMargin: EdgeInsets.zero,
                constrained: false,
                onInteractionStart: (_) => _interacted = true,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Stack(
                    children: [
                      Image.asset(
                        widget.config.mapImage,
                        width: w,
                        height: h,
                        fit: BoxFit.fill,
                      ),
                      if (pos == null)
                        painterFor(null)
                      else
                        TweenAnimationBuilder<Offset>(
                          tween: Tween<Offset>(begin: pos, end: pos),
                          duration: Duration(milliseconds: animMs),
                          curve: Curves.linear,
                          builder: (context, animated, _) => painterFor(animated),
                        ),
                    ],
                  ),
                ),
              ),
              if (pos != null)
                Positioned(
                  right: 16,
                  bottom: widget.bottomPadding,
                  child: FloatingActionButton.small(
                    heroTag: 'recenter',
                    backgroundColor: Colors.white,
                    foregroundColor: Theme.of(context).colorScheme.primary,
                    elevation: 3,
                    onPressed: _recenter,
                    child: const Icon(Icons.my_location),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
