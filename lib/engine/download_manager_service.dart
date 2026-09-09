import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/download_task.dart';
import '../models/segment_chunk.dart';
import '../models/device_metrics.dart';
import '../engine/turbo_download_service.dart';
import '../engine/cloud_extractor_service.dart';
import '../engine/storage_path_resolver.dart';
import '../engine/smart_url_filter.dart';
import '../engine/android_system_bridge.dart';
import '../engine/audio_extractor_service.dart';
import '../engine/smart_resume_manager.dart';
import '../engine/watermark_service.dart';

/// [DownloadManagerService] is the central task manager orchestrating:
/// 1. Active Downloads Queue with Pause, Resume, Cancel.
/// 2. Finished Downloads Library with Instant APK Install, Video/Audio Play, and Open in File Manager.
/// 3. In-App Browser Download Catching & Auto-naming with correct extensions (.apk, .mp4, etc.)
/// 4. Resilient Persistence across complete app exits and phone reboots.
class DownloadManagerService extends ChangeNotifier {
  static final DownloadManagerService _instance = DownloadManagerService._internal();
  factory DownloadManagerService() => _instance;
  DownloadManagerService._internal();

  final List<DownloadTask> _activeTasks = [];
  final List<DownloadTask> _completedTasks = [];
  final TurboDownloadService _turboService = TurboDownloadService();
  final CloudExtractorService _cloudExtractor = CloudExtractorService();

  final Map<String, StreamSubscription<TurboProgressEvent>> _subscriptions = {};
  bool _isInitialized = false;

  List<DownloadTask> get activeTasks => List.unmodifiable(_activeTasks);
  List<DownloadTask> get completedTasks => List.unmodifiable(_completedTasks);

  DownloadTask? get latestActiveTask => _activeTasks.isNotEmpty ? _activeTasks.first : null;

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

