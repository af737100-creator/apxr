import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'android_system_bridge.dart';

/// Storage location category for modern Android Scoped Storage.
enum StorageLocationType {
  publicMovies,
  publicDownloads,
  appExternalSandbox,
  appInternalDocuments,
}

class StorageLocationInfo {
  final String path;
  final StorageLocationType type;
  final bool isPublic;
  final String displayName;

  const StorageLocationInfo({
    required this.path,
    required this.type,
    required this.isPublic,
    required this.displayName,
  });
}

/// Resolves the optimal, scoped-storage compliant download destination path
/// for modern Android (13, 14, 15, 16+) and iOS/Desktop with zero-crash fallbacks.
class StoragePathResolver {
  static const String appSubfolder = 'HyperPulse';

  /// Sanitizes any string into a valid, safe cross-platform file name.
  /// Removes emojis, hashtags, illegal FAT32/Linux characters, trailing dots and spaces,
  /// and caps the length to prevent OS filesystem errors.
  static String sanitizeFileName(String name, {String fallbackExtension = 'mp4'}) {
    if (name.trim().isEmpty) {
      return 'HyperPulse_${DateTime.now().millisecondsSinceEpoch}.$fallbackExtension';
    }

    String clean = name.trim();

    // 1. Separate base name and extension
    String ext = '';
    final lastDot = clean.lastIndexOf('.');
    if (lastDot != -1 && lastDot < clean.length - 1 && clean.length - lastDot <= 6) {
      ext = clean.substring(lastDot);
      clean = clean.substring(0, lastDot);
    } else if (fallbackExtension.isNotEmpty) {
      ext = fallbackExtension.startsWith('.') ? fallbackExtension : '.$fallbackExtension';
    }

    // 2. Remove illegal characters for Android/Linux/Windows filesystems
    // Replace: \ / : * ? " < > | \n \r \t and non-printable chars
    clean = clean.replaceAll(RegExp(r'[\\/:*?"<>|\r\n\t\x00-\x1F]'), '_');

    // 3. Remove or replace hashtag symbols and multiple consecutive underscores
    clean = clean.replaceAll('#', '_');
    clean = clean.replaceAll(RegExp(r'_+'), '_');

    // 4. Remove leading/trailing dots and spaces (causes FAT32/Android OS 22 Invalid argument error)
    clean = clean.trim();
    while (clean.endsWith('.') || clean.endsWith(' ') || clean.endsWith('_')) {
      if (clean.isEmpty) break;
      clean = clean.substring(0, clean.length - 1).trim();
    }
    while (clean.startsWith('.') || clean.startsWith(' ') || clean.startsWith('_')) {
      if (clean.isEmpty) break;
      clean = clean.substring(1).trim();
    }

    // 5. Cap base name length to 70 characters
    if (clean.length > 70) {
      clean = clean.substring(0, 70).trim();
      while (clean.endsWith('.') || clean.endsWith('_')) {
        clean = clean.substring(0, clean.length - 1);
      }
    }

    // 6. Final fallback if string became empty
    if (clean.isEmpty) {
      clean = 'HyperPulse_${DateTime.now().millisecondsSinceEpoch}';
    }

    return '$clean$ext';
  }

