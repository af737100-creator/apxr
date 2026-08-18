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
  final String sourceUrl;
  final String fileName;
  final String destinationDirectory;
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
}
