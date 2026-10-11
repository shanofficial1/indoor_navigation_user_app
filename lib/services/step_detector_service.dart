import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import '../models/motion_state.dart';
import '../models/positioning_config.dart';
import '../utils/pos_log.dart';
import '../utils/smoothing_utils.dart';

// ======================================================
// LIVE SENSOR DATA (unchanged API)
// ======================================================

class StepSensorData {
  final double x;
  final double y;
  final double z;
  final double xyMagnitude;
  final double filteredAcceleration;
  final DateTime time;

  StepSensorData({
    required this.x,
    required this.y,
    required this.z,
    required this.xyMagnitude,
    required this.filteredAcceleration,
    required this.time,
  });
}

// ======================================================
// STEP EVENT (extended, backward compatible)
// ======================================================

class StepDetectorEvent {
  final int stepCount;
  final double x;
  final double y;
  final double z;
  final double acceleration;
  final double filteredAcceleration;
  final DateTime time;

  /// Steps per second at the time of this step.
  final double cadenceHz;
  final MotionState state;

  /// 0..1 rhythm regularity.
  final double regularity;

  StepDetectorEvent({
    required this.stepCount,
    required this.x,
    required this.y,
    required this.z,
    required this.acceleration,
    required this.filteredAcceleration,
    required this.time,
    this.cadenceHz = 0.0,
    this.state = MotionState.walking,
    this.regularity = 1.0,
  });
}

// ======================================================
// ANALYSIS / DEBUG EVENT (unchanged API)
// ======================================================

class StepAnalysisData {
  final String status;
  final String reason;

  final double x;
  final double y;
  final double z;

  final double xyMagnitude;
  final double filteredAcceleration;

  final int stepCount;

  final DateTime time;

  StepAnalysisData({
    required this.status,
    required this.reason,
    required this.x,
    required this.y,
    required this.z,
    required this.xyMagnitude,
    required this.filteredAcceleration,
    required this.stepCount,
    required this.time,
  });
}

class _Peak {
  _Peak(this.time, this.raw, this.filtered, this.x, this.y, this.z);
  final DateTime time;
  final double raw;
  final double filtered;
  final double x;
  final double y;
  final double z;
}

class _RawSample {
  _RawSample(this.time, this.value);
  final DateTime time;
  final double value;
}

class _GyroSample {
  _GyroSample(this.time, this.squared);
  final DateTime time;
  final double squared;
}

// ======================================================
// STEP DETECTOR SERVICE
// ======================================================

/// Peak-based step detector with shake rejection and activity classification.
///
/// signal -> time-based low-pass -> local-maximum peak -> checks:
///   amplitude window, min step interval, rhythm regularity, shake (gyro RMS,
///   violent peak, raw peak rate) -> burst confirmation -> counted step.
///
/// All thresholds come from [StepDetectionConfig].
class StepDetectorService {
  StepDetectorService({StepDetectionConfig config = const StepDetectionConfig()})
      : _cfg = config;

  final StepDetectionConfig _cfg;

  StreamSubscription<UserAccelerometerEvent>? _subscription;

  final StreamController<StepSensorData> _sensorController =
      StreamController<StepSensorData>.broadcast();
  final StreamController<StepDetectorEvent> _eventController =
      StreamController<StepDetectorEvent>.broadcast();
  final StreamController<StepAnalysisData> _analysisController =
      StreamController<StepAnalysisData>.broadcast();

  // ---- state -----------------------------------------------------------
  int _stepCount = 0;
  bool _isRunning = false;
  DateTime? _startTime;
  DateTime? _lastStepTime;

  // ---- filter / peak history -------------------------------------------
  double _filtered = 0.0;
  double _prevF = 0.0;
  double _prevPrevF = 0.0;
  double _prevX = 0.0;
  double _prevY = 0.0;
  double _prevZ = 0.0;
  DateTime? _prevTime;
  DateTime? _lastSampleTime;
  DateTime? _lastSensorEmit;

  // ---- burst / rhythm ---------------------------------------------------
  final List<_Peak> _burst = <_Peak>[];
  bool _burstConfirmed = false;
  DateTime? _lastPeakTime;
  final List<double> _intervalsMs = <double>[];
  int _irregularStreak = 0;
  final List<DateTime> _rawPeakTimes = <DateTime>[];
  double _cadenceHz = 0.0;
  double _regularity = 0.0;

