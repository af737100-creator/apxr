# HyperPulse Low-Level Download Engine ⚡

HyperPulse is an enterprise-grade, low-level multithreaded download acceleration engine written in **Dart / Flutter**. It leverages concurrent **Dart Isolates**, **HTTP Range Headers**, zero-thrash **RAM ring caching (64MB batches)**, and **Neural Segmentation** to maximize network throughput and minimize flash memory degradation.

---

## 🏛️ Core Architecture Components

1. **`NeuralSegmentationEngine` (`lib/engine/neural_segmentation_engine.dart`)**:
   - Analyzes real-time network throughput, RTT latency, CPU core count, available RAM, and battery state.
   - Dynamically calculates optimal parallel thread concurrency (4 to 32 parallel streams).
   - Generates precise byte-range partitions without byte-boundary collisions.

2. **`RamCacheManager` (`lib/engine/ram_cache_manager.dart`)**:
   - Zero-copy in-memory buffer pool.
   - Buffers incoming TCP socket streams in RAM.
   - Flushes in optimized batches (default 64MB) to physical storage using `RandomAccessFile` positioning to prevent flash memory wear and CPU context-switching overhead.

3. **`TurboDownloadService` (`lib/engine/turbo_download_service.dart`)**:
   - Spawns independent native background threads (`Isolate.spawn`).
   - Streams byte ranges simultaneously via `Dio`.
   - Assembles partitions into the final file without corruption.
   - Dispatches live telemetry streams (`TurboProgressEvent`).

4. **`LinkAnalyzer` (`lib/engine/link_analyzer.dart`)**:
   - Fast-path verification for direct downloadable binaries (`.mp4`, `.apk`, `.zip`, `.iso`, etc.).
   - Bridge interface (`IMediaExtractor`) for `yt-dlp` to extract direct MP4 streams from YouTube, TikTok, Instagram, Twitter/X, and web video hosts.

---

## 🚀 Quick Start Example

```dart
import 'package:hyperpulse/hyperpulse.dart';

void main() async {
  // 1. Initialize Turbo Service
  final turboService = TurboDownloadService();

  // 2. Profile host hardware and connection
  final deviceMetrics = DeviceMetrics(
    totalRamMb: 8192,
    availableRamMb: 4096,
    logicalCores: 8,
    currentNetworkSpeedMbps: 200.0,
    latencyMs: 25,
  );

  // 3. Create download task
  final task = DownloadTask(
    id: 'task_001',
    sourceUrl: 'https://releases.ubuntu.com/22.04.4/ubuntu-22.04.4-desktop-amd64.iso',
    fileName: 'ubuntu-22.04.4.iso',
    destinationDirectory: '/storage/emulated/0/Download',
  );

  // 4. Listen to real-time progress
  turboService.onProgress.listen((event) {
    print('Progress: ${(event.progressPercent * 100).toStringAsFixed(1)}% | Speed: ${(event.speedBytesPerSec / 1024 / 1024).toStringAsFixed(2)} MB/s | RAM Buffer: ${event.bufferedRamMb.toStringAsFixed(1)} MB');
  });

  // 5. Start parallel download
  await turboService.startDownload(
    task: task,
    deviceMetrics: deviceMetrics,
    ramBufferThresholdMb: 64, // 64 MB RAM batch write threshold
  );

  print('Download complete: ${task.fullFilePath}');
}
```
