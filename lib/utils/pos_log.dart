import 'package:flutter/foundation.dart';

/// Structured, easily-disabled logging for the positioning pipeline.
///
/// Usage: `PosLog.d('BLE', () => 'B01 RSSI=-61');`
/// The message is a closure so that nothing is built when logging is off.
/// Toggle with `debug.logging` in the JSON configuration.
class PosLog {
  PosLog._();

  static bool enabled = false;

  static void d(String tag, String Function() message) {
    if (!enabled) return;
    debugPrint('[$tag] ${message()}');
  }
}
