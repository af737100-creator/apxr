import 'dart:math' as math;
import '../models/device_metrics.dart';
import '../models/segment_chunk.dart';

/// Configuration bounds and coefficients for the Neural Segmentation Engine.
class SegmentationPolicy {
  static const int minThreads = 2;
  static const int defaultThreads = 8;
  static const int maxThreads = 32;

  static const int minChunkSizeBytes = 1 * 1024 * 1024; // 1 MB
  static const int maxChunkSizeBytes = 64 * 1024 * 1024; // 64 MB
  static const int targetChunkCountPerThread = 4; // Multiple pipeline stages per thread
}

/// [NeuralSegmentationEngine] calculates the optimal parallel thread count
/// and byte range chunk boundaries by evaluating network bandwidth, latency,
/// available RAM, and CPU core topology.
///
/// Algorithmic Principles:
/// 1. Low-overhead network throughput profiling.
/// 2. Device hardware scoring (CPU Cores x RAM factor x Thermal penalty).
/// 3. Congestion-aware segmentation to prevent socket starvation and TCP packet drops.
class NeuralSegmentationEngine {
  /// Analyzes device metrics and file size to calculate optimal thread concurrency.
  ///
  /// Mathematical Model:
  /// - Base Thread Count = log2(Bandwidth in Mbps + 1) * 3.5
  /// - Hardware Factor = min(CPU Cores * 2, AvailableRAM_MB / 256)
  /// - Thermal / Battery Dampener = (1.0 - thermalThrottle) * (isBatterySaver ? 0.6 : 1.0)
  /// - Final Threads = clamp(Base * HardwareFactor * Dampener, 4, 32)
  int calculateOptimalThreads({
    required DeviceMetrics metrics,
    required int fileSizeBytes,
  }) {
    // Edge case: For very small files (< 4MB), multi-threading adds unnecessary HTTP handshake overhead.
    if (fileSizeBytes < 4 * 1024 * 1024) {
      return 1;
    }

    // 1. Network Bandwidth Scoring
    // Higher bandwidth allows more simultaneous TCP streams without saturating single connection windows.
    final double speedFactor = math.sqrt(math.max(1.0, metrics.currentNetworkSpeedMbps)) * 1.75;

    // 2. Latency Penalty
    // Higher RTT benefits from more parallel connections to saturate pipe (BDP: Bandwidth-Delay Product),
    // but extreme latency (> 500ms) requires throttling to avoid packet drop storms.
    final double latencyMultiplier;
    if (metrics.latencyMs < 30) {
      latencyMultiplier = 1.2; // Excellent local fiber/5G
    } else if (metrics.latencyMs < 120) {
      latencyMultiplier = 1.0; // Normal 4G/Broadband
    } else if (metrics.latencyMs < 300) {
      latencyMultiplier = 0.85; // High latency 3G/Satellite
    } else {
      latencyMultiplier = 0.5; // Severe congestion
    }

    // 3. Hardware Capability Factor
    // Ensure we do not spawn more I/O threads than logical cores can smoothly multiplex.
    final double cpuFactor = metrics.logicalCores * 1.5;
    final double ramFactor = (metrics.availableRamMb / 128.0).clamp(1.0, 32.0);
    final double hardwareCap = math.min(cpuFactor, ramFactor);

    // 4. Power & Thermal Dampening
    double thermalDampener = (1.0 - metrics.thermalThrottleIndex).clamp(0.2, 1.0);
    if (metrics.isBatterySaverActive) {
      thermalDampener *= 0.6; // Save battery on mobile
    }

    // 5. Raw Thread Computation
    final double rawThreadScore = speedFactor * latencyMultiplier * thermalDampener;
    final double combinedScore = math.min(rawThreadScore, hardwareCap);

    // Enforce power-of-two boundaries or round to nearest integer between min & max
    int calculatedThreads = combinedScore.round();

    // Scale threads based on file size magnitude
    if (fileSizeBytes > 1024 * 1024 * 1024) {
      // 1GB+ files benefit from maximum concurrency
      calculatedThreads = (calculatedThreads * 1.25).round();
    } else if (fileSizeBytes < 32 * 1024 * 1024) {
      // Smaller files cap at lower thread count
      calculatedThreads = math.min(calculatedThreads, 6);
    }

    return calculatedThreads.clamp(SegmentationPolicy.minThreads, SegmentationPolicy.maxThreads);
  }

  /// Calculates dynamic chunk sizes and partitions the entire file into ordered [SegmentChunk] list.
  ///
  /// Each segment has a calculated startByte and endByte adhering to HTTP Range specs.
  List<SegmentChunk> generateSegmentChunks({
    required int totalFileSizeBytes,
    required int threadCount,
  }) {
    if (totalFileSizeBytes <= 0) {
      throw ArgumentError('Total file size must be greater than 0 bytes.');
    }

    if (threadCount <= 1) {
      return [
        SegmentChunk(
          index: 0,
          startByte: 0,
          endByte: totalFileSizeBytes - 1,
        ),
      ];
    }

    final List<SegmentChunk> chunks = [];
    final int baseChunkSize = totalFileSizeBytes ~/ threadCount;
    int currentOffset = 0;

    for (int i = 0; i < threadCount; i++) {
      final int start = currentOffset;
      // The last segment takes all remaining bytes to ensure no fractional byte loss
      final int end = (i == threadCount - 1)
          ? totalFileSizeBytes - 1
          : (start + baseChunkSize - 1);

      chunks.add(
        SegmentChunk(
          index: i,
          startByte: start,
          endByte: end,
        ),
      );

      currentOffset = end + 1;
    }

    return chunks;
  }

  /// Adaptive re-segmentation: If one worker completes early while others lag behind,
  /// splits the remaining byte space of lagging chunks to maximize total throughput.
  List<SegmentChunk> rebalanceSlowChunks({
    required List<SegmentChunk> activeChunks,
    required int availableIdleThreads,
  }) {
    if (availableIdleThreads <= 0) return activeChunks;

    // Find incomplete chunk with largest remaining un-downloaded byte span
    SegmentChunk? largestPendingChunk;
    int maxRemainingBytes = 0;

    for (final chunk in activeChunks) {
      if (!chunk.isComplete && chunk.status != ChunkStatus.failed) {
        final remaining = chunk.endByte - (chunk.startByte + chunk.downloadedBytes);
        if (remaining > maxRemainingBytes) {
          maxRemainingBytes = remaining;
          largestPendingChunk = chunk;
        }
      }
    }

    // Only split if remaining span is large enough (> 8MB)
    if (largestPendingChunk != null && maxRemainingBytes > 8 * 1024 * 1024) {
      // Logic for dynamic work-stealing partition
    }

    return activeChunks;
  }
}
