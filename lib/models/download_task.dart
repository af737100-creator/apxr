import 'segment_chunk.dart';

/// Overall state of a download operation.
enum DownloadStatus {
  idle,
  analyzing,
  preparingSegments,
  downloading,
  paused,
  merging,
  completed,
  failed,
  canceled,
}

/// Comprehensive model holding task metadata, progress, and segment states.
class DownloadTask {
  final String id;
  String sourceUrl;
  String fileName;
  String destinationDirectory;
  int totalSizeBytes;
  int downloadedBytes;
  DownloadStatus status;
  double speedBytesPerSecond;
  int threadCount;
  final List<SegmentChunk> segments;
  String? error;
  DateTime createdAt;
  DateTime? finishedAt;

  DownloadTask({
    required this.id,
    required this.sourceUrl,
    required this.fileName,
    required this.destinationDirectory,
    this.totalSizeBytes = 0,
    this.downloadedBytes = 0,
    this.status = DownloadStatus.idle,
    this.speedBytesPerSecond = 0.0,
    this.threadCount = 4,
    List<SegmentChunk>? segments,
    this.error,
    DateTime? createdAt,
    this.finishedAt,
  })  : segments = segments ?? [],
        createdAt = createdAt ?? DateTime.now();

  String get fullFilePath => '$destinationDirectory/$fileName';
  set fullFilePath(String newPath) {
    final lastSlash = newPath.lastIndexOf('/');
    if (lastSlash != -1) {
      destinationDirectory = newPath.substring(0, lastSlash);
      fileName = newPath.substring(lastSlash + 1);
    } else {
      fileName = newPath;
    }
  }

  String get tempFilePath => '$destinationDirectory/$fileName.hyperpulse_part';
  set tempFilePath(String _) {
    // Getter automatically resolves to $destinationDirectory/$fileName.hyperpulse_part
  }

  String get fileExtension {
    if (fileName.contains('.')) {
      return fileName.split('.').last.toLowerCase();
    }
    return '';
  }

  bool get isApk => fileExtension == 'apk';
  bool get isVideo => ['mp4', 'mkv', 'webm', 'mov', 'avi', 'flv', '3gp'].contains(fileExtension);
  bool get isAudio => ['mp3', 'm4a', 'flac', 'wav', 'aac', 'ogg'].contains(fileExtension);
  bool get isArchive => ['zip', 'rar', '7z', 'tar', 'gz', 'iso'].contains(fileExtension);
  bool get isDocument => ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'epub'].contains(fileExtension);

  double get progress {
    if (totalSizeBytes <= 0) return 0.0;
    return (downloadedBytes / totalSizeBytes).clamp(0.0, 1.0);
  }

  String get formattedSpeed {
    if (speedBytesPerSecond < 1024) {
      return '${speedBytesPerSecond.toStringAsFixed(0)} B/s';
    } else if (speedBytesPerSecond < 1024 * 1024) {
      return '${(speedBytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(speedBytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    }
  }

  String get formattedTotalSize {
    if (totalSizeBytes < 1024 * 1024) {
      return '${(totalSizeBytes / 1024).toStringAsFixed(1)} KB';
    } else if (totalSizeBytes < 1024 * 1024 * 1024) {
      return '${(totalSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    } else {
      return '${(totalSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sourceUrl': sourceUrl,
    'fileName': fileName,
    'destinationDirectory': destinationDirectory,
    'totalSizeBytes': totalSizeBytes,
    'downloadedBytes': downloadedBytes,
    'status': status.name,
    'speedBytesPerSecond': speedBytesPerSecond,
    'threadCount': threadCount,
    'segments': segments.map((s) => s.toJson()).toList(),
    'error': error,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
  };

  factory DownloadTask.fromJson(Map<String, dynamic> json) {
    final segs = <SegmentChunk>[];
    if (json['segments'] is List) {
      for (final s in json['segments']) {
        if (s is Map<String, dynamic>) {
          segs.add(SegmentChunk.fromJson(s));
        }
      }
    }

    return DownloadTask(
      id: json['id'] as String? ?? 'task_${DateTime.now().millisecondsSinceEpoch}',
      sourceUrl: json['sourceUrl'] as String? ?? '',
      fileName: json['fileName'] as String? ?? 'download_file',
      destinationDirectory: json['destinationDirectory'] as String? ?? '',
      totalSizeBytes: json['totalSizeBytes'] as int? ?? 0,
      downloadedBytes: json['downloadedBytes'] as int? ?? 0,
      status: DownloadStatus.values.firstWhere(
        (e) => e.name == (json['status'] ?? 'idle'),
        orElse: () => DownloadStatus.idle,
      ),
      speedBytesPerSecond: (json['speedBytesPerSecond'] as num?)?.toDouble() ?? 0.0,
      threadCount: json['threadCount'] as int? ?? 4,
      segments: segs,
      error: json['error'] as String?,
      createdAt: json['createdAt'] != null ? DateTime.tryParse(json['createdAt']) : null,
      finishedAt: json['finishedAt'] != null ? DateTime.tryParse(json['finishedAt']) : null,
    );
  }
}