  // Recent raw magnitudes: a low-passed peak lags the raw spike, so the real
  // peak amplitude is the raw maximum over a short trailing window.
  final List<_RawSample> _rawHist = <_RawSample>[];
  static const Duration _rawWindow = Duration(milliseconds: 150);

  // ---- shake ---------------------------------------------------------------
  final List<_GyroSample> _gyro = <_GyroSample>[];
  DateTime? _shakeUntil;

  static const Duration _sensorEmitInterval = Duration(milliseconds: 100);
  static const int _maxIntervalHistory = 5;

  // ---- getters (existing API) ------------------------------------------
  int get stepCount => _stepCount;
  bool get isRunning => _isRunning;
  double get filteredAcceleration => _filtered;

  Stream<StepSensorData> get sensorData => _sensorController.stream;
  Stream<StepDetectorEvent> get events => _eventController.stream;
  Stream<StepAnalysisData> get analysis => _analysisController.stream;

  // ---- getters (new) ------------------------------------------------------
  double get cadenceHz => _cadenceHz;
  double get regularity => _regularity;

  bool shakeSuspected(DateTime now) =>
      _shakeUntil != null && now.isBefore(_shakeUntil!);

  /// Activity derived from the step rhythm.
  MotionState stateAt(DateTime now) {
    if (!_isRunning && _startTime == null) return MotionState.unknown;
    final timeout = Duration(milliseconds: _cfg.stationaryTimeoutMs);
    final last = _lastStepTime;
    if (last == null) {
      final start = _startTime;
      if (start != null && now.difference(start) > timeout) {
        return MotionState.stationary;
      }
      return MotionState.unknown;
    }
    if (now.difference(last) > timeout) return MotionState.stationary;
    return _cadenceHz >= _cfg.runningFrequencyMin
        ? MotionState.running
        : MotionState.walking;
  }

  // ======================================================
  // START / STOP
  // ======================================================

  void start() {
    if (_isRunning) return;
    _isRunning = true;
    _startTime = DateTime.now();
    if (!_cfg.enabled) return;

    _subscription = userAccelerometerEventStream(
      samplingPeriod: Duration(milliseconds: _cfg.samplingIntervalMs),
    ).listen(
      (e) => processSample(e.x, e.y, e.z, DateTime.now()),
      onError: (Object error) => PosLog.d('STEP', () => 'sensor error: $error'),
    );
  }

  void stop() {
    _subscription?.cancel();
    _subscription = null;
    _isRunning = false;
  }

  // ======================================================
  // GYRO (shake rejection input)
  // ======================================================

  /// Feed the gyroscope magnitude (rad/s). Sustained high rotation while
  /// "stepping" means the phone is being shaken/twisted, not carried.
  void feedGyro(double magnitudeRadPerSec, DateTime now) {
    _gyro.add(_GyroSample(now, magnitudeRadPerSec * magnitudeRadPerSec));
    final cutoff = now.subtract(Duration(milliseconds: _cfg.shakeWindowMs));
    while (_gyro.isNotEmpty && _gyro.first.time.isBefore(cutoff)) {
      _gyro.removeAt(0);
    }
    if (_gyro.length < 3) return;
    var sum = 0.0;
    for (final g in _gyro) {
      sum += g.squared;
    }
    final rms = math.sqrt(sum / _gyro.length);
    if (rms > _cfg.shakeGyroThresholdRadPerSec) {
      _markShake(now);
    }
  }

  void _markShake(DateTime now) {
    _shakeUntil = now.add(Duration(milliseconds: _cfg.shakeHoldMs));
    _resetBurst();
  }

  // ======================================================
  // ACCELEROMETER
  // ======================================================

