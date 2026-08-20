import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/segment_chunk.dart';

/// [SmartResumeManager] provides resilient resume metadata persistence (.pulse_state)
/// enabling HyperPulse to resume broken downloads down to the exact byte offset
/// across app restarts, network handovers (Wi-Fi <-> 5G), and device reboots.
class SmartResumeManager {
  /// Generates the path for the hidden checkpoint file
  static String getStateFilePath(String targetFilePath) {
    return '$targetFilePath.pulse_state';
  }

  /// Saves the current segment checkpoints to disk in atomic JSON format
  static Future<void> persistCheckpoints({
    required String targetFilePath,
    required String sourceUrl,
    required int totalSizeBytes,
    required List<SegmentChunk> segments,
  }) async {
    try {
      final stateFile = File(getStateFilePath(targetFilePath));
      
      final payload = {
        'version': 1,
        'sourceUrl': sourceUrl,
        'targetFilePath': targetFilePath,
        'totalSizeBytes': totalSizeBytes,
        'savedAt': DateTime.now().toIso8601String(),
        'segments': segments.map((s) => s.toJson()).toList(),
      };

      final jsonStr = jsonEncode(payload);
      // Write to temp first, then rename for atomic safety
      final tmpFile = File('${stateFile.path}.tmp');
      await tmpFile.writeAsString(jsonStr, flush: true);
      if (await stateFile.exists()) {
        await stateFile.delete();
      }
      await tmpFile.rename(stateFile.path);
    } catch (e) {
      debugPrint('[SmartResumeManager] Error persisting checkpoint: $e');
    }
  }

  /// Loads previously saved segment states if available and valid
  static Future<Map<String, dynamic>?> loadCheckpoints(String targetFilePath) async {
    try {
      final stateFile = File(getStateFilePath(targetFilePath));
      if (!await stateFile.exists()) return null;

      final content = await stateFile.readAsString();
      if (content.isEmpty) return null;

      final Map<String, dynamic> data = jsonDecode(content);
      return data;
    } catch (e) {
      debugPrint('[SmartResumeManager] Error loading checkpoint: $e');
      return null;
    }
  }

  /// Cleans up state checkpoint file upon successful download completion
  static Future<void> deleteCheckpoint(String targetFilePath) async {
    try {
      final stateFile = File(getStateFilePath(targetFilePath));
      if (await stateFile.exists()) {
        await stateFile.delete();
      }
      final tmpFile = File('${stateFile.path}.tmp');
      if (await tmpFile.exists()) {
        await tmpFile.delete();
      }
    } catch (_) {}
  }
}
