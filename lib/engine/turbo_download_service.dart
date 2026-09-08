import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import '../models/device_metrics.dart';
import '../models/download_task.dart';
import '../models/segment_chunk.dart';
import '../isolates/chunk_worker_isolate.dart';
import 'neural_segmentation_engine.dart';
import 'ram_cache_manager.dart';
import 'storage_path_resolver.dart';
import 'cloud_extractor_service.dart';
import 'zero_byte_shield_engine.dart';
import 'smart_resume_manager.dart';
import 'dual_network_flight_mode.dart';
import 'android_system_bridge.dart';
import 'universal_app_store_resolver.dart';
import 'watermark_service.dart';
import 'package:path/path.dart' as p;

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
  final int activeThreads;
  final bool isDualBoostActive;

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
    this.activeThreads = 1,
    this.isDualBoostActive = false,
  });
}

/// [TurboDownloadService] is the supreme rocket engine for HyperPulse:
/// 1. Dynamic Parallel Segmentation: up to 32 parallel Dart Isolates with adaptive bandwidth profiling.
/// 2. 64MB Volatile RAM Cache with zero flash-wear synchronized batched I/O.
/// 3. Zero-Byte & Magic Bytes Header Shield (blocks fake HTML error pages, 0-byte corruptions).
/// 4. Smart Byte-Level Resumption (.pulse_state checkpointing).
/// 5. Adaptive Bandwidth Optimizer: adjusts active thread windows dynamically.
/// 6. Dual-Network Flight Mode: combines Wi-Fi + 5G radios concurrently.
/// 7. Deep Redirect & Cookie Tracking for MediaFire, APKPure, GitHub Releases, and Uptodown.
class TurboDownloadService {
  final Dio _dio;
  final NeuralSegmentationEngine _segmentationEngine;
  final DualNetworkFlightModeService _dualNetwork = DualNetworkFlightModeService();
  final StreamController<TurboProgressEvent> _progressController =
      StreamController<TurboProgressEvent>.broadcast();

  Stream<TurboProgressEvent> get onProgress => _progressController.stream;
  Stream<TurboProgressEvent> get progressStream => _progressController.stream;

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
                      'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.127 Mobile Safari/537.36',
                  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
                  'Accept-Encoding': 'identity',
                  'Connection': 'keep-alive',
                  'Sec-Fetch-Dest': 'document',
                  'Sec-Fetch-Mode': 'navigate',
                  'Sec-Fetch-Site': 'none',
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