  /// Process one user-acceleration sample (gravity removed). Public so the
  /// detector can be driven with synthetic data in tests.
  void processSample(double x, double y, double z, DateTime now) {
    _startTime ??= now;

    final xy = math.sqrt(x * x + y * y);
    final magnitude = _cfg.useXyz ? math.sqrt(x * x + y * y + z * z) : xy;

    // Time-based low-pass: independent of the sensor's actual sample rate.
    final lastT = _lastSampleTime;
    var dtMs = lastT == null
        ? _cfg.samplingIntervalMs.toDouble()
        : now.difference(lastT).inMicroseconds / 1000.0;
    dtMs = dtMs.clamp(1.0, 250.0).toDouble();
    _lastSampleTime = now;
    final alpha = dtMs / (_cfg.filterTimeConstantMs + dtMs);
    _filtered += alpha * (magnitude - _filtered);

    // Throttled live data for the test page.
    final lastEmit = _lastSensorEmit;
    if ((lastEmit == null || now.difference(lastEmit) >= _sensorEmitInterval) &&
        !_sensorController.isClosed) {
      _lastSensorEmit = now;
      _sensorController.add(StepSensorData(
        x: x,
        y: y,
        z: z,
        xyMagnitude: magnitude,
        filteredAcceleration: _filtered,
        time: now,
      ));
    }

    _rawHist.add(_RawSample(now, magnitude));
    final rawCutoff = now.subtract(_rawWindow);
    while (_rawHist.isNotEmpty && _rawHist.first.time.isBefore(rawCutoff)) {
      _rawHist.removeAt(0);
    }
    var rawMax = magnitude;
    for (final r in _rawHist) {
      if (r.value > rawMax) rawMax = r.value;
    }

    // Local maximum of the filtered signal: the PREVIOUS sample is the peak.
    final isPeak = _prevF > _cfg.minimumFilteredPeak &&
        _prevF > _prevPrevF &&
        _prevF > _filtered;

    final peak = _Peak(_prevTime ?? now, rawMax, _prevF, _prevX, _prevY, _prevZ);

    _prevPrevF = _prevF;
    _prevF = _filtered;
    _prevX = x;
    _prevY = y;
    _prevZ = z;
    _prevTime = now;

    if (isPeak) _onPeak(peak);
  }

  // ======================================================
  // PEAK HANDLING
  // ======================================================

  void _onPeak(_Peak p) {
    final t = p.time;

    // --- shake: raw peak rate (counts every candidate peak) ---------------
    _rawPeakTimes.add(t);
    final windowStart = t.subtract(const Duration(seconds: 1));
    while (_rawPeakTimes.isNotEmpty && _rawPeakTimes.first.isBefore(windowStart)) {
      _rawPeakTimes.removeAt(0);
    }
    if (_rawPeakTimes.length > _cfg.maxRawPeakRateHz) {
      _markShake(t);
      _analyse('IGNORED', 'SHAKE (PEAK RATE ${_rawPeakTimes.length}/s)', p);
      return;
    }

    if (shakeSuspected(t)) {
      _resetBurst();
      _analyse('IGNORED', 'SHAKE (GYRO)', p);
      return;
    }

    if (p.raw < _cfg.minimumRawPeak) {
      _analyse('IGNORED', 'TOO SMALL', p);
      return;
    }

    if (p.raw > _cfg.maximumPeak) {
      _markShake(t);
      _analyse('IGNORED', 'TOO LARGE (SHAKE)', p);
      return;
    }

    // --- interval to the previous ACCEPTED peak ---------------------------
    final last = _lastPeakTime;
    if (last != null) {
      final intervalMs = t.difference(last).inMicroseconds / 1000.0;

      if (intervalMs < _cfg.minimumStepIntervalMs) {
        _analyse('IGNORED', 'TOO FAST (${intervalMs.round()} ms)', p);
        return;
      }

      if (intervalMs > _cfg.maximumStepIntervalMs) {
        // Pause in the rhythm: this peak starts a fresh candidate burst.
        _analyse('IGNORED', 'TOO SLOW (${intervalMs.round()} ms)', p);
        _startBurst(p);
        return;
      }

      // --- rhythm regularity ----------------------------------------------
      if (_intervalsMs.length >= 2) {
        final med = median(_intervalsMs);
        if ((intervalMs - med).abs() > _cfg.regularityTolerance * med) {
          _irregularStreak++;
          _lastPeakTime = t; // the peak did happen; keep timing continuous
          _analyse('IGNORED', 'IRREGULAR RHYTHM (${intervalMs.round()} ms)', p);
          if (_irregularStreak >= _cfg.maxIrregularInRow) {
            _resetBurst();
          }
          return;
        }
      }
      _irregularStreak = 0;
      _intervalsMs.add(intervalMs);
      while (_intervalsMs.length > _maxIntervalHistory) {
        _intervalsMs.removeAt(0);
      }
      _updateRhythm();
    } else {
      // Very first peak.
      _startBurst(p);
      return;
    }

    _lastPeakTime = t;
    _burst.add(p);

    if (!_burstConfirmed) {
      // Need (confirmationSteps + 1) peaks with regular spacing before any step
      // is counted: a lone bump or a short shake therefore counts nothing.
      if (_burst.length >= _cfg.confirmationSteps + 1) {
        _burstConfirmed = true;
        for (final bp in _burst) {
          _registerStep(bp);
        }
        _burst.clear();
      } else {
        _analyse('CANDIDATE', 'WAITING FOR RHYTHM (${_burst.length})', p);
      }
      return;
    }

    _analyse('VALID', 'NORMAL MOVEMENT', p);
    _registerStep(p);
  }

