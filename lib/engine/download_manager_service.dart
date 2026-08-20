import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/download_task.dart';
import '../models/device_metrics.dart';
import '../engine/turbo_download_service.dart';
import '../engine/cloud_extractor_service.dart';
import '../engine/storage_path_resolver.dart';
import '../engine/smart_url_filter.dart';
import '../engine/android_system_bridge.dart';
import '../engine/audio_extractor_service.dart';

/// [DownloadManagerService] is the central task manager orchestrating:
/// 1. Active Downloads Queue with Pause, Resume, Cancel.
/// 2. Finished Downloads Library with Instant APK Install, Video/Audio Play, and Open in File Manager.
/// 3. In-App Browser Download Catching & Auto-naming with correct extensions (.apk, .mp4, etc.)
class DownloadManagerService extends ChangeNotifier {
  static final DownloadManagerService _instance = DownloadManagerService._internal();
  factory DownloadManagerService() => _instance;
  DownloadManagerService._internal();

  final List<DownloadTask> _activeTasks = [];
  final List<DownloadTask> _completedTasks = [];
  final TurboDownloadService _turboService = TurboDownloadService();
  final CloudExtractorService _cloudExtractor = CloudExtractorService();

  final Map<String, StreamSubscription<TurboProgressEvent>> _subscriptions = {};

  List<DownloadTask> get activeTasks => List.unmodifiable(_activeTasks);
  List<DownloadTask> get completedTasks => List.unmodifiable(_completedTasks);

  int get activeCount =>
      _activeTasks.where((t) => t.status == DownloadStatus.downloading || t.status == DownloadStatus.analyzing || t.status == DownloadStatus.preparingSegments).length;

  double get totalSpeedBytesPerSecond {
    double total = 0.0;
    for (final task in _activeTasks) {
      if (task.status == DownloadStatus.downloading) {
        total += task.speedBytesPerSecond;
      }
    }
    return total;
  }

