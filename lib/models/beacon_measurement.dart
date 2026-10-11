/// A normalised, filtered measurement of ONE configured beacon.
/// Unknown / disabled BLE devices never become a BeaconMeasurement.
class BeaconMeasurement {
  const BeaconMeasurement({
    required this.beaconId,
    required this.macAddress,
    required this.nodeId,
    required this.rawRssi,
    required this.filteredRssi,
    required this.estimatedDistance,
    required this.rssiStdDev,
    required this.sampleCount,
    required this.timestamp,
    required this.quality,
  });

  final String beaconId;
  final String macAddress;
  final String? nodeId;

  /// Latest raw RSSI (dBm).
  final int rawRssi;

  /// Outlier-rejected, smoothed RSSI (dBm).
  final double filteredRssi;

  /// Distance (m) from the user to the beacon, from the filtered RSSI.
  final double estimatedDistance;

  /// Spread of the recent RSSI window (dB): lower = more stable.
  final double rssiStdDev;
  final int sampleCount;

  /// Time of the last packet.
  final DateTime timestamp;

  /// 0..1 intrinsic quality (strength, stability, freshness, sample count).
  final double quality;

  double ageMs(DateTime now) =>
      now.difference(timestamp).inMicroseconds / 1000.0;

  bool isStale(DateTime now, int timeoutMs) => ageMs(now) > timeoutMs;
}
