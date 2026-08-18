import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

/// Result of an audio extraction operation.
class AudioExtractionResult {
  final bool success;
  final String? outputPath;
  final String? errorMessage;
  final Duration? duration;

  const AudioExtractionResult({
    required this.success,
    this.outputPath,
    this.errorMessage,
    this.duration,
  });
}

/// Service dedicated to extracting high-fidelity MP3 audio from downloaded video files.
class AudioExtractorService {
  static const Set<String> supportedVideoExtensions = {
    '.mp4',
    '.mkv',
    '.webm',
    '.avi',
    '.mov',
    '.flv',
    '.3gp',
    '.ts',
    '.m4v',
  };

  /// Checks if the given filename or URL represents a video format
  static bool isVideoFormat(String filenameOrUrl) {
    final cleanPath = filenameOrUrl.split('?').first.toLowerCase();
    final ext = p.extension(cleanPath);
    return supportedVideoExtensions.contains(ext);
  }

  /// Extracts MP3 from the specified video file path
  /// - [videoFilePath]: Absolute path to the downloaded video
  /// - [deleteOriginal]: Whether to delete the video file after successful extraction
  /// - [bitrateKbps]: Audio bitrate (default 192 kbps for high fidelity)
  static Future<AudioExtractionResult> extractToMp3({
    required String videoFilePath,
    bool deleteOriginal = false,
    int bitrateKbps = 192,
  }) async {
    final videoFile = File(videoFilePath);
    if (!await videoFile.exists()) {
      return const AudioExtractionResult(
        success: false,
        errorMessage: 'الملف المرئي الأصلي غير موجود على مسار التخزين',
      );
    }

    // Prepare MP3 destination path
    final dir = p.dirname(videoFilePath);
    final baseName = p.basenameWithoutExtension(videoFilePath);
    final mp3Path = p.join(dir, '$baseName.mp3');

    try {
      debugPrint('[AudioExtractorService] Initiating FFmpeg MP3 Extraction for: $videoFilePath');

      // Command: Extract audio, discard video (-vn), high quality libmp3lame
      final command =
          '-y -i "$videoFilePath" -vn -acodec libmp3lame -b:a ${bitrateKbps}k -ar 44100 "$mp3Path"';

      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();

      if (ReturnCode.isSuccess(returnCode)) {
        debugPrint('[AudioExtractorService] MP3 extracted successfully to: $mp3Path');

        if (deleteOriginal) {
          try {
            await videoFile.delete();
          } catch (e) {
            debugPrint('[AudioExtractorService] Could not delete original video: $e');
          }
        }

        return AudioExtractionResult(
          success: true,
          outputPath: mp3Path,
        );
      } else {
        // Check fallback via OS process if running on desktop or hybrid
        final fallbackResult = await _fallbackSystemFfmpeg(videoFilePath, mp3Path, bitrateKbps);
        if (fallbackResult.success) {
          return fallbackResult;
        }

        final logs = await session.getAllLogsAsString();
        return AudioExtractionResult(
          success: false,
          errorMessage: 'فشل استخراج الصوت عبر FFmpeg: ${logs ?? "Unknown error"}',
        );
      }
    } catch (e) {
      debugPrint('[AudioExtractorService] Exception during extraction: $e');
      return AudioExtractionResult(
        success: false,
        errorMessage: 'حدث خطأ أثناء معالجة ملف الصوت: ${e.toString()}',
      );
    }
  }

  /// Fallback for desktop testing environments
  static Future<AudioExtractionResult> _fallbackSystemFfmpeg(
    String input,
    String output,
    int bitrate,
  ) async {
    try {
      final result = await Process.run('ffmpeg', [
        '-y',
        '-i',
        input,
        '-vn',
        '-acodec',
        'libmp3lame',
        '-b:a',
        '${bitrate}k',
        output,
      ]);

      if (result.exitCode == 0 && await File(output).exists()) {
        return AudioExtractionResult(success: true, outputPath: output);
      }
    } catch (_) {}
    return const AudioExtractionResult(success: false);
  }
}
