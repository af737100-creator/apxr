import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/device_metrics.dart';
import '../models/download_task.dart';
import '../models/segment_chunk.dart';
import '../isolates/chunk_worker_isolate.dart';
import 'neural_segmentation_engine.dart';
import 'ram_cache_manager.dart';
import 'cloud_extractor_service.dart';

/// Event dispatched to listeners with real-time download telemetry.
class TurboProgressEvent {
  final String taskId;
  final int totalBytes;
  final int downloadedBytes;
  final double speedBytesPerSec;
  final double progressPercent;
  final List<SegmentChunk> segments;
  final double bufferedRamMb;
  final bool isSingleStream;
  final String statusText;

  TurboProgressEvent({
    required this.taskId,
    required this.totalBytes,
    required this.downloadedBytes,
    required this.speedBytesPerSec,
    required this.progressPercent,
    required this.segments,
    required this.bufferedRamMb,
    this.isSingleStream = false,
    this.statusText = '',
  });
}

/// [TurboDownloadService] is the master download engine for HyperPulse.
///
/// Features:
/// 1. Multi-Thread Parallel Mode (16-Isolates) with HTTP Range 206 for direct files (APK, ZIP, ISO).
/// 2. Single-Stream Direct Mode (ResponseType.stream) without segmentation for social video links (YouTube, TikTok, Instagram).
/// 3. In-Memory Zero-Lock RAM Cache buffering ([RamCacheManager]).
/// 4. Intelligent auto-detection of link types and seamless fallback.
class TurboDownloadService {
  final Dio _dio;
  final NeuralSegmentationEngine _segmentationEngine;
  final StreamController<TurboProgressEvent> _progressController =
      StreamController<TurboProgressEvent>.broadcast();

  Stream<TurboProgressEvent> get onProgress => _progressController.stream;