  void _startBurst(_Peak p) {
    _burst
      ..clear()
      ..add(p);
    _burstConfirmed = false;
    _intervalsMs.clear();
    _irregularStreak = 0;
    _lastPeakTime = p.time;
    _analyse('CANDIDATE', 'WAITING FOR NEXT MOVEMENT', p);
  }

  void _resetBurst() {
    _burst.clear();
    _burstConfirmed = false;
    _intervalsMs.clear();
    _irregularStreak = 0;
    _lastPeakTime = null;
    _regularity = 0.0;
  }

  void _updateRhythm() {
    if (_intervalsMs.isEmpty) return;
    final med = median(_intervalsMs);
    _cadenceHz = med > 0 ? 1000.0 / med : 0.0;
    if (_intervalsMs.length >= 3) {
      final cv = stdDev(_intervalsMs) / (mean(_intervalsMs));
      _regularity = (1.0 - cv / 0.35).clamp(0.0, 1.0).toDouble();
    } else {
      _regularity = 0.6;
    }
  }

  void _registerStep(_Peak p) {
    _lastStepTime = p.time;
    _stepCount++;

    final state = _cadenceHz >= _cfg.runningFrequencyMin
        ? MotionState.running
        : MotionState.walking;

    _analyse('COUNTED', 'STEP COUNTED', p);
    PosLog.d(
      'MOTION',
      () => 'state=${state.name} step=$_stepCount '
          'cadence=${_cadenceHz.toStringAsFixed(2)}Hz '
          'regularity=${_regularity.toStringAsFixed(2)}',
    );

    if (!_eventController.isClosed) {
      _eventController.add(StepDetectorEvent(
        stepCount: _stepCount,
        x: p.x,
        y: p.y,
        z: p.z,
        acceleration: p.raw,
        filteredAcceleration: p.filtered,
        time: p.time,
        cadenceHz: _cadenceHz,
        state: state,
        regularity: _regularity,
      ));
    }
  }

  void _analyse(String status, String reason, _Peak p) {
    if (_analysisController.isClosed) return;
    _analysisController.add(StepAnalysisData(
      status: status,
      reason: reason,
      x: p.x,
      y: p.y,
      z: p.z,
      xyMagnitude: p.raw,
      filteredAcceleration: p.filtered,
      stepCount: _stepCount,
      time: p.time,
    ));
  }

  // ======================================================
  // RESET / DISPOSE
  // ======================================================

  void reset() {
    _stepCount = 0;
    _lastStepTime = null;
    _lastSensorEmit = null;
    _filtered = 0.0;
    _prevPrevF = 0.0;
    _prevF = 0.0;
    _prevX = 0.0;
    _prevY = 0.0;
    _prevZ = 0.0;
    _prevTime = null;
    _lastSampleTime = null;
    _cadenceHz = 0.0;
    _rawPeakTimes.clear();
    _rawHist.clear();
    _gyro.clear();
    _shakeUntil = null;
    _resetBurst();
    PosLog.d('STEP', () => 'reset');
  }

  void dispose() {
    stop();
    if (!_sensorController.isClosed) _sensorController.close();
    if (!_eventController.isClosed) _eventController.close();
    if (!_analysisController.isClosed) _analysisController.close();
  }
}
