import 'dart:async';

import 'package:flutter/material.dart';

import '../services/step_detector_service.dart';

class StepTestPage extends StatefulWidget {
  final StepDetectorService stepDetector;

  const StepTestPage({
    super.key,
    required this.stepDetector,
  });

  @override
  State<StepTestPage> createState() =>
      _StepTestPageState();
}

class _StepTestPageState
    extends State<StepTestPage> {
  StreamSubscription<StepSensorData>?
      _sensorSubscription;

  StreamSubscription<StepAnalysisData>?
      _analysisSubscription;

  // --------------------------------------------------
  // LIVE X Y Z
  // --------------------------------------------------

  double _x = 0.0;

  double _y = 0.0;

  double _z = 0.0;

  double _xy = 0.0;

  // --------------------------------------------------
  // STEP COUNT
  // --------------------------------------------------

  int _stepCount = 0;

  // --------------------------------------------------
  // CURRENT DECISION
  // --------------------------------------------------

  String _status = 'WAITING';

  String _reason =
      'Move the phone to test';

  // --------------------------------------------------
  // LOG
  // --------------------------------------------------

  final List<String> _decisionLogs = [];

  @override
  void initState() {
    super.initState();

    _stepCount =
        widget.stepDetector.stepCount;

    // ------------------------------------------------
    // LIVE SENSOR DATA
    // ------------------------------------------------

    _sensorSubscription =
        widget.stepDetector.sensorData.listen(
      (data) {
        if (!mounted) {
          return;
        }

        setState(() {
          _x = data.x;

          _y = data.y;

          _z = data.z;

          _xy = data.xyMagnitude;
        });
      },
    );

    // ------------------------------------------------
    // DECISION DATA
    // ------------------------------------------------

    _analysisSubscription =
        widget.stepDetector.analysis.listen(
      (data) {
        if (!mounted) {
          return;
        }

        final String log =
            '${data.status} | '
            '${data.reason} | '
            'X=${data.x.toStringAsFixed(2)} | '
            'Y=${data.y.toStringAsFixed(2)} | '
            'Z=${data.z.toStringAsFixed(2)} | '
            'XY=${data.xyMagnitude.toStringAsFixed(2)}';

        setState(() {
          _stepCount =
              data.stepCount;

          _status =
              data.status;

          _reason =
              data.reason;

          _decisionLogs.insert(
            0,
            log,
          );

          if (_decisionLogs.length >
              100) {
            _decisionLogs.removeLast();
          }
        });
      },
    );
  }

  // ==================================================
  // RESET
  // ==================================================

  void _reset() {
    widget.stepDetector.reset();

    setState(() {
      _stepCount = 0;

      _status = 'WAITING';

      _reason =
          'Move the phone to test';

      _decisionLogs.insert(
        0,
        'RESET | Step count reset to 0',
      );
    });
  }

  // ==================================================
  // CLEAR
  // ==================================================

  void _clearLogs() {
    setState(() {
      _decisionLogs.clear();
    });
  }

  // ==================================================
  // DISPOSE
  // ==================================================

  @override
  void dispose() {
    _sensorSubscription?.cancel();

    _analysisSubscription?.cancel();

    super.dispose();
  }

  // ==================================================
  // BUILD
  // ==================================================

  @override
  Widget build(BuildContext context) {
    final bool running =
        widget.stepDetector.isRunning;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Step Sensor Test',
        ),
        actions: [
          IconButton(
            onPressed: _clearLogs,
            icon: const Icon(
              Icons.delete_outline,
            ),
            tooltip: 'Clear Log',
          ),
        ],
      ),
      body: Column(
        children: [
          // ==========================================
          // STEP COUNT
          // ==========================================

          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  const Text(
                    'STEP COUNT',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 5),

                  Text(
                    '$_stepCount',
                    style: const TextStyle(
                      fontSize: 52,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 5),

                  Row(
                    mainAxisAlignment:
                        MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration:
                            BoxDecoration(
                          shape:
                              BoxShape.circle,
                          color: running
                              ? Colors.green
                              : Colors.red,
                        ),
                      ),

                      const SizedBox(
                        width: 8,
                      ),

                      Text(
                        running
                            ? 'RUNNING'
                            : 'STOPPED',
                        style:
                            const TextStyle(
                          fontWeight:
                              FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // ==========================================
          // CURRENT X Y Z
          // ==========================================

          Card(
            margin:
                const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  const Text(
                    'LIVE ACCELEROMETER',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight:
                          FontWeight.bold,
                    ),
                  ),

                  const SizedBox(height: 12),

                  _valueRow(
                    'X',
                    _x,
                  ),

                  const Divider(),

                  _valueRow(
                    'Y',
                    _y,
                  ),

                  const Divider(),

                  _valueRow(
                    'Z',
                    _z,
                  ),

                  const Divider(),

                  _valueRow(
                    'X + Y',
                    _xy,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          // ==========================================
          // CURRENT DECISION
          // ==========================================

          Container(
            width: double.infinity,
            margin:
                const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            padding:
                const EdgeInsets.all(14),
            decoration: BoxDecoration(
              border:
                  Border.all(
                color:
                    _status == 'COUNTED'
                        ? Colors.green
                        : Colors.grey.shade300,
              ),
              borderRadius:
                  BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                const Text(
                  'CURRENT MOVEMENT DECISION',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                const SizedBox(height: 8),

                Text(
                  _status,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight:
                        FontWeight.bold,
                    color:
                        _status == 'COUNTED'
                            ? Colors.green
                            : _status == 'IGNORED'
                                ? Colors.red
                                : Colors.orange,
                  ),
                ),

                const SizedBox(height: 4),

                Text(
                  _reason,
                  textAlign:
                      TextAlign.center,
                  style:
                      const TextStyle(
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // ==========================================
          // BUTTONS
          // ==========================================

          Padding(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            child: Row(
              children: [
                Expanded(
                  child:
                      ElevatedButton.icon(
                    onPressed: _reset,
                    icon:
                        const Icon(
                      Icons.refresh,
                    ),
                    label:
                        const Text(
                      'RESET',
                    ),
                  ),
                ),

                const SizedBox(
                  width: 10,
                ),

                Expanded(
                  child:
                      ElevatedButton.icon(
                    onPressed: () {
                      if (widget
                          .stepDetector
                          .isRunning) {
                        widget
                            .stepDetector
                            .stop();
                      } else {
                        widget
                            .stepDetector
                            .start();
                      }

                      setState(() {});
                    },
                    icon: Icon(
                      running
                          ? Icons.stop
                          : Icons.play_arrow,
                    ),
                    label: Text(
                      running
                          ? 'STOP'
                          : 'START',
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 12),

          // ==========================================
          // DECISION LOG
          // ==========================================

          Padding(
            padding:
                const EdgeInsets.symmetric(
              horizontal: 16,
            ),
            child: Row(
              mainAxisAlignment:
                  MainAxisAlignment
                      .spaceBetween,
              children: [
                const Text(
                  'MOVEMENT LOG',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight:
                        FontWeight.bold,
                  ),
                ),

                Text(
                  '${_decisionLogs.length}',
                  style:
                      const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 6),

          // ==========================================
          // LOG LIST
          // ==========================================

          Expanded(
            child: Container(
              margin:
                  const EdgeInsets.symmetric(
                horizontal: 16,
              ),
              decoration:
                  BoxDecoration(
                border: Border.all(
                  color:
                      Colors.grey.shade300,
                ),
                borderRadius:
                    BorderRadius.circular(
                  10,
                ),
              ),
              child: _decisionLogs.isEmpty
                  ? const Center(
                      child: Text(
                        'No movement detected yet.',
                      ),
                    )
                  : ListView.builder(
                      padding:
                          const EdgeInsets.all(
                        8,
                      ),
                      itemCount:
                          _decisionLogs.length,
                      itemBuilder:
                          (context, index) {
                        final log =
                            _decisionLogs[
                                index];

                        final bool counted =
                            log.startsWith(
                          'COUNTED',
                        );

                        final bool ignored =
                            log.startsWith(
                          'IGNORED',
                        );

                        return Container(
                          margin:
                              const EdgeInsets
                                  .only(
                            bottom: 6,
                          ),
                          padding:
                              const EdgeInsets
                                  .all(
                            10,
                          ),
                          decoration:
                              BoxDecoration(
                            color: counted
                                ? Colors.green
                                    .withValues(alpha: 0.12)
                                : ignored
                                    ? Colors.red
                                        .withValues(alpha: 0.08)
                                    : Colors.grey
                                        .withValues(alpha: 0.08),
                            borderRadius:
                                BorderRadius
                                    .circular(
                              8,
                            ),
                          ),
                          child:
                              Text(
                            log,
                            style:
                                TextStyle(
                              fontSize: 12,
                              fontWeight:
                                  counted
                                      ? FontWeight.bold
                                      : FontWeight
                                          .normal,
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),

          const SizedBox(height: 10),
        ],
      ),
    );
  }

  // ==================================================
  // VALUE ROW
  // ==================================================

  Widget _valueRow(
    String name,
    double value,
  ) {
    return Padding(
      padding:
          const EdgeInsets.symmetric(
        vertical: 5,
      ),
      child: Row(
        mainAxisAlignment:
            MainAxisAlignment.spaceBetween,
        children: [
          Text(
            name,
            style:
                const TextStyle(
              fontSize: 20,
              fontWeight:
                  FontWeight.w500,
            ),
          ),
          Text(
            value.toStringAsFixed(3),
            style:
                const TextStyle(
              fontSize: 20,
              fontWeight:
                FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}