  TurboDownloadService({
    Dio? customDio,
    NeuralSegmentationEngine? segmentationEngine,
  })  : _dio = customDio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 20),
                receiveTimeout: const Duration(seconds: 60),
                headers: {
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Mobile Safari/537.36 HyperPulse/2.4.0',
                  'Accept': '*/*',
                  'Accept-Encoding': 'identity',
                },
              ),
            ),
        _segmentationEngine = segmentationEngine ?? NeuralSegmentationEngine();

  /// Identifies if a URL belongs to a social media or dynamic media streaming platform
  static bool isSocialMediaStreamUrl(String url) {
    final lower = url.toLowerCase();
    return CloudExtractorService.isSocialVideoPlatform(lower) ||
        lower.contains('googlevideo.com') ||
        lower.contains('tiktokcdn.com') ||
        lower.contains('byteoversea.com') ||
        lower.contains('cdninstagram.com') ||
        lower.contains('fbcdn.net') ||
        lower.contains('twimg.com') ||
        lower.contains('video.twimg.com') ||
        lower.contains('pinimg.com') ||
        lower.contains('v.redd.it') ||
        lower.contains('vimeo.com') ||
        lower.contains('dailymotion.com');
  }

  /// Probes remote file size and range capabilities
  Future<Map<String, dynamic>> probeRemoteFile(String url) async {
    try {
      final response = await _dio.head(
        url,
        options: Options(
          followRedirects: true,
          validateStatus: (status) => status != null && status < 400,
        ),
      );

      final headers = response.headers;
      final contentLengthStr = headers.value('content-length');
      final acceptRanges = headers.value('accept-ranges');
      final contentDisposition = headers.value('content-disposition');

      final int totalBytes =
          contentLengthStr != null ? int.tryParse(contentLengthStr) ?? -1 : -1;
      final bool supportsRanges = (acceptRanges == 'bytes') && (totalBytes > 1024 * 1024);

      String inferredFileName = 'download_file';
      if (contentDisposition != null && contentDisposition.contains('filename=')) {
        final match = RegExp(r'filename=["' + "'" + r']?([^"' + "'" + r';]+)["' + "'" + r']?')
            .firstMatch(contentDisposition);
        if (match != null && match.group(1) != null) {
          inferredFileName = match.group(1)!;
        }
      } else {
        final uri = Uri.parse(url);
        if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
          inferredFileName = uri.pathSegments.last;
        }
      }

      return {
        'totalBytes': totalBytes,
        'supportsRanges': supportsRanges,
        'fileName': inferredFileName,
        'headers': headers.map,
      };
    } catch (e) {
      debugPrint('[TurboDownloadService] Probe warning: $e');
      return {
        'totalBytes': -1,
        'supportsRanges': false,
        'fileName': 'download_file',
        'headers': {},
      };
    }
  }

  /// Master download router: automatically chooses Single-Stream or Multi-Thread Parallel
  Future<void> startDownload({
    required DownloadTask task,
    required DeviceMetrics deviceMetrics,
    int? customThreadCount,
    int ramBufferThresholdMb = 64,
    bool forceSingleStream = false,
  }) async {
    final bool isSocial = isSocialMediaStreamUrl(task.sourceUrl);

    // 1. If it's a social video (YouTube/TikTok, etc.) or explicitly forced, use Single-Stream immediately
    if (forceSingleStream || isSocial) {
      debugPrint('[TurboDownloadService] ⚡ Activating Single-Stream Direct Mode for social media video.');
      await downloadSingleStream(
        task: task,
        ramBufferThresholdMb: ramBufferThresholdMb,
      );
      return;
    }

    // 2. Otherwise probe for multi-threaded parallel download (Direct files: APK, ZIP, ISO)
    task.status = DownloadStatus.analyzing;
    final probeResult = await probeRemoteFile(task.sourceUrl);
    task.totalSizeBytes = probeResult['totalBytes'] as int;
    final bool supportsRanges = probeResult['supportsRanges'] as bool;

    if (task.totalSizeBytes <= 0 || !supportsRanges) {
      debugPrint('[TurboDownloadService] Range requests unsupported. Falling back to Single-Stream Mode.');
      await downloadSingleStream(
        task: task,
        ramBufferThresholdMb: ramBufferThresholdMb,
      );
      return;
    }

    // 3. Launch Multi-Thread Parallel Isolates
    try {
      await _executeParallelDownload(
        task: task,
        deviceMetrics: deviceMetrics,
        customThreadCount: customThreadCount,
        ramBufferThresholdMb: ramBufferThresholdMb,
      );
    } catch (e) {
      debugPrint('[TurboDownloadService] Parallel download error, falling back to Single-Stream: $e');
      await downloadSingleStream(
        task: task,
        ramBufferThresholdMb: ramBufferThresholdMb,
      );
    }
  }

  /// [downloadSingleStream]: Direct single-stream downloader using ResponseType.stream.
  /// Does NOT split into chunks, buffers in RAM cache, and streams continuously to disk.
  Future<void> downloadSingleStream({
    required DownloadTask task,
    int ramBufferThresholdMb = 64,
  }) async {
    task.status = DownloadStatus.downloading;
    task.threadCount = 1;

    final targetFile = File(task.fullFilePath);
    if (!await targetFile.parent.exists()) {
      await targetFile.parent.create(recursive: true);
    }

    // Prepare single segment telemetry indicator
    final singleSegment = SegmentChunk(
      index: 0,
      startByte: 0,
      endByte: task.totalSizeBytes > 0 ? task.totalSizeBytes : 0,
      status: ChunkStatus.downloading,
    );
    task.segments.clear();
    task.segments.add(singleSegment);

    final ramCache = RamCacheManager(
      targetFilePath: task.fullFilePath,
      flushThresholdBytes: ramBufferThresholdMb * 1024 * 1024,
    );
    await ramCache.initialize(expectedTotalSize: task.totalSizeBytes);

    int bytesDownloadedSinceLastTick = 0;
    DateTime lastSpeedTick = DateTime.now();
    final Response<ResponseBody> response = await _dio.get<ResponseBody>(
      task.sourceUrl,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          'Accept-Encoding': 'identity',
        },
      ),
    );

    final stream = response.data?.stream;
    if (stream == null) {
      throw Exception('تعذر فتح تيار تحميل الفيديو المباشر من السيرفر');
    }

    // Try to extract content-length from stream response headers if available
    final streamContentLength = response.headers.value('content-length');
    if (streamContentLength != null && task.totalSizeBytes <= 0) {
      task.totalSizeBytes = int.tryParse(streamContentLength) ?? -1;
      singleSegment.endByte = task.totalSizeBytes > 0 ? task.totalSizeBytes : 0;
    }

    int currentOffset = 0;

    await for (final Uint8List chunk in stream) {
      final int chunkSize = chunk.lengthInBytes;
      task.downloadedBytes += chunkSize;
      singleSegment.downloadedBytes += chunkSize;
      bytesDownloadedSinceLastTick += chunkSize;

      // Write directly to zero-thrash RAM Cache
      await ramCache.writeChunkData(
        segmentIndex: 0,
        fileOffset: currentOffset,
        data: chunk,
      );
      currentOffset += chunkSize;

      // Speed calculation every 400ms
      final now = DateTime.now();
      final elapsedMs = now.difference(lastSpeedTick).inMilliseconds;
      if (elapsedMs >= 400) {
        final double speedBps = (bytesDownloadedSinceLastTick / elapsedMs) * 1000.0;
        task.speedBytesPerSecond = speedBps;
        bytesDownloadedSinceLastTick = 0;
        lastSpeedTick = now;

        double progressPct = 0.0;
        if (task.totalSizeBytes > 0) {
          progressPct = (task.downloadedBytes / task.totalSizeBytes).clamp(0.0, 0.99);
        } else {
          // Dynamic pulsing stream progression
          progressPct = (task.downloadedBytes / (task.downloadedBytes + 5 * 1024 * 1024)).clamp(0.05, 0.95);
        }

        _progressController.add(
          TurboProgressEvent(
            taskId: task.id,
            totalBytes: task.totalSizeBytes,
            downloadedBytes: task.downloadedBytes,
            speedBytesPerSec: speedBps,
            progressPercent: progressPct,
            segments: [singleSegment],
            bufferedRamMb: ramCache.currentBufferedMb,
            isSingleStream: true,
            statusText: 'تيار مباشر نشط (Social Video Stream)',
          ),
        );
      }
    }

    // Flush RAM cache to disk and finalize
    task.status = DownloadStatus.merging;
    await ramCache.flushToDisk();
    await ramCache.dispose();

    singleSegment.status = ChunkStatus.completed;
    task.status = DownloadStatus.completed;
    task.finishedAt = DateTime.now();

    _progressController.add(
      TurboProgressEvent(
        taskId: task.id,
        totalBytes: task.downloadedBytes,
        downloadedBytes: task.downloadedBytes,
        speedBytesPerSec: 0,
        progressPercent: 1.0,
        segments: [singleSegment],
        bufferedRamMb: 0.0,
        isSingleStream: true,
        statusText: 'اكتمل تحميل الفيديو بنجاح',
      ),
    );
  }

  /// Multi-Thread Parallel Download Implementation
  Future<void> _executeParallelDownload({
    required DownloadTask task,
    required DeviceMetrics deviceMetrics,
    int? customThreadCount,
    required int ramBufferThresholdMb,
  }) async {
    final int threadCount = customThreadCount ??
        _segmentationEngine.calculateOptimalThreads(
          metrics: deviceMetrics,
          fileSizeBytes: task.totalSizeBytes,
        );

    task.threadCount = threadCount;
    task.status = DownloadStatus.preparingSegments;

    final List<SegmentChunk> chunks = _segmentationEngine.generateSegmentChunks(
      totalFileSizeBytes: task.totalSizeBytes,
      threadCount: threadCount,
    );
    task.segments.clear();
    task.segments.addAll(chunks);

    final ramCache = RamCacheManager(
      targetFilePath: task.fullFilePath,
      flushThresholdBytes: ramBufferThresholdMb * 1024 * 1024,
    );
    await ramCache.initialize(expectedTotalSize: task.totalSizeBytes);

    task.status = DownloadStatus.downloading;

    int bytesDownloadedSinceLastTick = 0;
    DateTime lastSpeedTick = DateTime.now();
    final receivePort = ReceivePort();
    final List<Isolate> workerIsolates = [];
    int completedWorkers = 0;
    final Completer<void> downloadFinishedCompleter = Completer<void>();

    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      chunk.status = ChunkStatus.downloading;
      chunk.startTime = DateTime.now();

      final initParams = ChunkWorkerInitParams(
        segmentIndex: chunk.index,
        url: task.sourceUrl,
        startByte: chunk.startByte,
        endByte: chunk.endByte,
        mainSendPort: receivePort.sendPort,
      );

      final isolate = await Isolate.spawn<ChunkWorkerInitParams>(
        chunkWorkerEntryPoint,
        initParams,
      );
      workerIsolates.add(isolate);
    }

    final subscription = receivePort.listen((dynamic message) async {
      if (message is ChunkWorkerPacket) {
        final chunk = task.segments[message.segmentIndex];

        if (message.error != null) {
          chunk.status = ChunkStatus.failed;
          chunk.errorMessage = message.error;
        } else if (message.isCompleted) {
          chunk.status = ChunkStatus.completed;
          chunk.completedTime = DateTime.now();
          completedWorkers++;

          if (completedWorkers == task.segments.length) {
            if (!downloadFinishedCompleter.isCompleted) {
              downloadFinishedCompleter.complete();
            }
          }
        } else if (message.data != null) {
          final Uint8List data = message.data!;
          chunk.downloadedBytes += data.lengthInBytes;
          task.downloadedBytes += data.lengthInBytes;
          bytesDownloadedSinceLastTick += data.lengthInBytes;

          await ramCache.writeChunkData(
            segmentIndex: message.segmentIndex,
            fileOffset: message.offset,
            data: data,
          );

          final now = DateTime.now();
          final elapsedMs = now.difference(lastSpeedTick).inMilliseconds;
          if (elapsedMs >= 400) {
            final double speedBps = (bytesDownloadedSinceLastTick / elapsedMs) * 1000.0;
            task.speedBytesPerSecond = speedBps;
            bytesDownloadedSinceLastTick = 0;
            lastSpeedTick = now;

            _progressController.add(
              TurboProgressEvent(
                taskId: task.id,
                totalBytes: task.totalSizeBytes,
                downloadedBytes: task.downloadedBytes,
                speedBytesPerSec: task.speedBytesPerSecond,
                progressPercent: task.progress,
                segments: List.unmodifiable(task.segments),
                bufferedRamMb: ramCache.currentBufferedMb,
                isSingleStream: false,
                statusText: 'تقطيع متوازي ($threadCount ألوية نشطة)',
              ),
            );
          }
        }
      }
    });

    await downloadFinishedCompleter.future;

    for (final isolate in workerIsolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    await subscription.cancel();
    receivePort.close();

    task.status = DownloadStatus.merging;
    await ramCache.flushToDisk();
    await ramCache.dispose();

    task.status = DownloadStatus.completed;
    task.finishedAt = DateTime.now();

    _progressController.add(
      TurboProgressEvent(
        taskId: task.id,
        totalBytes: task.totalSizeBytes,
        downloadedBytes: task.totalSizeBytes,
        speedBytesPerSec: 0,
        progressPercent: 1.0,
        segments: List.unmodifiable(task.segments),
        bufferedRamMb: 0.0,
        isSingleStream: false,
        statusText: 'اكتمل التحميل المتوازي',
      ),
    );
  }

  void dispose() {
    _progressController.close();
  }
}
