import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// In-memory buffered block representing downloaded bytes awaiting synchronized disk write.
class MemoryBlock {
  final int fileOffset;
  final Uint8List data;
  final int segmentIndex;
  final DateTime timestamp;

  MemoryBlock({
    required this.fileOffset,
    required this.data,
    required this.segmentIndex,
  }) : timestamp = DateTime.now();

  int get byteLength => data.lengthInBytes;
}

/// [RamCacheManager] provides high-throughput zero-copy memory ring buffering.
///
/// Problem Solved:
/// Writing directly to NVMe/UFS flash memory on every incoming network socket packet
/// causes severe I/O bottleneck, excessive context switching, CPU core wakeups,
/// battery degradation, and flash wear (Write Amplification).
///
/// Solution:
/// Incoming network byte chunks are appended to a volatile in-memory cache.
/// When cached data accumulates to [flushThresholdBytes] (e.g. 64 Megabytes)
/// or when forced/completed, a synchronized batch-flush operation writes the entire
/// block sequence to disk using targeted [RandomAccessFile.setPosition] calls.
class RamCacheManager {
  /// Default batch flush threshold: 64 Megabytes (64 * 1024 * 1024 bytes).
  final int flushThresholdBytes;

  /// Absolute target destination file path.
  final String targetFilePath;

  /// In-memory queue storing unflushed memory blocks.
  final List<MemoryBlock> _bufferPool = [];

  /// Current cumulative byte count stored in RAM.
  int _currentBufferedBytes = 0;

  /// Lock mechanism to ensure sequential, race-condition-free disk writes.
  final Completer<void> _writeLockCompleter = Completer<void>()..complete();
  bool _isFlushing = false;

  /// Dedicated RandomAccessFile handle for zero-overhead positioned writing.
  RandomAccessFile? _fileHandle;

  /// StreamController for telemetry and monitoring RAM usage.
  final StreamController<int> _ramUsageController = StreamController<int>.broadcast();
  Stream<int> get onRamUsageChanged => _ramUsageController.stream;

  RamCacheManager({
    required this.targetFilePath,
    this.flushThresholdBytes = 64 * 1024 * 1024, // 64 MB default
  });

  /// Initializes the target file descriptor and pre-allocates file bounds.
  Future<void> initialize({int? expectedTotalSize}) async {
    final file = File(targetFilePath);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    _fileHandle = await file.open(mode: FileMode.writeOnlyAppend);

    // If total file size is known, pre-allocate space to prevent disk fragmentation
    if (expectedTotalSize != null && expectedTotalSize > 0) {
      await _fileHandle!.truncate(expectedTotalSize);
    }
  }

  /// Appends incoming downloaded bytes into the RAM buffer.
  /// Automatically triggers a disk flush if RAM buffer exceeds [flushThresholdBytes].
  Future<void> writeChunkData({
    required int segmentIndex,
    required int fileOffset,
    required Uint8List data,
  }) async {
    final block = MemoryBlock(
      fileOffset: fileOffset,
      data: data,
      segmentIndex: segmentIndex,
    );

    _bufferPool.add(block);
    _currentBufferedBytes += block.byteLength;
    _ramUsageController.add(_currentBufferedBytes);

    // Trigger flush if threshold reached
    if (_currentBufferedBytes >= flushThresholdBytes && !_isFlushing) {
      await flushToDisk();
    }
  }

  /// Flushes all cached blocks from RAM to disk and immediately releases memory buffers.
  /// Uses a single write lock to avoid data corruption or parallel write conflicts.
  Future<void> flushToDisk() async {
    if (_bufferPool.isEmpty || _isFlushing) return;

    _isFlushing = true;
    try {
      if (_fileHandle == null) {
        final file = File(targetFilePath);
        _fileHandle = await file.open(mode: FileMode.writeOnly);
      }

      // Snapshot current pool and clear primary buffer to allow immediate ingestion
      final List<MemoryBlock> blocksToWrite = List.from(_bufferPool);
      _bufferPool.clear();
      _currentBufferedBytes = 0;
      _ramUsageController.add(0);

      // Sort blocks by fileOffset to allow linear sector disk writing for maximum SSD speed
      blocksToWrite.sort((a, b) => a.fileOffset.compareTo(b.fileOffset));

      for (final block in blocksToWrite) {
        await _fileHandle!.setPosition(block.fileOffset);
        await _fileHandle!.writeFrom(block.data);
      }

      // Force synchronous flush to physical medium
      await _fileHandle!.flush();
    } catch (error) {
      rethrow;
    } finally {
      _isFlushing = false;
    }
  }

  /// Current memory consumption in Megabytes.
  double get currentBufferedMb => _currentBufferedBytes / (1024 * 1024);

  /// Closes file handles, flushes remaining buffers, and ensures memory cleanup.
  Future<void> dispose() async {
    if (_bufferPool.isNotEmpty) {
      await flushToDisk();
    }
    if (_fileHandle != null) {
      await _fileHandle!.close();
      _fileHandle = null;
    }
    _bufferPool.clear();
    _currentBufferedBytes = 0;
    await _ramUsageController.close();
  }
}
