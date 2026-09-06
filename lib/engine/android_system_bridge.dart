import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// [AndroidSystemBridge] bridges Flutter with native Android OS capabilities:
/// 1. SYSTEM_ALERT_WINDOW (Draw Over Other Apps / الظهور فوق التطبيقات).
/// 2. POST_NOTIFICATIONS status verification.
/// 3. MediaScannerConnection (Indexing downloaded videos into Gallery/Photos).
/// 4. Movies/HyperPulse public directory resolution.
class AndroidSystemBridge {
  static const MethodChannel _systemChannel =
      MethodChannel('com.hyperpulse.app/android_system');
  static const MethodChannel _serviceChannel =
      MethodChannel('com.hyperpulse.app/foreground_service');

  /// Starts the Android Foreground Service to keep CPU & Network alive when app is minimized.
  static Future<bool> startForegroundService() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? result = await _serviceChannel.invokeMethod<bool>('startService');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] startForegroundService error: $e');
      return false;
    }
  }

  /// Stops the Android Foreground Service when no active downloads remain.
  static Future<bool> stopForegroundService() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? result = await _serviceChannel.invokeMethod<bool>('stopService');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] stopForegroundService error: $e');
      return false;
    }
  }

  /// Checks if the application has the "Draw Over Other Apps" (SYSTEM_ALERT_WINDOW) permission.
  static Future<bool> canDrawOverlays() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? result = await _systemChannel.invokeMethod<bool>('canDrawOverlays');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] canDrawOverlays check error: $e');
      return false;
    }
  }

  /// Opens the native Android System Settings screen to grant "Draw Over Other Apps".
  static Future<bool> openOverlaySettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? result = await _systemChannel.invokeMethod<bool>('openOverlaySettings');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] openOverlaySettings error: $e');
      return false;
    }
  }

  /// Checks if status bar notifications are enabled for the app.
  static Future<bool> areNotificationsEnabled() async {
    if (!Platform.isAndroid) return true;
    try {
      final bool? result =
          await _systemChannel.invokeMethod<bool>('areNotificationsEnabled');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] areNotificationsEnabled error: $e');
      return false;
    }
  }

  /// Opens the native Android Notification Settings screen for HyperPulse.
  static Future<bool> openNotificationSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? result =
          await _systemChannel.invokeMethod<bool>('openNotificationSettings');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] openNotificationSettings error: $e');
      return false;
    }
  }

  /// Tells the Android MediaScannerConnection to index a newly downloaded Video/Audio file
  /// and exports it to Android MediaStore and Public Download directory so that
  /// it appears immediately in the Google Photos / Samsung Gallery / Xiaomi Gallery app
  /// and in the system File Manager (Download/HyperPulse).
  static Future<String> exportToPublicStorage(String filePath) async {
    if (!Platform.isAndroid) return filePath;
    try {
      debugPrint('[AndroidSystemBridge] 🔄 Exporting file to Public MediaStore & Downloads: $filePath');
      final String? result = await _systemChannel.invokeMethod<String>(
        'exportToPublicStorage',
        {'filePath': filePath},
      );
      debugPrint('[AndroidSystemBridge] ✅ File exported successfully: $result');
      return result ?? filePath;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] exportToPublicStorage warning: $e');
      return filePath;
    }
  }

  /// Backward-compatible alias for scanMediaFile
  static Future<void> scanMediaFile(String filePath) async {
    await exportToPublicStorage(filePath);
  }

  /// Resolves the absolute path for `Download/HyperPulse` on Android.
  static Future<String?> getPublicDownloadsPath() async {
    if (!Platform.isAndroid) return null;
    try {
      final String? path =
          await _systemChannel.invokeMethod<String>('getPublicDownloadsPath');
      return path;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] getPublicDownloadsPath warning: $e');
      return null;
    }
  }

  /// Resolves the absolute path for `Movies/HyperPulse` on Android.
  static Future<String?> getPublicMoviesPath() async {
    if (!Platform.isAndroid) return null;
    try {
      final String? path =
          await _systemChannel.invokeMethod<String>('getPublicMoviesPath');
      return path;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] getPublicMoviesPath warning: $e');
      return null;
    }
  }

  /// Installs a downloaded APK file directly using Android PackageInstaller / FileProvider.
  static Future<bool> installApk(String apkFilePath) async {
    if (!Platform.isAndroid) return false;
    try {
      debugPrint('[AndroidSystemBridge] 📦 Installing APK: $apkFilePath');
      final bool? result = await _systemChannel.invokeMethod<bool>(
        'installApk',
        {'filePath': apkFilePath},
      );
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] installApk error: $e');
      return false;
    }
  }

  /// Opens any downloaded file (Video, Audio, Document, Zip) in its default external app.
  static Future<bool> openFile(String filePath) async {
    if (!Platform.isAndroid) return false;
    try {
      debugPrint('[AndroidSystemBridge] 📂 Opening file externally: $filePath');
      final bool? result = await _systemChannel.invokeMethod<bool>(
        'openFile',
        {'filePath': filePath},
      );
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] openFile error: $e');
      return false;
    }
  }

  /// Directly requests all runtime and storage permissions on app launch.
  /// Shows system prompts so user simply taps Allow (سماح).
  static Future<bool> requestAllAppPermissions() async {
    if (!Platform.isAndroid) return true;
    try {
      debugPrint('[AndroidSystemBridge] 🛡️ Requesting all system permissions on launch...');
      final bool? result = await _systemChannel.invokeMethod<bool>('requestAllAppPermissions');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] requestAllAppPermissions error: $e');
      return false;
    }
  }

  /// Creates and verifies all public storage folders (Download/HyperPulse, Videos, Audio, Apps, Archives)
  static Future<bool> createAppStorageFolders() async {
    if (!Platform.isAndroid) return true;
    try {
      debugPrint('[AndroidSystemBridge] 📁 Creating app storage folders immediately...');
      final bool? result = await _systemChannel.invokeMethod<bool>('createAppStorageFolders');
      return result ?? false;
    } catch (e) {
      debugPrint('[AndroidSystemBridge] createAppStorageFolders error: $e');
      return false;
    }
  }
}
