/// Representation of client hardware specifications and network telemetry
/// used by [NeuralSegmentationEngine] to compute optimal parallelism.
class DeviceMetrics {
  /// Total physical RAM installed on device (in Megabytes).
  final int totalRamMb;

  /// Available free RAM before buffer allocation (in Megabytes).
  final int availableRamMb;

  /// Number of logical CPU cores available on device.
  final int logicalCores;

  /// Current network download throughput in Megabits per second (Mbps).
  final double currentNetworkSpeedMbps;

  /// Network Round Trip Time (RTT) latency in milliseconds.
  final int latencyMs;

  /// Whether device is currently in Battery Saver or Low Power mode.
  final bool isBatterySaverActive;

  /// Thermal throttling status of the device (0.0 = cold, 1.0 = critical throttle).
  final double thermalThrottleIndex;

  const DeviceMetrics({
    required this.totalRamMb,
    required this.availableRamMb,
    required this.logicalCores,
    required this.currentNetworkSpeedMbps,
    required this.latencyMs,
    this.isBatterySaverActive = false,
    this.thermalThrottleIndex = 0.0,
  });

  /// Factory constructor for high-end flagship devices (Simulated / Default).
  factory DeviceMetrics.flagshipProfile() {
    return const DeviceMetrics(
      totalRamMb: 8192,
      availableRamMb: 4096,
      logicalCores: 8,
      currentNetworkSpeedMbps: 250.0,
      latencyMs: 18,
      isBatterySaverActive: false,
      thermalThrottleIndex: 0.0,
    );
  }

  /// Factory constructor for mid-range mobile devices.
  factory DeviceMetrics.midRangeProfile() {
    return const DeviceMetrics(
      totalRamMb: 4096,
      availableRamMb: 1536,
      logicalCores: 6,
      currentNetworkSpeedMbps: 45.0,
      latencyMs: 45,
      isBatterySaverActive: false,
      thermalThrottleIndex: 0.1,
    );
  }

  /// Factory constructor for low-end / constrained devices.
  factory DeviceMetrics.lowEndProfile() {
    return const DeviceMetrics(
      totalRamMb: 2048,
      availableRamMb: 512,
      logicalCores: 4,
      currentNetworkSpeedMbps: 8.0,
      latencyMs: 120,
      isBatterySaverActive: true,
      thermalThrottleIndex: 0.5,
    );
  }

  @override
  String toString() {
    return 'DeviceMetrics(RAM: ${availableRamMb}MB/${totalRamMb}MB, Cores: $logicalCores, Speed: ${currentNetworkSpeedMbps.toStringAsFixed(1)}Mbps, RTT: ${latencyMs}ms)';
  }
}
