import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'controllers/direction_beam_controller.dart';
import 'controllers/navigation_controller.dart';
import 'controllers/positioning_controller.dart';
import 'models/building_config.dart';
import 'models/positioning_state.dart';
import 'screens/ble_scanner_page.dart';
import 'screens/destination_search_page.dart';
import 'screens/developer_tools_page.dart';
import 'screens/step_test_page.dart';
import 'services/ble_service.dart';
import 'services/config_service.dart';
import 'widgets/indoor_map.dart';
import 'widgets/positioning_debug_panel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IndoorNavUserApp());
}

class IndoorNavUserApp extends StatelessWidget {
  const IndoorNavUserApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Indoor Navigation',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A73E8),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF4F6FA),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  /// Average indoor walking speed used for the time estimate (m / min).
  static const double _walkMetersPerMinute = 72.0;

  final ConfigService _configService = ConfigService();

  BuildingConfig? config;
  String? error;

  PositioningController? _positioning;
  NavigationController? _navigation;
  DirectionBeamController? _beam;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    try {
      final loaded = await _configService.loadConfig();
      if (!mounted) return;

      final positioning = PositioningController(loaded);
      final navigation = NavigationController(
        config: loaded,
        positioning: positioning,
        configService: _configService,
      );
      final beam = DirectionBeamController(
        config: loaded,
        positioning: positioning,
      );

      setState(() {
        error = null;
        config = loaded;
        _positioning = positioning;
        _navigation = navigation;
        _beam = beam;
      });

      beam.start();
      await positioning.start();
    } catch (e) {
      if (!mounted) return;
      setState(() => error = e.toString());
    }
  }

  /// Scanning and sensors only run while the app is in the foreground.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final p = _positioning;
    if (p == null) return;
    if (state == AppLifecycleState.resumed) {
      p.start();
      _beam?.start();
    } else if (state == AppLifecycleState.paused) {
      p.pause();
      _beam?.stop();
    }
  }

  // ---- hidden developer tools (tap the building name 5 times) --------------
  int _titleTaps = 0;
  DateTime? _lastTitleTap;

  void _onTitleTap() {
    final now = DateTime.now();
    if (_lastTitleTap == null ||
        now.difference(_lastTitleTap!) > const Duration(seconds: 2)) {
      _titleTaps = 0;
    }
    _lastTitleTap = now;
    if (++_titleTaps >= 5) {
      _titleTaps = 0;
      _openDeveloperTools();
    }
  }

  void _openDeveloperTools() {
    final p = _positioning;
    final cfg = config;
    if (p == null || cfg == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (ctx) => DeveloperToolsPage(
          diagnosticsOn: p.debugVisible,
          onToggleDiagnostics: p.toggleDebug,
          onOpenStepTest: () => Navigator.push(
            ctx,
            MaterialPageRoute(
              builder: (_) => StepTestPage(stepDetector: p.motion.stepDetector),
            ),
          ),
          onOpenBleScanner: () async {
            // The scanner page runs its own scan: pause ours meanwhile.
            await p.pause();
            if (!ctx.mounted) return;
            await Navigator.push(
              ctx,
              MaterialPageRoute(builder: (_) => BleScannerPage(config: cfg)),
            );
            await p.start();
          },
        ),
      ),
    );
  }

  // ---- search ----------------------------------------------------------------
  Future<void> _searchDestination() async {
    final cfg = config;
    final nav = _navigation;
    if (cfg == null || nav == null) return;

    final selected = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DestinationSearchPage(config: cfg)),
    );
    if (selected == null) return;

    // Fresh step session for the new trip.
    _positioning?.motion.stepDetector.reset();

    final ok = nav.setDestination(selected);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text("Sorry, directions to ${selected.name} aren't available yet."),
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _beam?.dispose();
    _navigation?.dispose();
    _positioning?.dispose();
    super.dispose();
  }

  // ---- helpers -----------------------------------------------------------------
  Color _markerColor(PositioningState? s) {
    switch (s) {
      case PositioningState.lowConfidence:
      case PositioningState.recovering:
        return Colors.orange;
      case PositioningState.lost:
        return Colors.grey;
      default:
        return const Color(0xFF1A73E8);
    }
  }

  /// Friendly, non-technical status message (or null when everything is fine).
  _Notice? _notice(BleStatus ble, PositioningSnapshot? snap) {
    if (ble == BleStatus.bluetoothOff) {
      return const _Notice(
        Icons.bluetooth_disabled,
        'Turn on Bluetooth to find your location',
        warning: true,
      );
    }
    if (ble == BleStatus.unsupported || ble == BleStatus.error) {
      return const _Notice(
        Icons.location_off_outlined,
        'Location unavailable. Please check Bluetooth and location permission.',
        warning: true,
      );
    }
    if (snap == null || snap.position == null) {
      return const _Notice(Icons.my_location, 'Finding your location…', busy: true);
    }
    switch (snap.state) {
      case PositioningState.lost:
        return const _Notice(Icons.my_location, 'Looking for your location…', busy: true);
      case PositioningState.lowConfidence:
      case PositioningState.recovering:
        return const _Notice(Icons.info_outline, 'Your location may be approximate');
      default:
        return null;
    }
  }

  String _distanceText(double meters) {
    if (meters < 10) return '${meters.round()} m';
    return '${(meters / 5).round() * 5} m';
  }

  String _timeText(double meters) {
    final minutes = meters / _walkMetersPerMinute;
    if (minutes < 1) return 'less than a minute';
    final m = minutes.ceil();
    return m == 1 ? '1 min' : '$m min';
  }

  // ---- build -------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.map_outlined, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                const Text(
                  "We couldn't load the map",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text('Please try again.', style: TextStyle(color: Colors.grey.shade600)),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    setState(() => error = null);
                    _loadConfig();
                  },
                  child: const Text('Try again'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final cfg = config;
    final positioning = _positioning;
    final nav = _navigation;
    if (cfg == null || positioning == null || nav == null) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.navigation_rounded, size: 56, color: cs.primary),
              const SizedBox(height: 20),
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ],
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: Listenable.merge([positioning, nav]),
      builder: (context, _) {
        final snap = positioning.snapshot;
        final notice = _notice(positioning.bleStatus, snap);
        final showTripCard = nav.isNavigating;

        return Scaffold(
          body: Stack(
            children: [
              // MAP
              Positioned.fill(
                child: IndoorMap(
                  config: cfg,
                  graph: positioning.graph,
                  route: nav.route,
                  currentNodeId: snap?.nearestNodeId,
                  currentPosition: snap?.position,
                  markerColor: _markerColor(snap?.state),
                  beam: _beam,
                  bottomPadding: showTripCard ? 190 : 28,
                ),
              ),

              // TOP: search + building name + status
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Column(
                    children: [
                      _SearchPill(onTap: _searchDestination),
                      const SizedBox(height: 8),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: _onTitleTap,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            '${cfg.buildingName} · Floor ${cfg.floor}',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade800,
                            ),
                          ),
                        ),
                      ),
                      if (notice != null && !positioning.debugVisible) ...[
                        const SizedBox(height: 8),
                        _NoticeChip(notice: notice),
                      ],
                      if (positioning.debugVisible) ...[
                        const SizedBox(height: 8),
                        PositioningDebugPanel(snapshot: snap),
                      ],
                    ],
                  ),
                ),
              ),

              // BOTTOM: trip card
              if (showTripCard)
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 12,
                  child: SafeArea(
                    top: false,
                    child: nav.arrived
                        ? _ArrivedCard(
                            name: nav.destinationName ?? 'your destination',
                            onDone: nav.stop,
                          )
                        : _TripCard(
                            name: nav.destinationName ?? '',
                            distance: _distanceText(nav.remainingDistanceMeters),
                            time: _timeText(nav.remainingDistanceMeters),
                            progress: nav.totalDistanceMeters <= 0
                                ? 0.0
                                : (1.0 -
                                        nav.remainingDistanceMeters /
                                            nav.totalDistanceMeters)
                                    .clamp(0.0, 1.0),
                            onEnd: nav.stop,
                          ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ===========================================================================
// UI pieces
// ===========================================================================

class _Notice {
  const _Notice(this.icon, this.text, {this.warning = false, this.busy = false});
  final IconData icon;
  final String text;
  final bool warning;
  final bool busy;
}

class _SearchPill extends StatelessWidget {
  const _SearchPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      elevation: 6,
      shadowColor: Colors.black38,
      borderRadius: BorderRadius.circular(30),
      child: InkWell(
        borderRadius: BorderRadius.circular(30),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
          child: Row(
            children: [
              Icon(Icons.search, color: cs.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Where do you want to go?',
                  style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                ),
              ),
              Icon(Icons.directions_walk, color: Colors.grey.shade500),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeChip extends StatelessWidget {
  const _NoticeChip({required this.notice});
  final _Notice notice;

  @override
  Widget build(BuildContext context) {
    final bg = notice.warning ? const Color(0xFFFFF3E0) : Colors.white;
    final fg = notice.warning ? const Color(0xFFB45309) : Colors.grey.shade800;
    return Material(
      color: bg,
      elevation: 3,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(22),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (notice.busy)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(notice.icon, size: 17, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                notice.text,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TripCard extends StatelessWidget {
  const _TripCard({
    required this.name,
    required this.distance,
    required this.time,
    required this.progress,
    required this.onEnd,
  });

  final String name;
  final String distance;
  final String time;
  final double progress;
  final VoidCallback onEnd;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Colors.white,
      elevation: 10,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 12, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: cs.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(Icons.flag_rounded, color: cs.primary),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$distance · $time walk',
                        style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                      ),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: onEnd,
                  style: TextButton.styleFrom(foregroundColor: Colors.red.shade600),
                  child: const Text('End'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: math.max(0.03, progress),
                  minHeight: 6,
                  backgroundColor: cs.primary.withValues(alpha: 0.12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArrivedCard extends StatelessWidget {
  const _ArrivedCard({required this.name, required this.onDone});
  final String name;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      elevation: 10,
      shadowColor: Colors.black45,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.check_rounded, color: Colors.green, size: 28),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "You've arrived",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
                  ),
                ],
              ),
            ),
            FilledButton(onPressed: onDone, child: const Text('Done')),
          ],
        ),
      ),
    );
  }
}
