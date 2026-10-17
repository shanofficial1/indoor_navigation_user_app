import 'dart:math' as math;

// ============================================================================
// Centralised positioning configuration.
//
// Every tunable of the positioning engine lives here. Each section can be
// supplied (all or in part) in the building JSON; anything missing or of the
// wrong type silently falls back to the default declared in the const
// constructor, so OLD JSON FILES KEEP WORKING.
// ============================================================================

double _d(Map<String, dynamic>? j, String k, double def) {
  final v = j?[k];
  return v is num ? v.toDouble() : def;
}

int _i(Map<String, dynamic>? j, String k, int def) {
  final v = j?[k];
  return v is num ? v.round() : def;
}

bool _b(Map<String, dynamic>? j, String k, bool def) {
  final v = j?[k];
  return v is bool ? v : def;
}

String? _s(Map<String, dynamic>? j, String k) {
  final v = j?[k];
  return v is String ? v : null;
}

Map<String, dynamic>? _m(dynamic v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

double _cl(double v, double lo, double hi) => v < lo ? lo : (v > hi ? hi : v);

// ----------------------------------------------------------------------------
// RSSI filter  ("rssiFilter")
// ----------------------------------------------------------------------------

enum RssiFilterMode { movingAverage, ema, movingAverageEma }

class RssiFilterConfig {
  const RssiFilterConfig({
    this.enabled = true,
    this.windowSize = 5,
    this.emaAlpha = 0.25,
    this.outlierThresholdDb = 10.0,
    this.outlierMaxConsecutive = 3,
    this.mode = RssiFilterMode.movingAverageEma,
  });

  /// false => raw RSSI is passed straight through.
  final bool enabled;
  final int windowSize;
  final double emaAlpha;

  /// A sample further than this (dB) from the window median is an outlier.
  final double outlierThresholdDb;

  /// After this many consecutive "outliers" the change is treated as real
  /// (the user actually moved) and the window restarts.
  final int outlierMaxConsecutive;
  final RssiFilterMode mode;

  factory RssiFilterConfig.fromJson(Map<String, dynamic>? j) {
    const d = RssiFilterConfig();
    RssiFilterMode mode = d.mode;
    switch (_s(j, 'mode')) {
      case 'movingAverage':
        mode = RssiFilterMode.movingAverage;
        break;
      case 'ema':
        mode = RssiFilterMode.ema;
        break;
      case 'movingAverageEma':
        mode = RssiFilterMode.movingAverageEma;
        break;
    }
    return RssiFilterConfig(
      enabled: _b(j, 'enabled', d.enabled),
      windowSize: math.max(1, _i(j, 'windowSize', d.windowSize)),
      emaAlpha: _cl(_d(j, 'emaAlpha', d.emaAlpha), 0.01, 1.0),
      outlierThresholdDb: _d(j, 'outlierThreshold', d.outlierThresholdDb),
      outlierMaxConsecutive:
          math.max(1, _i(j, 'outlierMaxConsecutive', d.outlierMaxConsecutive)),
      mode: mode,
    );
  }
}

// ----------------------------------------------------------------------------
// Distance model  ("distanceModel")
// ----------------------------------------------------------------------------

class DistanceModelConfig {
  const DistanceModelConfig({
    this.pathLossExponent = 2.0,
    this.referenceDistanceMeters = 1.0,
    this.defaultTxPower = -59.0,
    this.minDistanceMeters = 0.2,
    this.maxDistanceMeters = 40.0,
  });

  /// "n" in  d = d0 * 10^((txPower - rssi) / (10 n)).
  final double pathLossExponent;
  final double referenceDistanceMeters;

  /// Used when a beacon has no calibrated txPower of its own.
  final double defaultTxPower;
  final double minDistanceMeters;
  final double maxDistanceMeters;

  factory DistanceModelConfig.fromJson(Map<String, dynamic>? j) {
    const d = DistanceModelConfig();
    return DistanceModelConfig(
      pathLossExponent:
          math.max(0.5, _d(j, 'pathLossExponent', d.pathLossExponent)),
      referenceDistanceMeters: math.max(
          0.1, _d(j, 'referenceDistanceMeters', d.referenceDistanceMeters)),
      defaultTxPower: _d(j, 'defaultTxPower', d.defaultTxPower),
      minDistanceMeters: _d(j, 'minDistanceMeters', d.minDistanceMeters),
      maxDistanceMeters: _d(j, 'maxDistanceMeters', d.maxDistanceMeters),
    );
  }
}

// ----------------------------------------------------------------------------
// BLE layer  ("ble")
// ----------------------------------------------------------------------------

class BleConfig {
  const BleConfig({
    this.measurementTimeoutMs = 2000,
    this.beaconTimeoutMs = 4000,
    this.scanRestartBackoffMs = 5000,
    this.autoRestartScan = true,
  });

  /// A beacon measurement older than this is stale and ignored.
  final int measurementTimeoutMs;

  /// Filter state for a beacon is dropped after this much silence.
  final int beaconTimeoutMs;

  /// Minimum gap between scanner restarts (Android throttles rapid restarts).
  final int scanRestartBackoffMs;
  final bool autoRestartScan;

  factory BleConfig.fromJson(Map<String, dynamic>? j) {
    const d = BleConfig();
    final measurement =
        math.max(200, _i(j, 'measurementTimeoutMs', d.measurementTimeoutMs));
    return BleConfig(
      measurementTimeoutMs: measurement,
      beaconTimeoutMs:
          math.max(measurement, _i(j, 'beaconTimeoutMs', d.beaconTimeoutMs)),
      scanRestartBackoffMs:
          math.max(1000, _i(j, 'scanRestartBackoffMs', d.scanRestartBackoffMs)),
      autoRestartScan: _b(j, 'autoRestartScan', d.autoRestartScan),
    );
  }
}

// ----------------------------------------------------------------------------
// Positioning engine  ("positioning")
// ----------------------------------------------------------------------------

class PositioningParams {
  const PositioningParams({
    // --- beacon selection ---------------------------------------------------
    this.minimumBeacons = 2,
    this.preferredBeacons = 3,
    this.maximumBeacons = 5,
    this.singleBeaconProximityMeters = 2.0,
    this.maxUsableDistanceMeters = 15.0,
    this.selectionRssiWeight = 0.30,
    this.selectionStabilityWeight = 0.25,
    this.selectionFreshnessWeight = 0.15,
    this.selectionConsistencyWeight = 0.30,
    this.rssiStabilityScaleDb = 6.0,
    this.consistencyScaleMeters = 4.0,
    // --- BLE position estimate ----------------------------------------------
    this.sampleStepMeters = 0.25,
    this.ratioConsistencyTolerance = 0.35,
    this.maxResidualMeters = 4.0,
    this.ambiguityScaleMeters = 3.0,
    this.ambiguityCostMargin = 1.5,
    this.priorWeight = 0.02,
    // --- fusion ---------------------------------------------------------------
    this.fusionIntervalMs = 200,
    this.bleConfidence = 0.8,
    this.pdrConfidence = 0.7,
    this.pdrDriftScaleMeters = 15.0,
    this.minimumFixConfidence = 0.15,
    this.bleDeadbandMeters = 0.5,
    this.stationaryHoldRadiusMeters = 1.2,
    this.correctionTimeConstantMs = 1500,
    this.stationaryCorrectionScale = 3.0,
    this.maxCorrectionSpeedMps = 1.0,
    this.maxSpeedMps = 4.5,
    this.lostTimeoutMs = 6000,
    this.lowConfidenceThreshold = 0.35,
    this.recoveryTeleportMeters = 8.0,
    // --- graph ----------------------------------------------------------------
    this.graphSnapDistanceMeters = 3.0,
    this.graphTransitionThresholdMeters = 1.0,
    this.arrivalRadiusMeters = 2.0,
  });

  final int minimumBeacons;
  final int preferredBeacons;
  final int maximumBeacons;

  /// With fewer than [minimumBeacons] visible, a single beacon still gives a
  /// (low-confidence) "proximity" fix if the user is this close to it.
  final double singleBeaconProximityMeters;

  /// Ranges beyond this are too unreliable to use at all.
  final double maxUsableDistanceMeters;

  // Beacon ranking weights (rssi strength / stability / freshness / agreement
  // with the current position). They need not sum to 1.
  final double selectionRssiWeight;
  final double selectionStabilityWeight;
  final double selectionFreshnessWeight;
  final double selectionConsistencyWeight;
  final double rssiStabilityScaleDb;
  final double consistencyScaleMeters;

  /// Resolution of the graph search for the BLE fix.
  final double sampleStepMeters;

  /// Two-beacon ratio method is used only if dA + dB is within this fraction
  /// of the beacon-to-beacon path length (i.e. user plausibly between them).
  final double ratioConsistencyTolerance;

  /// RMS range residual above which a BLE candidate is rejected as inconsistent.
  final double maxResidualMeters;
  final double ambiguityScaleMeters;
  final double ambiguityCostMargin;

  /// Small pull towards the current position when the fix is ambiguous.
  final double priorWeight;

  final int fusionIntervalMs;

  /// Base confidence (0..1) of a perfect BLE fix / of fresh PDR.
  final double bleConfidence;
  final double pdrConfidence;

  /// PDR confidence falls by 1/e every this many metres walked without BLE.
  final double pdrDriftScaleMeters;
  final double minimumFixConfidence;

  /// BLE disagreement smaller than this is ignored (stops marker jitter).
  final double bleDeadbandMeters;

  /// Same, but while the user is stationary ("position hold").
  final double stationaryHoldRadiusMeters;

  /// How quickly the fused position is pulled towards an accepted BLE target.
  final int correctionTimeConstantMs;
  final double stationaryCorrectionScale;
  final double maxCorrectionSpeedMps;

  /// Physically plausible maximum speed of the displayed position.
  final double maxSpeedMps;
  final int lostTimeoutMs;
  final double lowConfidenceThreshold;

  /// After being LOST, a confirmed BLE fix further than this snaps instead of
  /// being blended in (the dead-reckoned position is presumed wrong).
  final double recoveryTeleportMeters;

  final double graphSnapDistanceMeters;

  /// A turn is only recognised this close to a graph node.
  final double graphTransitionThresholdMeters;
  final double arrivalRadiusMeters;

  factory PositioningParams.fromJson(Map<String, dynamic>? j) {
    const d = PositioningParams();
    final minB = math.max(1, _i(j, 'minimumBeacons', d.minimumBeacons));
    final prefB = math.max(minB, _i(j, 'preferredBeacons', d.preferredBeacons));
    final maxB = math.max(prefB, _i(j, 'maximumBeacons', d.maximumBeacons));
    return PositioningParams(
      minimumBeacons: minB,
      preferredBeacons: prefB,
      maximumBeacons: maxB,
      singleBeaconProximityMeters: _d(
          j, 'singleBeaconProximityMeters', d.singleBeaconProximityMeters),
      maxUsableDistanceMeters:
          _d(j, 'maxUsableDistanceMeters', d.maxUsableDistanceMeters),
      selectionRssiWeight: _d(j, 'selectionRssiWeight', d.selectionRssiWeight),
      selectionStabilityWeight:
          _d(j, 'selectionStabilityWeight', d.selectionStabilityWeight),
      selectionFreshnessWeight:
          _d(j, 'selectionFreshnessWeight', d.selectionFreshnessWeight),
      selectionConsistencyWeight:
          _d(j, 'selectionConsistencyWeight', d.selectionConsistencyWeight),
      rssiStabilityScaleDb:
          math.max(0.5, _d(j, 'rssiStabilityScaleDb', d.rssiStabilityScaleDb)),
      consistencyScaleMeters: math.max(
          0.5, _d(j, 'consistencyScaleMeters', d.consistencyScaleMeters)),
      sampleStepMeters:
          math.max(0.05, _d(j, 'sampleStepMeters', d.sampleStepMeters)),
      ratioConsistencyTolerance:
          _d(j, 'ratioConsistencyTolerance', d.ratioConsistencyTolerance),
      maxResidualMeters:
          math.max(0.5, _d(j, 'maxResidualMeters', d.maxResidualMeters)),
      ambiguityScaleMeters:
          math.max(0.1, _d(j, 'ambiguityScaleMeters', d.ambiguityScaleMeters)),
      ambiguityCostMargin:
          _d(j, 'ambiguityCostMargin', d.ambiguityCostMargin),
      priorWeight: _d(j, 'priorWeight', d.priorWeight),
      fusionIntervalMs:
          math.max(50, _i(j, 'fusionIntervalMs', d.fusionIntervalMs)),
      bleConfidence: _cl(_d(j, 'bleConfidence', d.bleConfidence), 0.0, 1.0),
      pdrConfidence: _cl(_d(j, 'pdrConfidence', d.pdrConfidence), 0.0, 1.0),
      pdrDriftScaleMeters:
          math.max(1.0, _d(j, 'pdrDriftScaleMeters', d.pdrDriftScaleMeters)),
      minimumFixConfidence:
          _d(j, 'minimumFixConfidence', d.minimumFixConfidence),
      bleDeadbandMeters: _d(j, 'bleDeadbandMeters', d.bleDeadbandMeters),
      stationaryHoldRadiusMeters:
          _d(j, 'stationaryHoldRadiusMeters', d.stationaryHoldRadiusMeters),
      correctionTimeConstantMs: math.max(
          100, _i(j, 'correctionTimeConstantMs', d.correctionTimeConstantMs)),
      stationaryCorrectionScale:
          _d(j, 'stationaryCorrectionScale', d.stationaryCorrectionScale),
      maxCorrectionSpeedMps:
          _d(j, 'maxCorrectionSpeedMps', d.maxCorrectionSpeedMps),
      maxSpeedMps: math.max(0.5,
          _d(j, 'maximumSpeedMetersPerSecond', _d(j, 'maxSpeedMps', d.maxSpeedMps))),
      lostTimeoutMs: math.max(1000, _i(j, 'lostTimeoutMs', d.lostTimeoutMs)),
      lowConfidenceThreshold:
          _d(j, 'lowConfidenceThreshold', d.lowConfidenceThreshold),
      recoveryTeleportMeters:
          _d(j, 'recoveryTeleportMeters', d.recoveryTeleportMeters),
      graphSnapDistanceMeters:
          _d(j, 'graphSnapDistanceMeters', d.graphSnapDistanceMeters),
      graphTransitionThresholdMeters: _d(
          j, 'graphTransitionThresholdMeters', d.graphTransitionThresholdMeters),
      arrivalRadiusMeters:
          _d(j, 'arrivalRadiusMeters', d.arrivalRadiusMeters),
    );
  }
}

// ----------------------------------------------------------------------------
// Temporal confirmation / smoothing  ("positionSmoothing")
// ----------------------------------------------------------------------------

class PositionSmoothingConfig {
  const PositionSmoothingConfig({
    this.confirmationDurationMs = 1500,
    this.confirmationMinSamples = 3,
    this.maxJumpMeters = 1.5,
    this.confirmationRadiusMeters = 1.5,
    this.displayAnimationMs = 250,
  });

  /// A BLE candidate farther than [maxJumpMeters] from the current position
  /// must stay consistent for this long before it is accepted.
  final int confirmationDurationMs;
  final int confirmationMinSamples;
  final double maxJumpMeters;

  /// Successive candidates within this radius count as "the same" candidate.
  final double confirmationRadiusMeters;

  /// Length of the UI marker tween between two position updates.
  final int displayAnimationMs;

  factory PositionSmoothingConfig.fromJson(Map<String, dynamic>? j) {
    const d = PositionSmoothingConfig();
    return PositionSmoothingConfig(
      confirmationDurationMs:
          math.max(0, _i(j, 'confirmationDurationMs', d.confirmationDurationMs)),
      confirmationMinSamples:
          math.max(1, _i(j, 'confirmationMinSamples', d.confirmationMinSamples)),
      maxJumpMeters: math.max(0.1, _d(j, 'maxJumpMeters', d.maxJumpMeters)),
      confirmationRadiusMeters: math.max(
          0.1, _d(j, 'confirmationRadiusMeters', d.confirmationRadiusMeters)),
      displayAnimationMs:
          math.max(0, _i(j, 'displayAnimationMs', d.displayAnimationMs)),
    );
  }
}

// ----------------------------------------------------------------------------
// Motion  ("motion")
// ----------------------------------------------------------------------------

class StepDetectionConfig {
  const StepDetectionConfig({
    this.enabled = true,
    this.useXyz = false,
    this.samplingIntervalMs = 20,
    this.filterTimeConstantMs = 50,
    this.minimumRawPeak = 1.5,
    this.minimumFilteredPeak = 1.2,
    this.maximumPeak = 12.0,
    this.minimumStepIntervalMs = 300,
    this.maximumStepIntervalMs = 1200,
    this.walkingFrequencyMin = 1.0,
    this.walkingFrequencyMax = 2.5,
    this.runningFrequencyMin = 2.5,
    this.regularityTolerance = 0.45,
    this.confirmationSteps = 2,
    this.maxIrregularInRow = 3,
    this.maxRawPeakRateHz = 7.0,
    this.stationaryTimeoutMs = 1500,
    this.shakeGyroThresholdRadPerSec = 6.0,
    this.shakeWindowMs = 500,
    this.shakeHoldMs = 800,
  });

  final bool enabled;

  /// false: |(x, y)| of user-acceleration (the project's original signal);
  /// true: |(x, y, z)|, orientation independent.
  final bool useXyz;

  /// Accelerometer sampling period. 20 ms (50 Hz) is needed to resolve running
  /// cadence; the plugin default (200 ms) is far too slow.
  final int samplingIntervalMs;
  final int filterTimeConstantMs;
  final double minimumRawPeak;
  final double minimumFilteredPeak;

  /// Peaks above this are violent shaking, not walking.
  final double maximumPeak;
  final int minimumStepIntervalMs;
  final int maximumStepIntervalMs;
  final double walkingFrequencyMin;
  final double walkingFrequencyMax;
  final double runningFrequencyMin;

  /// An interval deviating more than this fraction from the recent median
  /// breaks the walking rhythm.
  final double regularityTolerance;

  /// Number of regular intervals needed before the first steps are counted.
  /// (Stops one-off bumps and short shakes being counted at all.)
  final int confirmationSteps;
  final int maxIrregularInRow;
  final double maxRawPeakRateHz;
  final int stationaryTimeoutMs;

  /// RMS gyroscope magnitude (rad/s) over [shakeWindowMs] above which the
  /// phone is being shaken/twisted rather than carried.
  final double shakeGyroThresholdRadPerSec;
  final int shakeWindowMs;
  final int shakeHoldMs;

  factory StepDetectionConfig.fromJson(Map<String, dynamic>? j) {
    const d = StepDetectionConfig();
    return StepDetectionConfig(
      enabled: _b(j, 'enabled', d.enabled),
      useXyz: (_s(j, 'signal') ?? (d.useXyz ? 'xyz' : 'xy')) == 'xyz',
      samplingIntervalMs:
          math.max(5, _i(j, 'samplingIntervalMs', d.samplingIntervalMs)),
      filterTimeConstantMs:
          math.max(1, _i(j, 'filterTimeConstantMs', d.filterTimeConstantMs)),
      minimumRawPeak: _d(j, 'minimumRawPeak', d.minimumRawPeak),
      minimumFilteredPeak:
          _d(j, 'minimumFilteredPeak', d.minimumFilteredPeak),
      maximumPeak: _d(j, 'maximumPeak', d.maximumPeak),
      minimumStepIntervalMs:
          math.max(50, _i(j, 'minimumStepIntervalMs', d.minimumStepIntervalMs)),
      maximumStepIntervalMs:
          math.max(200, _i(j, 'maximumStepIntervalMs', d.maximumStepIntervalMs)),
      walkingFrequencyMin:
          _d(j, 'walkingFrequencyMin', d.walkingFrequencyMin),
      walkingFrequencyMax:
          _d(j, 'walkingFrequencyMax', d.walkingFrequencyMax),
      runningFrequencyMin:
          _d(j, 'runningFrequencyMin', d.runningFrequencyMin),
      regularityTolerance:
          _d(j, 'regularityTolerance', d.regularityTolerance),
      confirmationSteps:
          math.max(1, _i(j, 'confirmationSteps', d.confirmationSteps)),
      maxIrregularInRow:
          math.max(1, _i(j, 'maxIrregularInRow', d.maxIrregularInRow)),
      maxRawPeakRateHz: _d(j, 'maxRawPeakRateHz', d.maxRawPeakRateHz),
      stationaryTimeoutMs:
          math.max(500, _i(j, 'stationaryTimeoutMs', d.stationaryTimeoutMs)),
      shakeGyroThresholdRadPerSec: _d(
          j, 'shakeGyroThresholdRadPerSec', d.shakeGyroThresholdRadPerSec),
      shakeWindowMs: math.max(100, _i(j, 'shakeWindowMs', d.shakeWindowMs)),
      shakeHoldMs: math.max(0, _i(j, 'shakeHoldMs', d.shakeHoldMs)),
    );
  }
}

class StepLengthConfig {
  const StepLengthConfig({
    this.walkingMeters = 0.65,
    this.runningMeters = 1.0,
  });

  final double walkingMeters;
  final double runningMeters;

  factory StepLengthConfig.fromJson(Map<String, dynamic>? j) {
    const d = StepLengthConfig();
    return StepLengthConfig(
      walkingMeters:
          math.max(0.2, _d(j, 'walkingStepLength', d.walkingMeters)),
      runningMeters:
          math.max(0.2, _d(j, 'runningStepLength', d.runningMeters)),
    );
  }
}

class HeadingConfig {
  const HeadingConfig({
    this.samplingIntervalMs = 30,
    this.magCorrectionPerSecond = 0.5,
    this.mapNorthOffsetDegrees,
    this.turnRateThresholdDegPerSec = 35.0,
    this.minFieldMicroTesla = 20.0,
    this.maxFieldMicroTesla = 70.0,
    this.directionHysteresis = 0.3,
    this.minimumConfidence = 0.4,
  });

  final int samplingIntervalMs;

  /// Complementary-filter gain pulling the gyro heading to the magnetometer.
  final double magCorrectionPerSecond;

  /// Map orientation. Defined by:  mapBearing = compassHeading + offset,
  /// i.e. the bearing, in degrees clockwise from the map's "up" direction,
  /// at which compass NORTH points on the floor-plan image.
  ///   map "up" is north            ->   0
  ///   map "up" is east  (north is to the left)   -> -90 (or 270)
  ///   map "up" is south (north is down)          -> 180
  /// Also accepted as  map.northOffsetDegrees  in the JSON.
  /// null => learned online from BLE progress along edges.
  final double? mapNorthOffsetDegrees;
  final double turnRateThresholdDegPerSec;

  /// Magnetometer readings outside this magnitude band are distrusted.
  final double minFieldMicroTesla;
  final double maxFieldMicroTesla;

  /// |cos| of heading-vs-edge angle needed to decide the walking direction.
  final double directionHysteresis;
  final double minimumConfidence;

  factory HeadingConfig.fromJson(Map<String, dynamic>? j) {
    const d = HeadingConfig();
    final off = j?['mapNorthOffsetDegrees'];
    return HeadingConfig(
      samplingIntervalMs:
          math.max(5, _i(j, 'samplingIntervalMs', d.samplingIntervalMs)),
      magCorrectionPerSecond:
          _d(j, 'magCorrectionPerSecond', d.magCorrectionPerSecond),
      mapNorthOffsetDegrees: off is num ? off.toDouble() : null,
      turnRateThresholdDegPerSec: _d(
          j, 'turnRateThresholdDegPerSec', d.turnRateThresholdDegPerSec),
      minFieldMicroTesla: _d(j, 'minFieldMicroTesla', d.minFieldMicroTesla),
      maxFieldMicroTesla: _d(j, 'maxFieldMicroTesla', d.maxFieldMicroTesla),
      directionHysteresis:
          _d(j, 'directionHysteresis', d.directionHysteresis),
      minimumConfidence: _d(j, 'minimumConfidence', d.minimumConfidence),
    );
  }
}

class MotionConfig {
  const MotionConfig({
    this.stepDetection = const StepDetectionConfig(),
    this.stepLength = const StepLengthConfig(),
    this.heading = const HeadingConfig(),
  });

  final StepDetectionConfig stepDetection;
  final StepLengthConfig stepLength;
  final HeadingConfig heading;

  /// Same config with the map orientation set (used for the map-block alias).
  MotionConfig withMapNorthOffset(double degrees) => MotionConfig(
        stepDetection: stepDetection,
        stepLength: stepLength,
        heading: HeadingConfig(
          samplingIntervalMs: heading.samplingIntervalMs,
          magCorrectionPerSecond: heading.magCorrectionPerSecond,
          mapNorthOffsetDegrees: degrees,
          turnRateThresholdDegPerSec: heading.turnRateThresholdDegPerSec,
          minFieldMicroTesla: heading.minFieldMicroTesla,
          maxFieldMicroTesla: heading.maxFieldMicroTesla,
          directionHysteresis: heading.directionHysteresis,
          minimumConfidence: heading.minimumConfidence,
        ),
      );

  factory MotionConfig.fromJson(Map<String, dynamic>? j) {
    return MotionConfig(
      stepDetection: StepDetectionConfig.fromJson(_m(j?['stepDetection'])),
      stepLength: StepLengthConfig.fromJson(_m(j?['stepLength'])),
      heading: HeadingConfig.fromJson(_m(j?['heading'])),
    );
  }
}

// ----------------------------------------------------------------------------
// Debug  ("debug")
// ----------------------------------------------------------------------------

class DebugConfig {
  const DebugConfig({
    this.panelEnabled = false,
    this.logging = false,
    this.recording = false,
  });

  /// Show the diagnostics panel when the app starts.
  final bool panelEnabled;

  /// Print structured [BLE]/[MOTION]/[FUSION]/[POSITION] logs.
  final bool logging;

  /// Emit one compact JSON line per fusion tick (`[REC] {...}` in logcat) so a
  /// walk can be replayed offline with ReplayRunner and the parameters tuned.
  final bool recording;

  factory DebugConfig.fromJson(Map<String, dynamic>? j) {
    const d = DebugConfig();
    return DebugConfig(
      panelEnabled: _b(j, 'enabled', d.panelEnabled),
      logging: _b(j, 'logging', d.logging),
      recording: _b(j, 'recording', d.recording),
    );
  }
}

// ----------------------------------------------------------------------------
// Root
// ----------------------------------------------------------------------------

class PositioningConfig {
  const PositioningConfig({
    this.rssiFilter = const RssiFilterConfig(),
    this.distanceModel = const DistanceModelConfig(),
    this.ble = const BleConfig(),
    this.params = const PositioningParams(),
    this.smoothing = const PositionSmoothingConfig(),
    this.motion = const MotionConfig(),
    this.debug = const DebugConfig(),
  });

  final RssiFilterConfig rssiFilter;
  final DistanceModelConfig distanceModel;
  final BleConfig ble;
  final PositioningParams params;
  final PositionSmoothingConfig smoothing;
  final MotionConfig motion;
  final DebugConfig debug;

  /// Reads the optional top-level sections of the building JSON.
  /// Never throws: bad/missing sections fall back to defaults.
  factory PositioningConfig.fromJson(Map<String, dynamic> root) {
    var motion = MotionConfig.fromJson(_m(root['motion']));
    final alias = _m(root['map'])?['northOffsetDegrees'];
    if (motion.heading.mapNorthOffsetDegrees == null && alias is num) {
      motion = motion.withMapNorthOffset(alias.toDouble());
    }
    return PositioningConfig(
      rssiFilter: RssiFilterConfig.fromJson(_m(root['rssiFilter'])),
      distanceModel: DistanceModelConfig.fromJson(_m(root['distanceModel'])),
      ble: BleConfig.fromJson(_m(root['ble'])),
      params: PositioningParams.fromJson(_m(root['positioning'])),
      smoothing: PositionSmoothingConfig.fromJson(_m(root['positionSmoothing'])),
      motion: motion,
      debug: DebugConfig.fromJson(_m(root['debug'])),
    );
  }
}
