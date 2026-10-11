enum MotionState { unknown, stationary, walking, running }

/// Everything the fusion layer needs to know about the user's motion at one
/// instant. Built by MotionService; plain data so it is trivial to test.
class MotionSnapshot {
  const MotionSnapshot({
    required this.time,
    this.state = MotionState.unknown,
    this.stepCount = 0,
    this.cadenceHz = 0.0,
    this.stepRegularity = 0.0,
    this.headingRad,
    this.headingConfidence = 0.0,
    this.turnRateRadPerSec = 0.0,
    this.isTurning = false,
    this.shakeSuspected = false,
    this.gyroAvailable = false,
    this.magnetometerAvailable = false,
  });

  final DateTime time;
  final MotionState state;
  final int stepCount;

  /// Steps per second.
  final double cadenceHz;

  /// 0..1 how regular the step rhythm is.
  final double stepRegularity;

  /// Device forward-axis heading, compass frame (0 = magnetic north, clockwise).
  final double? headingRad;
  final double headingConfidence;
  final double turnRateRadPerSec;
  final bool isTurning;

  /// Phone is being shaken - steps are not trustworthy right now.
  final bool shakeSuspected;
  final bool gyroAvailable;
  final bool magnetometerAvailable;

  bool get isMoving =>
      state == MotionState.walking || state == MotionState.running;

  bool headingUsable(double minConfidence) =>
      headingRad != null && headingConfidence >= minConfidence;
}