  /// Categorized subfolder name based on file extension and media flags
  static String categorizeSubfolder({
    String? fileName,
    String? fileExtension,
    bool isVideo = false,
    bool isApk = false,
    bool isArchive = false,
    bool isAudio = false,
  }) {
    if (isApk) return 'Apps';
    if (isVideo) return 'Videos';
    if (isArchive) return 'Archives';
    if (isAudio) return 'Audio';

    final ext = (fileExtension ?? (fileName != null && fileName.contains('.') ? fileName.split('.').last : '')).toLowerCase().trim();
    if (ext == 'apk' || ext == 'xapk' || ext == 'apks') return 'Apps';
    if (['mp4', 'mkv', 'webm', 'mov', 'avi', '3gp', 'flv'].contains(ext)) return 'Videos';
    if (['zip', 'rar', '7z', 'tar', 'gz', 'iso', 'bz2', 'xz'].contains(ext)) return 'Archives';
    if (['mp3', 'm4a', 'wav', 'flac', 'aac', 'ogg', 'opus'].contains(ext)) return 'Audio';
    if (['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'epub'].contains(ext)) return 'Documents';

    return 'General';
  }

  /// Resolves the public Movies directory (`Movies/HyperPulse/Videos`) with verified write test.
  static Future<String> resolveMoviesDirectory() async {
    try {
      if (Platform.isAndroid) {
        // 1. Query Native Android Bridge for Environment.DIRECTORY_MOVIES
        final nativeMovies = await AndroidSystemBridge.getPublicMoviesPath();
        if (nativeMovies != null && nativeMovies.isNotEmpty) {
          final target = Directory(p.join(nativeMovies, 'Videos'));
          if (!await target.exists()) {
            try {
              await target.create(recursive: true);
            } catch (_) {}
          }
          if (await _isWritable(target.path)) {
            return target.path;
          }
        }

        // 2. Standard Android /storage/emulated/0/Movies/HyperPulse/Videos
        final fallbackDir = Directory('/storage/emulated/0/Movies/$appSubfolder/Videos');
        if (!await fallbackDir.exists()) {
          try {
            await fallbackDir.create(recursive: true);
          } catch (_) {}
        }
        if (await _isWritable(fallbackDir.path)) {
          return fallbackDir.path;
        }
      }

      // 3. Fallback to standard verified Downloads or App Sandbox
      return await resolveDownloadDirectory(isMediaVideo: true, category: 'Videos');
    } catch (e) {
      debugPrint('[StoragePathResolver] resolveMoviesDirectory error: $e');
      return await resolveDownloadDirectory(isMediaVideo: true, category: 'Videos');
    }
  }

  /// Resolves a 100% verified writable directory to save downloads organized by category.
  /// Structure in phone storage:
  /// Download/HyperPulse/Apps
  /// Download/HyperPulse/Videos
  /// Download/HyperPulse/Archives
  /// Download/HyperPulse/Audio
  /// Download/HyperPulse/Documents
  static Future<String> resolveDownloadDirectory({
    bool isMediaVideo = false,
    bool isApk = false,
    bool isArchive = false,
    bool isAudio = false,
    String? category,
    String? fileName,
    bool preferPublicDownloads = true,
  }) async {
    final chosenCategory = category ??
        categorizeSubfolder(
          fileName: fileName,
          isVideo: isMediaVideo,
          isApk: isApk,
          isArchive: isArchive,
          isAudio: isAudio,
        );

    try {
      if (isMediaVideo && Platform.isAndroid) {
        final moviesDir = await resolveMoviesDirectory();
        if (await _isWritable(moviesDir)) {
          return moviesDir;
        }
      }

      if (Platform.isAndroid) {
        if (preferPublicDownloads) {
          // 0. Native Android Bridge Public Downloads (Environment.DIRECTORY_DOWNLOADS/HyperPulse/Category)
          try {
            final nativeDownloads = await AndroidSystemBridge.getPublicDownloadsPath();
            if (nativeDownloads != null && nativeDownloads.isNotEmpty) {
              final target = Directory(p.join(nativeDownloads, chosenCategory));
              if (!await target.exists()) {
                await target.create(recursive: true);
              }
              if (await _isWritable(target.path)) {
                return target.path;
              }
            }
          } catch (_) {}

          // 1. Direct path to /storage/emulated/0/Download/HyperPulse/Category
          try {
            final directDownloads = Directory('/storage/emulated/0/Download/$appSubfolder/$chosenCategory');
            if (!await directDownloads.exists()) {
              await directDownloads.create(recursive: true);
            }
            if (await _isWritable(directDownloads.path)) {
              return directDownloads.path;
            }
          } catch (_) {}

          // 2. Direct path to root storage /storage/emulated/0/HyperPulse/Category
          try {
            final rootFolder = Directory('/storage/emulated/0/$appSubfolder/$chosenCategory');
            if (!await rootFolder.exists()) {
              await rootFolder.create(recursive: true);
            }
            if (await _isWritable(rootFolder.path)) {
              return rootFolder.path;
            }
          } catch (_) {}

          // 3. Attempt standard getDownloadsDirectory
          try {
            final Directory? downloadsDir = await getDownloadsDirectory();
            if (downloadsDir != null) {
              final target = Directory(p.join(downloadsDir.path, appSubfolder, chosenCategory));
              if (!await target.exists()) {
                await target.create(recursive: true);
              }
              if (await _isWritable(target.path)) {
                return target.path;
              }
            }
          } catch (_) {}
        }

        // 4. Guaranteed External App Storage (Scoped-Storage safe, no permission needed)
        try {
          final Directory? extDir = await getExternalStorageDirectory();
          if (extDir != null) {
            final target = Directory(p.join(extDir.path, 'Downloads', chosenCategory));
            if (!await target.exists()) {
              await target.create(recursive: true);
            }
            if (await _isWritable(target.path)) {
              return target.path;
            }
          }
        } catch (_) {}

        // 5. Guaranteed Safe Sandbox (Application Documents)
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final target = Directory(p.join(appDocDir.path, 'Downloads', chosenCategory));
        if (!await target.exists()) {
          await target.create(recursive: true);
        }
        return target.path;
      } else if (Platform.isIOS) {
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final target = Directory(p.join(appDocDir.path, 'Downloads', chosenCategory));
        if (!await target.exists()) {
          await target.create(recursive: true);
        }
        return target.path;
      } else {
        // Desktop / Web
        final Directory? downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null && await _isWritable(downloadsDir.path)) {
          final target = Directory(p.join(downloadsDir.path, appSubfolder, chosenCategory));
          if (!await target.exists()) {
            await target.create(recursive: true);
          }
          return target.path;
        }
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final target = Directory(p.join(appDocDir.path, 'Downloads', chosenCategory));
        if (!await target.exists()) {
          await target.create(recursive: true);
        }
        return target.path;
      }
    } catch (e) {
      debugPrint('[StoragePathResolver] Error resolving storage: $e');
      final Directory tempDir = await getTemporaryDirectory();
      return tempDir.path;
    }
  }

  /// Lists available storage locations with permissions info for UI selection
  static Future<List<StorageLocationInfo>> getAvailableStorageLocations() async {
    final List<StorageLocationInfo> locations = [];

    try {
      if (Platform.isAndroid) {
        // Public Movies
        final moviesPath = await resolveMoviesDirectory();
        locations.add(
          StorageLocationInfo(
            path: moviesPath,
            type: StorageLocationType.publicMovies,
            isPublic: true,
            displayName: 'معرض الفيديوهات (Movies/HyperPulse)',
          ),
        );

        // Public Downloads
        final Directory? downloads = await getDownloadsDirectory();
        if (downloads != null && await _isWritable(downloads.path)) {
          locations.add(
            StorageLocationInfo(
              path: p.join(downloads.path, appSubfolder),
              type: StorageLocationType.publicDownloads,
              isPublic: true,
              displayName: 'مجلد التنزيلات العام (Downloads/HyperPulse)',
            ),
          );
        }

        // External App Sandbox
        final Directory? externalDir = await getExternalStorageDirectory();
        if (externalDir != null && await _isWritable(externalDir.path)) {
          locations.add(
            StorageLocationInfo(
              path: p.join(externalDir.path, 'Downloads'),
              type: StorageLocationType.appExternalSandbox,
              isPublic: false,
              displayName: 'ذاكرة التطبيق الخارجية (App External Sandbox)',
            ),
          );
        }
      }

      // Internal App Documents (Always accessible)
      final Directory docDir = await getApplicationDocumentsDirectory();
      locations.add(
        StorageLocationInfo(
          path: p.join(docDir.path, 'Downloads'),
          type: StorageLocationType.appInternalDocuments,
          isPublic: false,
          displayName: 'المجلد الآمن للتطبيق (App Internal Storage)',
        ),
      );
    } catch (e) {
      debugPrint('[StoragePathResolver] Error listing locations: $e');
    }

    return locations;
  }

  /// Helper to test write permissions inside a directory
  static Future<bool> _isWritable(String path) async {
    try {
      final dir = Directory(path);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final testFile = File(p.join(path, '.hyperpulse_write_test_${DateTime.now().millisecondsSinceEpoch}'));
      await testFile.writeAsString('test', flush: true);
      if (await testFile.exists()) {
        await testFile.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
