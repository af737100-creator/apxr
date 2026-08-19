/// State tracking for an individual byte range chunk in a multi-segmented download.
enum ChunkStatus {
  pending,
  downloading,
  bufferedInRam,
  flushedToDisk,
  completed,
  failed,
  retrying,
}

/// Represents a distinct slice/segment of a file downloaded via HTTP Range requests.
class SegmentChunk {
  /// Unique 0-indexed identifier for the segment.
  final int index;

  /// Absolute starting byte offset in the target file.
  final int startByte;

  /// Absolute ending byte offset in the target file (inclusive).
  int endByte;

  /// Number of bytes successfully downloaded and validated so far.
  int downloadedBytes;

  /// Current lifecycle status of this chunk.
  ChunkStatus status;

  /// Temporary error description if chunk download encounters an exception.
  String? errorMessage;

  /// Current retry attempt count for this specific segment.
  int retryAttempts;

  /// Timestamp when the chunk download began.
  DateTime? startTime;

  /// Timestamp when the chunk finished downloading.
  DateTime? completedTime;

  SegmentChunk({
    required this.index,
    required this.startByte,
    required this.endByte,
    this.downloadedBytes = 0,
    this.status = ChunkStatus.pending,
    this.errorMessage,
    this.retryAttempts = 0,
    this.startTime,
    this.completedTime,
  });

  /// Total expected payload size of this segment in bytes.
  int get totalExpectedBytes => (endByte - startByte) + 1;

  /// Current completion percentage for this chunk (0.0 to 1.0).
  double get progress {
    if (totalExpectedBytes <= 0) return 0.0;
    final ratio = downloadedBytes / totalExpectedBytes;
    return ratio.clamp(0.0, 1.0);
  }

  /// Whether all bytes for this segment have been received.
  bool get isComplete => downloadedBytes >= totalExpectedBytes;

  /// Constructs the standard HTTP "Range" header value.
  /// Example: "bytes=1048576-2097151"
  String get httpRangeHeader {
    final currentOffset = startByte + downloadedBytes;
    return 'bytes=$currentOffset-$endByte';
  }

  Map<String, dynamic> toJson() => {
    'index': index,
    'startByte': startByte,
    'endByte': endByte,
    'downloadedBytes': downloadedBytes,
    'status': status.name,
    'retryAttempts': retryAttempts,
  };

  @override
  String toString() {
    return 'SegmentChunk#$index [Range: $startByte-$endByte, Size: ${totalExpectedBytes ~/ 1024}KB, Progress: ${(progress * 100).toStringAsFixed(1)}%, Status: ${status.name}]';
  }
}