  /// Initializes the service, restoring any active/paused tasks from disk
  Future<void> init() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await _loadPersistedTasks();
    await refreshCompletedDownloadsFromStorage();
  }

  /// Path to task registry file
  Future<String> _getRegistryFilePath() async {
    final baseDir = await StoragePathResolver.resolveDownloadDirectory(isMediaVideo: false);
    return '$baseDir/.hyperpulse_tasks_registry.json';
  }

  /// Saves active and paused tasks to disk
  Future<void> _persistTasksState() async {
    try {
      final registryPath = await _getRegistryFilePath();
      final file = File(registryPath);
      final list = _activeTasks.map((t) => t.toJson()).toList();
      await file.writeAsString(jsonEncode(list), flush: true);
    } catch (e) {
      debugPrint('[DownloadManagerService] Error saving tasks registry: $e');
    }
  }

  /// Restores active and paused tasks from disk after app restart
  Future<void> _loadPersistedTasks() async {
    try {
      final registryPath = await _getRegistryFilePath();
      final file = File(registryPath);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (content.isNotEmpty) {
          final List<dynamic> decoded = jsonDecode(content);
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              final task = DownloadTask.fromJson(item);
              // If it was downloading when app closed, set to paused so user can resume seamlessly
              if (task.status == DownloadStatus.downloading || task.status == DownloadStatus.analyzing) {
                task.status = DownloadStatus.paused;
                task.speedBytesPerSecond = 0;
              }

              // Try to reload segment state if available
              final state = await SmartResumeManager.loadCheckpoints(task.fullFilePath);
              if (state != null && state['segments'] is List) {
                task.segments.clear();
                for (final segJson in state['segments']) {
                  if (segJson is Map<String, dynamic>) {
                    task.segments.add(SegmentChunk.fromJson(segJson));
                  }
                }
                final sumDownloaded = task.segments.fold<int>(0, (prev, s) => prev + s.downloadedBytes);
                if (sumDownloaded > 0) {
                  task.downloadedBytes = sumDownloaded;
                }
              }

              if (!_activeTasks.any((t) => t.id == task.id)) {
                _activeTasks.add(task);
              }
            }
          }
        }
      }

      // Also scan directory for any orphan .pulse_state files
      await _recoverOrphanStateFiles();
      notifyListeners();
    } catch (e) {
      debugPrint('[DownloadManagerService] Error loading persisted tasks: $e');
    }
  }

  /// Helper to safely list files in a directory without throwing on permission errors
  List<File> _safeListFiles(Directory dir) {
    try {
      if (!dir.existsSync()) return [];
      return dir.listSync().whereType<File>().toList();
    } catch (_) {
      return [];
    }
  }

  /// Recovers any .pulse_state files in download folders
  Future<void> _recoverOrphanStateFiles() async {
    try {
      final downloadsDir = await StoragePathResolver.resolveDownloadDirectory(isMediaVideo: false);
      final moviesDir = await StoragePathResolver.resolveMoviesDirectory();

      final searchDirs = [Directory(downloadsDir), Directory(moviesDir)];
      for (final dir in searchDirs) {
        if (!await dir.exists()) continue;
        final entries = _safeListFiles(dir);
        for (final entry in entries) {
          if (entry.path.endsWith('.pulse_state')) {
            final targetFilePath = entry.path.replaceAll('.pulse_state', '');
            final fileName = p.basename(targetFilePath);
            final bool alreadyTracked = _activeTasks.any((t) => t.fileName == fileName) ||
                _completedTasks.any((t) => t.fileName == fileName);

            if (!alreadyTracked) {
              final stateData = await SmartResumeManager.loadCheckpoints(targetFilePath);
              if (stateData != null) {
                final sourceUrl = stateData['sourceUrl']?.toString() ?? '';
                final totalSize = stateData['totalSizeBytes'] as int? ?? 0;
                final segs = <SegmentChunk>[];
                if (stateData['segments'] is List) {
                  for (final s in stateData['segments']) {
                    if (s is Map<String, dynamic>) {
                      segs.add(SegmentChunk.fromJson(s));
                    }
                  }
                }
                final sumDownloaded = segs.fold<int>(0, (prev, s) => prev + s.downloadedBytes);

                final recoveredTask = DownloadTask(
                  id: 'recovered_${DateTime.now().millisecondsSinceEpoch}_${fileName.hashCode}',
                  sourceUrl: sourceUrl,
                  fileName: fileName,
                  destinationDirectory: entry.parent.path,
                  totalSizeBytes: totalSize,
                  downloadedBytes: sumDownloaded,
                  status: DownloadStatus.paused,
                  segments: segs,
                  threadCount: segs.isNotEmpty ? segs.length : 16,
                );
                _activeTasks.add(recoveredTask);
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[DownloadManagerService] Error recovering orphan state files: $e');
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
        scannedFiles.addAll(_safeListFiles(mDir));
      }

      final dDir = Directory(downloadsDir);
      if (await dDir.exists()) {
        scannedFiles.addAll(_safeListFiles(dDir));
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

        // Never re-add files that belong to currently active or paused tasks
        final bool isCurrentlyActive = _activeTasks.any((t) => t.fullFilePath == file.path || t.fileName == filename);
        if (isCurrentlyActive) {
          continue;
        }

        final bool alreadyExists = _completedTasks.any((t) => t.fullFilePath == file.path);
        if (!alreadyExists) {
          final stat = file.statSync();
          // Filter out 0-byte or corrupted broken files
          if (stat.size <= 2048) {
            continue;
          }

          // If APK, verify it is a 100% complete and valid zip/apk container with End of Central Directory
          if (filename.toLowerCase().endsWith('.apk')) {
            try {
              final fileLength = file.lengthSync();
              if (fileLength < 22) continue; // Minimum valid ZIP is 22 bytes
              final raf = file.openSync();
              // 1. Verify Local File Header (PK\x03\x04)
              final headerBytes = raf.readSync(4);
              if (headerBytes.length < 4 ||
                  headerBytes[0] != 0x50 ||
                  headerBytes[1] != 0x4B ||
                  headerBytes[2] != 0x03 ||
                  headerBytes[3] != 0x04) {
                raf.closeSync();
                continue;
              }
              // 2. Verify End of Central Directory (PK\x05\x06) in the last 1024 bytes
              final seekPos = (fileLength - 1024).clamp(0, fileLength);
              raf.setPositionSync(seekPos);
              final tailBytes = raf.readSync(fileLength - seekPos);
              raf.closeSync();

              bool hasEocd = false;
              for (int i = 0; i <= tailBytes.length - 4; i++) {
                if (tailBytes[i] == 0x50 &&
                    tailBytes[i + 1] == 0x4B &&
                    tailBytes[i + 2] == 0x05 &&
                    tailBytes[i + 3] == 0x06) {
                  hasEocd = true;
                  break;
                }
              }
              if (!hasEocd) {
                // Incomplete / truncated APK. Do not treat as completed!
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
    final isYouTube = CloudExtractorService.isYouTubeUrl(cleanUrl);
    final isSocial = !isYouTube && CloudExtractorService.isSocialVideoPlatform(cleanUrl);

    String directUrl = cleanUrl;
    String inferredName = preferredTitle ?? 'file_${DateTime.now().millisecondsSinceEpoch}';
    bool isVideo = isYouTube || isSocial;
    bool isApk = cleanUrl.toLowerCase().contains('.apk') || inferredName.toLowerCase().endsWith('.apk');

    if (isYouTube) {
      // Direct YouTube stream handling with authentic video title resolution
      final ytId = CloudExtractorService.extractYouTubeVideoId(cleanUrl);
      if (preferredTitle == null || preferredTitle.isEmpty || preferredTitle.startsWith('YouTube_')) {
        final realTitle = await CloudExtractorService.fetchYouTubeRealTitle(cleanUrl);
        if (realTitle != null && realTitle.isNotEmpty) {
          inferredName = '$realTitle.mp4';
        } else {
          inferredName = 'YouTube_${ytId ?? DateTime.now().millisecondsSinceEpoch}.mp4';
        }
      } else if (!inferredName.toLowerCase().endsWith('.mp4') && !inferredName.toLowerCase().endsWith('.mkv')) {
        inferredName = '$inferredName.mp4';
      }
      isVideo = true;
      directUrl = cleanUrl;
    } else if (isSocial) {
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

    // Sanitize file name for Android filesystem safety
    inferredName = StoragePathResolver.sanitizeFileName(
      inferredName,
      fallbackExtension: isVideo ? 'mp4' : (isApk ? 'apk' : 'bin'),
    );

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
    _persistTasksState();
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
      _persistTasksState();
      notifyListeners();

      // Ensure foreground service is running so OS doesn't kill downloads on app switch/exit
      await AndroidSystemBridge.startForegroundService();

      final subscription = _turboService.progressStream.listen((event) {
        if (event.taskId == task.id) {
          task.downloadedBytes = event.downloadedBytes;
          task.totalSizeBytes = event.totalBytes;
          task.speedBytesPerSecond = event.speedBytesPerSec;
          if (event.segments.isNotEmpty) {
            task.segments.clear();
            task.segments.addAll(event.segments);
          }
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
      _persistTasksState();

      _subscriptions[task.id]?.cancel();
      _subscriptions.remove(task.id);

      // Apply watermark if video
      if (task.isVideo && File(task.fullFilePath).existsSync()) {
        try {
          await WatermarkService().applyWatermarkToVideo(task.fullFilePath);
        } catch (e) {
          debugPrint('[DownloadManagerService] Watermark notice: $e');
        }
      }

      // Export to Public Storage (Gallery for Videos, Download/HyperPulse for APKs)
      if (File(task.fullFilePath).existsSync()) {
        try {
          final exportedPath = await AndroidSystemBridge.exportToPublicStorage(task.fullFilePath);
          if (exportedPath.isNotEmpty && File(exportedPath).existsSync()) {
            task.destinationDirectory = p.dirname(exportedPath);
            task.fileName = p.basename(exportedPath);
          }
        } catch (e) {
          debugPrint('[DownloadManagerService] Export to public storage notice: $e');
        }
      }

      // Audio Extraction if requested
      if (extractMp3 && File(task.fullFilePath).existsSync()) {
        final res = await AudioExtractorService.extractToMp3(
          videoFilePath: task.fullFilePath,
          deleteOriginal: false,
        );
        if (res.success && res.outputPath != null) {
          await AndroidSystemBridge.exportToPublicStorage(res.outputPath!);
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
      _persistTasksState();

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
      _persistTasksState();
      notifyListeners();
    }
  }

  /// Resumes a paused download
  void resumeTask(String taskId) {
    final taskIndex = _activeTasks.indexWhere((t) => t.id == taskId);
    if (taskIndex != -1) {
      final task = _activeTasks[taskIndex];
      task.status = DownloadStatus.downloading;
      _persistTasksState();
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
      _persistTasksState();

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