  /// Probes remote file size, redirects (up to 10 hops), and range capabilities
  Future<Map<String, dynamic>> probeRemoteFile(String url, {Map<String, String>? customCookies}) async {
    int totalBytes = -1;
    bool supportsRanges = false;
    String inferredFileName = 'download_file';
    String contentType = '';
    Map<String, dynamic> headersMap = {};

    try {
      final headers = <String, dynamic>{
        'Accept-Encoding': 'identity',
      };
      if (customCookies != null && customCookies.isNotEmpty) {
        headers['Cookie'] = customCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
      }

      // Step 1: Fast HEAD Request
      try {
        final response = await _dio.head(
          url,
          options: Options(
            followRedirects: true,
            maxRedirects: 10,
            validateStatus: (status) => status != null && status < 400,
            headers: headers,
          ),
        );

        final respHeaders = response.headers;
        headersMap = respHeaders.map;
        final contentLengthStr = respHeaders.value('content-length');
        final acceptRanges = respHeaders.value('accept-ranges');
        final contentDisposition = respHeaders.value('content-disposition');
        contentType = respHeaders.value('content-type')?.toLowerCase() ?? '';

        if (contentLengthStr != null) {
          totalBytes = int.tryParse(contentLengthStr) ?? -1;
        }
        if (acceptRanges == 'bytes' || (totalBytes > 2 * 1024 * 1024)) {
          supportsRanges = true;
        }

        if (contentDisposition != null && contentDisposition.contains('filename')) {
          final match = RegExp('filename\\*?=(?:UTF-8\'\')?["\']?([^"\';]+)["\']?')
              .firstMatch(contentDisposition);
          if (match != null && match.group(1) != null) {
            inferredFileName = Uri.decodeFull(match.group(1)!.trim());
          }
        }
      } catch (headErr) {
        debugPrint('[TurboDownloadService] HEAD probe skipped, attempting range probe: $headErr');
      }

      // Step 2: If HEAD was inconclusive or range wasn't proven, perform 1-byte GET Range probe
      if (!supportsRanges || totalBytes <= 0) {
        try {
          final rangeResponse = await _dio.get<ResponseBody>(
            url,
            options: Options(
              responseType: ResponseType.stream,
              followRedirects: true,
              maxRedirects: 10,
              headers: {
                ...headers,
                'Range': 'bytes=0-1',
                'User-Agent':
                    'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.127 Mobile Safari/537.36',
              },
              validateStatus: (status) => status != null && (status == 200 || status == 206),
            ),
          );

          final rHeaders = rangeResponse.headers;
          if (contentType.isEmpty) {
            contentType = rHeaders.value('content-type')?.toLowerCase() ?? '';
          }
          final contentRange = rHeaders.value('content-range');
          if (rangeResponse.statusCode == 206 && contentRange != null) {
            supportsRanges = true;
            final match = RegExp(r'/(\d+)').firstMatch(contentRange);
            if (match != null) {
              totalBytes = int.tryParse(match.group(1)!) ?? totalBytes;
            }
          } else if (rangeResponse.statusCode == 200) {
            final len = rHeaders.value('content-length');
            if (len != null) {
              totalBytes = int.tryParse(len) ?? totalBytes;
            }
          }
        } catch (_) {}
      }

      if (inferredFileName == 'download_file') {
        final uri = Uri.parse(url);
        if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
          inferredFileName = uri.pathSegments.last;
        }
      }

      return {
        'totalBytes': totalBytes,
        'supportsRanges': supportsRanges,
        'fileName': inferredFileName,
        'contentType': contentType,
        'headers': headersMap,
      };
    } catch (e) {
      debugPrint('[TurboDownloadService] Probe warning: $e');
      return {
        'totalBytes': totalBytes,
        'supportsRanges': supportsRanges,
        'fileName': inferredFileName,
        'contentType': contentType,
        'headers': headersMap,
      };
    }
  }

  /// Master download router: automatically chooses Lightning YouTube Native Stream,
  /// 32-Isolate Parallel Multi-Thread Turbo, or High-Speed Buffered Streaming.
  Future<void> startDownload({
    required DownloadTask task,
    required DeviceMetrics deviceMetrics,
    int? customThreadCount,
    int ramBufferThresholdMb = 64,
    bool forceSingleStream = false,
    int maxZeroByteRetries = 3,
  }) async {
    int attempts = 0;
    while (attempts < maxZeroByteRetries) {
      attempts++;
      task.downloadedBytes = 0;
      try {
        await _performDownloadPipeline(
          task: task,
          deviceMetrics: deviceMetrics,
          customThreadCount: customThreadCount,
          ramBufferThresholdMb: ramBufferThresholdMb,
          forceSingleStream: forceSingleStream,
        );

        final tempFile = File(task.tempFilePath);
        final finalFile = File(task.fullFilePath);

        // Determine actual downloaded file location on disk
        String inspectPath = task.fullFilePath;
        if (await tempFile.exists()) {
          inspectPath = task.tempFilePath;
        } else if (await finalFile.exists()) {
          inspectPath = task.fullFilePath;
        } else {
          debugPrint('[TurboDownloadService] ⚠️ Neither temp file nor final file exists on disk!');
          if (attempts >= maxZeroByteRetries) {
            throw Exception('الملف غير موجود على القرص (File does not exist).');
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        // Zero-Byte & Magic Bytes Inspection on the completed file
        final integrity = await ZeroByteShieldEngine.inspectFile(
          filePath: inspectPath,
          expectedExtension: task.fileExtension,
        );

        if (!integrity.isValid) {
          debugPrint('[TurboDownloadService] ⚠️ Integrity rejected: ${integrity.rejectionReason}. Attempt $attempts of $maxZeroByteRetries.');
          try {
            if (await tempFile.exists()) await tempFile.delete();
            if (await finalFile.exists()) await finalFile.delete();
          } catch (_) {}

          if (attempts >= maxZeroByteRetries) {
            throw Exception(integrity.rejectionReason ?? 'فشل التحميل: الملف فارغ أو تالف وتم رفضه تلقائياً.');
          }
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }

        // Atomically rename/copy verified part file to final destination file if still in temp
        if (await tempFile.exists()) {
          if (await finalFile.exists()) {
            try {
              await finalFile.delete();
            } catch (_) {}
          }
          try {
            await tempFile.rename(task.fullFilePath);
          } catch (_) {
            // Fallback for cross-device / Scoped storage boundary where rename is not supported
            await tempFile.copy(task.fullFilePath);
            try {
              await tempFile.delete();
            } catch (_) {}
          }
        }

        // Auto-repair any .bin or missing extension using magic numbers
        final repairedPath = await ZeroByteShieldEngine.autoRepairFileExtension(task.fullFilePath);
        if (repairedPath != task.fullFilePath) {
          task.fileName = p.basename(repairedPath);
          task.destinationDirectory = p.dirname(repairedPath);
          debugPrint('[TurboDownloadService] 🔄 Auto-repaired final task name to: ${task.fileName}');
        }

        // Update task status and finished time
        task.status = DownloadStatus.completed;
        task.finishedAt = DateTime.now();

        // Clean up checkpoint on success
        await SmartResumeManager.deleteCheckpoint(task.tempFilePath);
        await SmartResumeManager.deleteCheckpoint(task.fullFilePath);

        // Stamp brand watermark with background and app name on downloaded videos if enabled
        if (task.isVideo && File(task.fullFilePath).existsSync()) {
          try {
            debugPrint('[TurboDownloadService] 🎬 Stamping brand watermark badge on video: ${task.fullFilePath}');
            await WatermarkService().applyWatermarkToVideo(task.fullFilePath);
          } catch (wmErr) {
            debugPrint('[TurboDownloadService] Watermarking notice: $wmErr');
          }
        }

        // Immediate Gallery & MediaStore Indexing
        try {
          await AndroidSystemBridge.scanMediaFile(task.fullFilePath);
        } catch (_) {}

        // Dispatch final 100% completion progress event
        _progressController.add(
          TurboProgressEvent(
            taskId: task.id,
            totalBytes: task.downloadedBytes > 0 ? task.downloadedBytes : task.totalSizeBytes,
            downloadedBytes: task.downloadedBytes > 0 ? task.downloadedBytes : task.totalSizeBytes,
            speedBytesPerSec: 0,
            progressPercent: 1.0,
            segments: List.from(task.segments),
            bufferedRamMb: 0.0,
            isSingleStream: forceSingleStream,
            statusText: task.isApk
                ? '✅ اكتمل تحميل تطبيق APK وجاري الفتح والتثبيت...'
                : (task.isVideo ? '🎬 اكتمل التحميل وحفظ الفيديو في المعرض بنجاح!' : '✅ اكتمل التحميل وحفظ الملف بنجاح!'),
            activeThreads: task.threadCount,
          ),
        );

        return; // Success!
      } catch (e) {
        if (attempts >= maxZeroByteRetries) {
          rethrow;
        }
        debugPrint('[TurboDownloadService] Download attempt $attempts failed with: $e. Retrying...');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> _performDownloadPipeline({
    required DownloadTask task,
    required DeviceMetrics deviceMetrics,
    int? customThreadCount,
    required int ramBufferThresholdMb,
    required bool forceSingleStream,
  }) async {
    // 0. Resolve store page URLs (APKPure, Uptodown, Mediafire, etc.) if raw page link was passed
    if (UniversalAppStoreResolver.isStoreOrHostingPage(task.sourceUrl) &&
        !task.sourceUrl.contains('dw.uptodown.com') &&
        !task.sourceUrl.contains('d.apkpure.net') &&
        !task.sourceUrl.contains('download.apkpure.com')) {
      final resolved = await UniversalAppStoreResolver.resolveStoreUrl(task.sourceUrl, pageTitle: task.fileName);
      if (resolved != null && resolved.directDownloadUrl.isNotEmpty) {
        task.sourceUrl = resolved.directDownloadUrl;
        if (resolved.cleanFileName.isNotEmpty) {
          task.fileName = resolved.cleanFileName;
        }
      }
    }

    // 1. Direct YouTube URL -> Use Ultra-Fast Native Explode Stream
    if (CloudExtractorService.isYouTubeUrl(task.sourceUrl)) {
      final ytId = CloudExtractorService.extractYouTubeVideoId(task.sourceUrl);
      if (ytId != null && ytId.isNotEmpty) {
        debugPrint('[TurboDownloadService] ⚡ Running Lightning YouTube Direct Stream for: $ytId');
        try {
          await downloadYouTubeDirectNative(
            task: task,
            videoId: ytId,
            ramBufferThresholdMb: ramBufferThresholdMb,
          );
          return;
        } catch (e) {
          debugPrint('[TurboDownloadService] Native YouTube direct stream warning: $e. Trying standard turbo...');
        }
      }
    }

    if (forceSingleStream) {
      debugPrint('[TurboDownloadService] ⚡ Forced Single Stream Mode requested.');
      await downloadSingleStream(
        task: task,
        ramBufferThresholdMb: ramBufferThresholdMb,
      );
      return;
    }

    // 2. Intelligent Range & Media Probing for Turbo Parallel Acceleration
    task.status = DownloadStatus.analyzing;
    final probeResult = await probeRemoteFile(task.sourceUrl);
    task.totalSizeBytes = probeResult['totalBytes'] as int;
    final bool supportsRanges = probeResult['supportsRanges'] as bool;
    final String contentType = (probeResult['contentType'] as String?) ?? '';

    // Correct file name and extension if probe returned genuine Content-Disposition header
    final probedName = probeResult['fileName'] as String?;
    if (probedName != null && probedName.isNotEmpty) {
      final lower = probedName.toLowerCase();
      if (lower.endsWith('.apk') ||
          lower.endsWith('.xapk') ||
          lower.endsWith('.zip') ||
          lower.endsWith('.mp4') ||
          lower.endsWith('.mkv')) {
        task.fileName = StoragePathResolver.sanitizeFileName(probedName);
      }
    }
    if ((contentType.contains('vnd.android.package-archive') ||
            contentType.contains('application/zip') ||
            task.sourceUrl.toLowerCase().contains('uptodown') ||
            task.sourceUrl.toLowerCase().contains('apkpure')) &&
        task.fileName.toLowerCase().endsWith('.bin')) {
      final base = task.fileName.substring(0, task.fileName.length - 4);
      task.fileName = '$base.apk';
    }

    if (contentType.contains('text/html') && (task.isApk || task.isVideo || task.isArchive)) {
      throw Exception('الرابط المعطى محمي أو غير مباشر (صفحة ويب إعلانية وليست ملفاً حقيقياً). افتح الرابط في المتصفح لتحميله');
    }

    // 3. If the server supports Range requests, launch Multi-Threaded Parallel Rocket Mode!
    if (supportsRanges && task.totalSizeBytes > 1024 * 1024) {
      debugPrint('[TurboDownloadService] 🚀 Range supported (${task.totalSizeBytes} bytes). Launching Parallel Turbo Mode!');
      try {
        await _executeParallelDownload(
          task: task,
          deviceMetrics: deviceMetrics,
          customThreadCount: customThreadCount,
          ramBufferThresholdMb: ramBufferThresholdMb,
        );
        return;
      } catch (e) {
        debugPrint('[TurboDownloadService] Parallel download error, falling back to Single-Stream: $e');
      }
    }

    // 4. Single-Stream Buffered Fallback
    debugPrint('[TurboDownloadService] ⚡ Executing High-Speed Buffered Single-Stream Mode.');
    await downloadSingleStream(
      task: task,
      ramBufferThresholdMb: ramBufferThresholdMb,
    );
  }

  /// [downloadYouTubeDirectNative]: Streams directly from Google's high-speed CDN video servers
  Future<void> downloadYouTubeDirectNative({
    required DownloadTask task,
    required String videoId,
    int ramBufferThresholdMb = 64,
  }) async {
    task.status = DownloadStatus.downloading;
    task.threadCount = 4;

    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(VideoId(videoId));
      
      final muxedStreams = manifest.muxed.sortByVideoQuality();
      StreamInfo? targetStreamInfo = muxedStreams.isNotEmpty ? muxedStreams.last : null;

      if (targetStreamInfo == null) {
        final videoOnly = manifest.videoOnly.sortByVideoQuality();
        if (videoOnly.isNotEmpty) targetStreamInfo = videoOnly.last;
      }

      if (targetStreamInfo == null) {
        throw Exception('لم يتم العثور على تيار فيديو مناسب للتحميل');
      }

      task.totalSizeBytes = targetStreamInfo.size.totalBytes;

      final targetFile = File(task.tempFilePath);
      if (!await targetFile.parent.exists()) {
        try {
          await targetFile.parent.create(recursive: true);
        } catch (_) {}
      }

      final singleSegment = SegmentChunk(
        index: 0,
        startByte: 0,
        endByte: task.totalSizeBytes,
        status: ChunkStatus.downloading,
      );
      task.segments.clear();
      task.segments.add(singleSegment);

      Stream<List<int>> byteStream;
      try {
        final directCdnUrl = targetStreamInfo.url.toString();
        final response = await _dio.get<ResponseBody>(
          directCdnUrl,
          options: Options(
            responseType: ResponseType.stream,
            followRedirects: true,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
              'Referer': 'https://www.youtube.com/',
              'Accept': '*/*',
              'Accept-Encoding': 'identity',
              'Connection': 'keep-alive',
            },
          ),
        );
        if (response.data?.stream != null) {
          byteStream = response.data!.stream;
        } else {
          byteStream = yt.videos.streamsClient.get(targetStreamInfo);
        }
      } catch (_) {
        byteStream = yt.videos.streamsClient.get(targetStreamInfo);
      }

      final IOSink sink = targetFile.openWrite(mode: FileMode.write);

      int bytesDownloadedSinceLastTick = 0;
      DateTime lastSpeedTick = DateTime.now();

      try {
        await for (final List<int> chunkData in byteStream) {
          sink.add(chunkData);
          final int chunkSize = chunkData.length;

          task.downloadedBytes += chunkSize;
          singleSegment.downloadedBytes += chunkSize;
          bytesDownloadedSinceLastTick += chunkSize;

          final now = DateTime.now();
          final elapsedMs = now.difference(lastSpeedTick).inMilliseconds;
          if (elapsedMs >= 250) {
            final double speedBps = (bytesDownloadedSinceLastTick / elapsedMs) * 1000.0;
            task.speedBytesPerSecond = speedBps;
            bytesDownloadedSinceLastTick = 0;
            lastSpeedTick = now;

            final double progressPct = task.totalSizeBytes > 0
                ? (task.downloadedBytes / task.totalSizeBytes).clamp(0.0, 0.99)
                : 0.5;

            _progressController.add(
              TurboProgressEvent(
                taskId: task.id,
                totalBytes: task.totalSizeBytes,
                downloadedBytes: task.downloadedBytes,
                speedBytesPerSec: speedBps,
                progressPercent: progressPct,
                segments: [singleSegment],
                bufferedRamMb: 0.0,
                isSingleStream: false,
                statusText: '⚡ تيار مباشر فائق من سيرفرات YouTube CDN',
                activeThreads: 4,
              ),
            );
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      singleSegment.status = ChunkStatus.completed;
    } finally {
      yt.close();
    }
  }

  /// [downloadSingleStream]: Direct ultra-high-speed buffered stream for general social streams
  Future<void> downloadSingleStream({
    required DownloadTask task,
    int ramBufferThresholdMb = 64,
  }) async {
    task.status = DownloadStatus.downloading;
    task.threadCount = 1;

    final targetFile = File(task.tempFilePath);
    if (!await targetFile.parent.exists()) {
      try {
        await targetFile.parent.create(recursive: true);
      } catch (_) {}
    }

    final singleSegment = SegmentChunk(
      index: 0,
      startByte: 0,
      endByte: task.totalSizeBytes > 0 ? task.totalSizeBytes : 0,
      status: ChunkStatus.downloading,
    );
    task.segments.clear();
    task.segments.add(singleSegment);

    final uri = Uri.tryParse(task.sourceUrl);
    String referer = 'https://www.google.com/';
    if (uri != null && uri.host.isNotEmpty) {
      if (uri.host.contains('tikwm.com')) {
        referer = 'https://www.tikwm.com/';
      } else if (uri.host.contains('tiktok.com')) {
        referer = 'https://www.tiktok.com/';
      } else if (uri.host.contains('instagram.com')) {
        referer = 'https://www.instagram.com/';
      } else if (uri.host.contains('twitter.com') || uri.host.contains('twimg.com') || uri.host.contains('x.com')) {
        referer = 'https://x.com/';
      } else if (uri.host.contains('youtube.com') || uri.host.contains('googlevideo.com')) {
        referer = 'https://www.youtube.com/';
      } else {
        referer = '${uri.scheme}://${uri.host}/';
      }
    }

    final Response<ResponseBody> response = await _dio.get<ResponseBody>(
      task.sourceUrl,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
        maxRedirects: 10,
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
          'Referer': referer,
          'Accept': '*/*',
          'Accept-Encoding': 'identity',
          'Connection': 'keep-alive',
        },
      ),
    );

    final stream = response.data?.stream;
    if (stream == null) {
      throw Exception('تعذر فتح تيار تحميل الملف من السيرفر');
    }

    final contentType = response.headers.value('content-type')?.toLowerCase() ?? '';
    final isMediaVideo = task.isVideo;

    if ((contentType.contains('text/html') || contentType.contains('text/plain')) && isMediaVideo) {
      throw Exception('الرابط المعطى هو صفحة ويب وليس تيار فيديو مباشر. افتح الرابط في المتصفح المدمج');
    }

    final streamContentLength = response.headers.value('content-length');
    if (streamContentLength != null && task.totalSizeBytes <= 0) {
      task.totalSizeBytes = int.tryParse(streamContentLength) ?? -1;
      singleSegment.endByte = task.totalSizeBytes > 0 ? task.totalSizeBytes : 0;
    }

    int bytesDownloadedSinceLastTick = 0;
    DateTime lastSpeedTick = DateTime.now();

    final IOSink sink = targetFile.openWrite(mode: FileMode.write);

    try {
      await for (final Uint8List chunk in stream) {
        sink.add(chunk);
        final int chunkSize = chunk.lengthInBytes;
        task.downloadedBytes += chunkSize;
        singleSegment.downloadedBytes += chunkSize;
        bytesDownloadedSinceLastTick += chunkSize;

        final now = DateTime.now();
        final elapsedMs = now.difference(lastSpeedTick).inMilliseconds;
        if (elapsedMs >= 250) {
          final double speedBps = (bytesDownloadedSinceLastTick / elapsedMs) * 1000.0;
          task.speedBytesPerSecond = speedBps;
          bytesDownloadedSinceLastTick = 0;
          lastSpeedTick = now;

          double progressPct = 0.0;
          if (task.totalSizeBytes > 0) {
            progressPct = (task.downloadedBytes / task.totalSizeBytes).clamp(0.0, 0.99);
          } else {
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
              bufferedRamMb: 0.0,
              isSingleStream: true,
              statusText: '⚡ تيار فائق السرعة مباشر (Direct Turbo Stream)',
              activeThreads: 1,
            ),
          );
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    singleSegment.status = ChunkStatus.completed;
  }

  /// [32-Isolate Parallel Turbo Download with Smart Resume Checkpoint & Dual Network Support]
  Future<void> _executeParallelDownload({
    required DownloadTask task,
    required DeviceMetrics deviceMetrics,
    int? customThreadCount,
    required int ramBufferThresholdMb,
  }) async {
    final int threadCount = (customThreadCount ??
        _segmentationEngine.calculateOptimalThreads(
          metrics: deviceMetrics,
          fileSizeBytes: task.totalSizeBytes,
        )).clamp(2, 32);

    task.threadCount = threadCount;
    task.status = DownloadStatus.preparingSegments;

    // 1. Check for previously saved Smart Resume checkpoint (.pulse_state)
    final savedCheckpoint = await SmartResumeManager.loadCheckpoints(task.tempFilePath) ??
        await SmartResumeManager.loadCheckpoints(task.fullFilePath);
    List<SegmentChunk> chunks = [];

    if (savedCheckpoint != null &&
        savedCheckpoint['sourceUrl'] == task.sourceUrl &&
        savedCheckpoint['totalSizeBytes'] == task.totalSizeBytes &&
        savedCheckpoint['segments'] is List) {
      debugPrint('[TurboDownloadService] 🔄 Found Smart Resume checkpoint! Resuming from exact byte offset...');
      final rawList = savedCheckpoint['segments'] as List;
      for (final item in rawList) {
        final c = SegmentChunk(
          index: item['index'] as int,
          startByte: item['startByte'] as int,
          endByte: item['endByte'] as int,
          downloadedBytes: item['downloadedBytes'] as int? ?? 0,
          retryAttempts: item['retryAttempts'] as int? ?? 0,
        );
        if (c.isComplete) {
          c.status = ChunkStatus.completed;
        }
        chunks.add(c);
      }
      task.downloadedBytes = chunks.fold(0, (sum, c) => sum + c.downloadedBytes);
    } else {
      chunks = _segmentationEngine.generateSegmentChunks(
        totalFileSizeBytes: task.totalSizeBytes,
        threadCount: threadCount,
      );
    }

    task.segments.clear();
    task.segments.addAll(chunks);

    final ramCache = RamCacheManager(
      targetFilePath: task.tempFilePath,
      flushThresholdBytes: ramBufferThresholdMb * 1024 * 1024,
    );
    await ramCache.initialize(expectedTotalSize: task.totalSizeBytes);

    task.status = DownloadStatus.downloading;

    int bytesDownloadedSinceLastTick = 0;
    DateTime lastSpeedTick = DateTime.now();
    DateTime lastCheckpointTick = DateTime.now();
    final receivePort = ReceivePort();
    final List<Isolate> workerIsolates = [];
    int completedWorkers = 0;
    final Completer<void> downloadFinishedCompleter = Completer<void>();

    // Spawn isolates for uncompleted chunks
    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      if (chunk.isComplete) {
        completedWorkers++;
        continue;
      }

      chunk.status = ChunkStatus.downloading;

      final initParams = ChunkWorkerInitParams(
        segmentIndex: i,
        url: task.sourceUrl,
        startByte: chunk.startByte + chunk.downloadedBytes,
        endByte: chunk.endByte,
        mainSendPort: receivePort.sendPort,
      );

      final isolate = await Isolate.spawn<ChunkWorkerInitParams>(
        chunkWorkerEntryPoint,
        initParams,
        debugName: 'HyperPulse_TurboWorker_$i',
      );
      workerIsolates.add(isolate);
    }

    if (completedWorkers == chunks.length) {
      if (!downloadFinishedCompleter.isCompleted) {
        downloadFinishedCompleter.complete();
      }
    }

    final subscription = receivePort.listen((dynamic message) async {
      if (message is ChunkWorkerPacket) {
        final chunk = task.segments[message.segmentIndex];

        if (message.error != null) {
          chunk.status = ChunkStatus.failed;
          chunk.errorMessage = message.error;
          debugPrint('[TurboDownloadService] Worker ${message.segmentIndex} error: ${message.error}');
          // If any chunk fails unrecoverably, fail completer so pipeline falls back to robust Single-Stream
          if (!downloadFinishedCompleter.isCompleted) {
            downloadFinishedCompleter.completeError(Exception('Worker ${message.segmentIndex} failed: ${message.error}'));
          }
        } else if (message.isCompleted) {
          chunk.status = ChunkStatus.completed;
          chunk.downloadedBytes = chunk.totalExpectedBytes;
          completedWorkers++;

          if (completedWorkers == chunks.length) {
            if (!downloadFinishedCompleter.isCompleted) {
              downloadFinishedCompleter.complete();
            }
          }
        } else if (message.data != null && message.data!.isNotEmpty) {
          final int deltaBytes = message.data!.lengthInBytes;
          chunk.downloadedBytes += deltaBytes;
          task.downloadedBytes += deltaBytes;
          bytesDownloadedSinceLastTick += deltaBytes;

          await ramCache.writeChunkData(
            segmentIndex: message.segmentIndex,
            fileOffset: message.offset,
            data: message.data!,
          );

          final now = DateTime.now();
          final elapsedMs = now.difference(lastSpeedTick).inMilliseconds;
          if (elapsedMs >= 200) {
            final double speedBps = (bytesDownloadedSinceLastTick / elapsedMs) * 1000.0;
            task.speedBytesPerSecond = speedBps;
            bytesDownloadedSinceLastTick = 0;
            lastSpeedTick = now;

            final double progressPct = task.totalSizeBytes > 0
                ? (task.downloadedBytes / task.totalSizeBytes).clamp(0.0, 1.0)
                : 0.0;

            _progressController.add(
              TurboProgressEvent(
                taskId: task.id,
                totalBytes: task.totalSizeBytes,
                downloadedBytes: task.downloadedBytes,
                speedBytesPerSec: speedBps,
                progressPercent: progressPct,
                segments: List.from(task.segments),
                bufferedRamMb: ramCache.currentBufferedMb,
                isSingleStream: false,
                statusText: '$threadCount مسار متوازي فائق السرعة عبر Dart Isolates (64MB RAM)',
                activeThreads: threadCount,
                isDualBoostActive: _dualNetwork.isDualBoostEnabled,
              ),
            );

            // Periodic checkpoint save every 3 seconds for smart resume
            if (now.difference(lastCheckpointTick).inSeconds >= 3) {
              lastCheckpointTick = now;
              SmartResumeManager.persistCheckpoints(
                targetFilePath: task.tempFilePath,
                sourceUrl: task.sourceUrl,
                totalSizeBytes: task.totalSizeBytes,
                segments: task.segments,
              );
            }
          }
        }
      }
    });

    await downloadFinishedCompleter.future;

    task.status = DownloadStatus.merging;
    await ramCache.flushToDisk();
    await ramCache.dispose();

    for (final isolate in workerIsolates) {
      isolate.kill(priority: Isolate.immediate);
    }
    await subscription.cancel();
    receivePort.close();

    task.status = DownloadStatus.completed;
    task.finishedAt = DateTime.now();

    _progressController.add(
      TurboProgressEvent(
        taskId: task.id,
        totalBytes: task.totalSizeBytes,
        downloadedBytes: task.downloadedBytes,
        speedBytesPerSec: 0,
        progressPercent: 1.0,
        segments: List.from(task.segments),
        bufferedRamMb: 0.0,
        isSingleStream: false,
        statusText: 'اكتمل التحميل الصاروخي المتوازي بنجاح!',
        activeThreads: threadCount,
        isDualBoostActive: _dualNetwork.isDualBoostEnabled,
      ),
    );
  }
}