  String get formattedTotalSpeed {
    final speed = totalSpeedBytesPerSecond;
    if (speed < 1024) {
      return '${speed.toStringAsFixed(0)} B/s';
    } else if (speed < 1024 * 1024) {
      return '${(speed / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(speed / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    }
  }

  /// Pauses all currently active downloads
  void pauseAll() {
    final activeIds = _activeTasks
        .where((t) => t.status == DownloadStatus.downloading || t.status == DownloadStatus.analyzing)
        .map((t) => t.id)
        .toList();
    for (final id in activeIds) {
      pauseTask(id);
    }
  }

  /// Resumes all paused downloads
  void resumeAll() {
    final pausedIds = _activeTasks
        .where((t) => t.status == DownloadStatus.paused || t.status == DownloadStatus.failed)
        .map((t) => t.id)
        .toList();
    for (final id in pausedIds) {
      resumeTask(id);
    }
  }

  /// Cancels all active downloads
  void cancelAll() {
    final allIds = _activeTasks.map((t) => t.id).toList();
    for (final id in allIds) {
      cancelTask(id);
    }
  }

  /// Retries a failed download task
  void retryTask(String taskId) {
    final taskIndex = _activeTasks.indexWhere((t) => t.id == taskId);
    if (taskIndex != -1) {
      final task = _activeTasks[taskIndex];
      task.status = DownloadStatus.downloading;
      task.error = null;
      task.downloadedBytes = 0;
      notifyListeners();
      _startTaskExecution(task);
    }
  }

  /// Scans destination folders to populate completed downloads on startup
  Future<void> refreshCompletedDownloadsFromStorage() async {
    try {
      final moviesDir = await StoragePathResolver.resolveMoviesDirectory();
      final downloadsDir = await StoragePathResolver.resolveDownloadDirectory(isMediaVideo: false);

      final scannedFiles = <File>[];

      final mDir = Directory(moviesDir);
      if (await mDir.exists()) {
        scannedFiles.addAll(mDir.listSync().whereType<File>());
      }

      final dDir = Directory(downloadsDir);
      if (await dDir.exists()) {
        scannedFiles.addAll(dDir.listSync().whereType<File>());
      }

      for (final file in scannedFiles) {
        final filename = p.basename(file.path);
        // Avoid temporary, lock, partial, and state files
        if (filename.startsWith('.') ||
            filename.endsWith('.part') ||
            filename.endsWith('.tmp') ||
            filename.endsWith('.hyperpulse_part') ||
            filename.endsWith('.pulse_state')) {
          continue;
        }

        final bool alreadyExists = _completedTasks.any((t) => t.fullFilePath == file.path);
        if (!alreadyExists) {
          final stat = file.statSync();
          // Filter out 0-byte or corrupted broken files
          if (stat.size <= 2048) {
            continue;
          }

          // If APK, verify it is a valid zip/apk container
          if (filename.toLowerCase().endsWith('.apk')) {
            try {
              final headerBytes = file.openSync().readSync(4);
              if (headerBytes.length < 4 ||
                  headerBytes[0] != 0x50 ||
                  headerBytes[1] != 0x4B ||
                  headerBytes[2] != 0x03 ||
                  headerBytes[3] != 0x04) {
                // Not a valid APK binary, skip
                continue;
              }
            } catch (_) {
              continue;
            }
          }

          final task = DownloadTask(
            id: 'local_${stat.modified.millisecondsSinceEpoch}_${filename.hashCode}',
            sourceUrl: '',
            fileName: filename,
            destinationDirectory: file.parent.path,
            totalSizeBytes: stat.size,
            downloadedBytes: stat.size,
            status: DownloadStatus.completed,
            createdAt: stat.modified,
            finishedAt: stat.modified,
          );
          _completedTasks.add(task);
        }
      }

      // Sort newest first
      _completedTasks.sort((a, b) => (b.finishedAt ?? b.createdAt).compareTo(a.finishedAt ?? a.createdAt));
      notifyListeners();
    } catch (e) {
      debugPrint('[DownloadManagerService] Error scanning files: $e');
    }
  }

  /// Start or queue a new download
  Future<DownloadTask> enqueueDownload({
    required String url,
    String? preferredTitle,
    bool extractMp3 = false,
  }) async {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(url.trim());
    final isSocial = CloudExtractorService.isSocialVideoPlatform(cleanUrl);

    String directUrl = cleanUrl;
    String inferredName = preferredTitle ?? 'file_${DateTime.now().millisecondsSinceEpoch}';
    bool isVideo = isSocial;
    bool isApk = cleanUrl.toLowerCase().contains('.apk') || inferredName.toLowerCase().endsWith('.apk');

    if (isSocial) {
      final cloudRes = await _cloudExtractor.extractDirectMedia(cleanUrl);
      if (cloudRes.success) {
        directUrl = cloudRes.directStreamUrl;
        inferredName = cloudRes.title;
        isVideo = true;
      } else {
        throw Exception(cloudRes.errorMessage ?? 'تعذر استخراج تيار الفيديو المباشر من هذا الرابط');
      }
    } else {
      // Check extension from URL
      final ext = SmartUrlFilter.inferFileExtension(cleanUrl);
      if (ext != null) {
        if (!inferredName.toLowerCase().endsWith('.$ext')) {
          inferredName = '$inferredName.$ext';
        }
        if (ext == 'apk') isApk = true;
        if (['mp4', 'mkv', 'webm', 'mov'].contains(ext)) isVideo = true;
      }
    }

    inferredName = inferredName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (inferredName.isEmpty) {
      inferredName = 'HyperPulse_${DateTime.now().millisecondsSinceEpoch}';
    }

    if (isVideo && !inferredName.toLowerCase().endsWith('.mp4')) {
      inferredName = '$inferredName.mp4';
    }

    final destinationDir = await StoragePathResolver.resolveDownloadDirectory(
      isMediaVideo: isVideo,
    );

    final task = DownloadTask(
      id: 'task_${DateTime.now().millisecondsSinceEpoch}_${_activeTasks.length}',
      sourceUrl: directUrl,
      fileName: inferredName,
      destinationDirectory: destinationDir,
      status: DownloadStatus.analyzing,
    );

    _activeTasks.insert(0, task);
    notifyListeners();

    _startTaskExecution(task, extractMp3: extractMp3, isSocial: isSocial);
    return task;
  }

  Future<void> _startTaskExecution(
    DownloadTask task, {
    bool extractMp3 = false,
    bool isSocial = false,
  }) async {
    try {
      task.status = DownloadStatus.downloading;
      notifyListeners();

      // Ensure foreground service is running so OS doesn't kill downloads on app switch/exit
      await AndroidSystemBridge.startForegroundService();

      final subscription = _turboService.progressStream.listen((event) {
        if (event.taskId == task.id) {
          task.downloadedBytes = event.downloadedBytes;
          task.totalSizeBytes = event.totalBytes;
          task.speedBytesPerSecond = event.speedBytesPerSec;
          notifyListeners();
        }
      });
      _subscriptions[task.id] = subscription;

      final deviceProfile = DeviceMetrics(
        totalRamMb: 8192,
        availableRamMb: 4096,
        logicalCores: 8,
        currentNetworkSpeedMbps: 180.0,
        latencyMs: 22,
      );

      await _turboService.startDownload(
        task: task,
        deviceMetrics: deviceProfile,
        ramBufferThresholdMb: 64,
        forceSingleStream: isSocial,
      );

      // On completion:
      task.status = DownloadStatus.completed;
      task.finishedAt = DateTime.now();
      _activeTasks.removeWhere((t) => t.id == task.id);
      _completedTasks.insert(0, task);

      _subscriptions[task.id]?.cancel();
      _subscriptions.remove(task.id);

      // Trigger MediaScanner for media files
      if (File(task.fullFilePath).existsSync()) {
        await AndroidSystemBridge.scanMediaFile(task.fullFilePath);
      }

      // Audio Extraction if requested
      if (extractMp3 && File(task.fullFilePath).existsSync()) {
        final res = await AudioExtractorService.extractToMp3(
          videoFilePath: task.fullFilePath,
          deleteOriginal: false,
        );
        if (res.success && res.outputPath != null) {
          await AndroidSystemBridge.scanMediaFile(res.outputPath!);
        }
      }

      if (activeCount == 0) {
        await AndroidSystemBridge.stopForegroundService();
      }

      notifyListeners();
    } catch (e) {
      debugPrint('[DownloadManagerService] Download error: $e');
      task.status = DownloadStatus.failed;
      task.error = e.toString();
      _subscriptions[task.id]?.cancel();
      _subscriptions.remove(task.id);

      if (activeCount == 0) {
        await AndroidSystemBridge.stopForegroundService();
      }

      notifyListeners();
    }
  }

  /// Pauses an active download
  void pauseTask(String taskId) {
    final taskIndex = _activeTasks.indexWhere((t) => t.id == taskId);
    if (taskIndex != -1) {
      final task = _activeTasks[taskIndex];
      task.status = DownloadStatus.paused;
      task.speedBytesPerSecond = 0;
      _subscriptions[taskId]?.cancel();
      _subscriptions.remove(taskId);
      notifyListeners();
    }
  }

  /// Resumes a paused download
  void resumeTask(String taskId) {
    final taskIndex = _activeTasks.indexWhere((t) => t.id == taskId);
    if (taskIndex != -1) {
      final task = _activeTasks[taskIndex];
      task.status = DownloadStatus.downloading;
      notifyListeners();
      _startTaskExecution(task);
    }
  }

  /// Cancels an active download
  void cancelTask(String taskId) {
    final taskIndex = _activeTasks.indexWhere((t) => t.id == taskId);
    if (taskIndex != -1) {
      final task = _activeTasks[taskIndex];
      task.status = DownloadStatus.canceled;
      _subscriptions[taskId]?.cancel();
      _subscriptions.remove(taskId);
      _activeTasks.removeAt(taskIndex);

      // Attempt to clean partial file
      try {
        final file = File(task.fullFilePath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {}

      notifyListeners();
    }
  }

  /// Opens or installs the completed file
  Future<bool> openOrInstallFile(DownloadTask task) async {
    final path = task.fullFilePath;
    final file = File(path);
    if (!file.existsSync()) {
      return false;
    }

    if (path.toLowerCase().endsWith('.apk')) {
      return await AndroidSystemBridge.installApk(path);
    } else {
      return await AndroidSystemBridge.openFile(path);
    }
  }

  /// Deletes a completed download from disk and list
  Future<void> deleteCompletedTask(DownloadTask task) async {
    try {
      final file = File(task.fullFilePath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}

    _completedTasks.removeWhere((t) => t.id == task.id);
    notifyListeners();
  }
}
