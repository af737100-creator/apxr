import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Storage location category for modern Android Scoped Storage.
enum StorageLocationType {
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
/// for modern Android (13, 14, 15, 16+) and iOS/Desktop.
class StoragePathResolver {
  static const String appSubfolder = 'HyperPulse';

  /// Resolves the primary valid directory to save downloads.
  /// Tries public Downloads first, falls back safely to App Sandbox.
  static Future<String> resolveDownloadDirectory({bool preferPublicDownloads = true}) async {
    try {
      if (Platform.isAndroid) {
        if (preferPublicDownloads) {
          // 1. Attempt standard Public Downloads
          final Directory? downloadsDir = await getDownloadsDirectory();
          if (downloadsDir != null && await _isWritable(downloadsDir.path)) {
            final target = Directory(p.join(downloadsDir.path, appSubfolder));
            if (!await target.exists()) {
              await target.create(recursive: true);
            }
            return target.path;
          }

          // 2. Fallback to External App Storage (Android/data/com.hyperpulse/files/Download)
          final Directory? extDir = await getExternalStorageDirectory();
          if (extDir != null && await _isWritable(extDir.path)) {
            final target = Directory(p.join(extDir.path, 'Downloads'));
            if (!await target.exists()) {
              await target.create(recursive: true);
            }
            return target.path;
          }
        }

        // 3. Guaranteed Safe Sandbox (Application Documents)
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final target = Directory(p.join(appDocDir.path, 'Downloads'));
        if (!await target.exists()) {
          await target.create(recursive: true);
        }
        return target.path;
      } else if (Platform.isIOS) {
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        final target = Directory(p.join(appDocDir.path, 'Downloads'));
        if (!await target.exists()) {
          await target.create(recursive: true);
        }
        return target.path;
      } else {
        // Desktop / Other platforms
        final Directory? downloadsDir = await getDownloadsDirectory();
        if (downloadsDir != null) {
          return downloadsDir.path;
        }
        final Directory appDocDir = await getApplicationDocumentsDirectory();
        return appDocDir.path;
      }
    } catch (e) {
      debugPrint('[StoragePathResolver] Error resolving storage: $e');
      // Emergency fallback
      final Directory tempDir = await getTemporaryDirectory();
      return tempDir.path;
    }
  }

  /// Lists available storage locations with permissions info for UI selection
  static Future<List<StorageLocationInfo>> getAvailableStorageLocations() async {
    final List<StorageLocationInfo> locations = [];

    try {
      if (Platform.isAndroid) {
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
      final testFile = File(p.join(path, '.hyperpulse_write_test'));
      await testFile.writeAsString('test');
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
  }
}
