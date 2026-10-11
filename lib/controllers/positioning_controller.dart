import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/building_config.dart';
import '../models/positioning_state.dart';
import '../services/ble_service.dart';
import '../services/graph_position_service.dart';
import '../services/motion_service.dart';
import '../services/positioning_service.dart';

/// UI-facing wrapper (ChangeNotifier, matching the app's no-extra-library
/// approach) around [PositioningService].
class PositioningController extends ChangeNotifier {
  PositioningController(this.config)
      : service = PositioningService(config: config),
        debugVisible = config.positioning.debug.panelEnabled {
    _sub = service.snapshots.listen((s) {
      snapshot = s;
      notifyListeners();
    });
    service.ble.status.addListener(_onBleStatus);
  }

  final BuildingConfig config;
  final PositioningService service;
  StreamSubscription<PositioningSnapshot>? _sub;
  bool _disposed = false;

  PositioningSnapshot? snapshot;
  bool debugVisible;

  GraphPositionService get graph => service.graph;
  MotionService get motion => service.motion;
  BleStatus get bleStatus => service.ble.status.value;

  void _onBleStatus() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() => service.start();
  Future<void> pause() => service.stop();

  void setRouteHint(Map<String, String> routeNext) =>
      service.setRouteHint(routeNext);

  void toggleDebug() {
    debugVisible = !debugVisible;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    service.ble.status.removeListener(_onBleStatus);
    service.dispose();
    super.dispose();
  }
}
