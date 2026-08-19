import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'smart_url_filter.dart';
import 'cloud_extractor_service.dart';

/// [DetectedDownloadLink] represents a newly captured downloadable URL
class DetectedDownloadLink {
  final String rawUrl;
  final String cleanUrl;
  final String? inferredExtension;
  final bool isVideoPlatform;
  final DateTime detectedAt;

  const DetectedDownloadLink({
    required this.rawUrl,
    required this.cleanUrl,
    this.inferredExtension,
    required this.isVideoPlatform,
    required this.detectedAt,
  });

  String get displayName {
    if (isVideoPlatform) {
      if (rawUrl.contains('youtube') || rawUrl.contains('youtu.be')) return 'فيديو YouTube';
      if (rawUrl.contains('tiktok')) return 'فيديو TikTok';
      if (rawUrl.contains('instagram')) return 'مقطع Instagram';
      if (rawUrl.contains('twitter') || rawUrl.contains('x.com')) return 'مقطع X (تويتر)';
      if (rawUrl.contains('facebook') || rawUrl.contains('fb.watch')) return 'فيديو Facebook';
      return 'فيديو وسائط';
    }
    final segment = cleanUrl.split('/').last.split('?').first;
    return segment.isNotEmpty ? segment : 'ملف ${inferredExtension?.toUpperCase() ?? "تحميل"}';
  }
}

/// [SmartDownloadCatcher] monitors the system Clipboard both in Flutter and via the
/// native Android Foreground Service to ensure Xiaomi / Samsung / Huawei devices
/// never kill the background monitoring radar.
class SmartDownloadCatcher {
  static final SmartDownloadCatcher _instance = SmartDownloadCatcher._internal();
  factory SmartDownloadCatcher() => _instance;
  SmartDownloadCatcher._internal() {
    _initNativeMethodChannel();
  }

  static const MethodChannel _nativeChannel =
      MethodChannel('com.hyperpulse.app/foreground_service');

  Timer? _clipboardTimer;
  String? _lastCapturedUrl;
  bool _isListening = false;
  bool _isForegroundServiceActive = false;

  final StreamController<DetectedDownloadLink> _linkStreamController =
      StreamController<DetectedDownloadLink>.broadcast();

  Stream<DetectedDownloadLink> get onDownloadLinkDetected =>
      _linkStreamController.stream;

  bool get isListening => _isListening;
  bool get isForegroundServiceActive => _isForegroundServiceActive;

  void _initNativeMethodChannel() {
    _nativeChannel.setMethodCallHandler((call) async {
      if (call.method == 'onUrlCaughtFromBackground') {
        final String? url = call.arguments as String?;
        if (url != null && url.isNotEmpty) {
          _processPotentialUrl(url);
        }
      }
    });
  }

  /// Starts the intelligent clipboard observer and kicks off the native Android Foreground Service.
  void startListening({Duration pollInterval = const Duration(milliseconds: 1000)}) {
    if (_isListening) return;
    _isListening = true;
    debugPrint('[SmartDownloadCatcher] 🚀 Started clipboard monitor & Foreground Service.');

    // 1. Start Android Native Foreground Service (Sticky Notification in Status Bar)
    _startNativeForegroundService();

    // 2. Poll Clipboard actively when in foreground
    _clipboardTimer = Timer.periodic(pollInterval, (_) async {
      await inspectClipboard();
    });
  }

  Future<void> _startNativeForegroundService() async {
    try {
      await _nativeChannel.invokeMethod('startService');
      _isForegroundServiceActive = true;
      debugPrint('[SmartDownloadCatcher] ✅ Native Foreground Service started.');
    } catch (e) {
      debugPrint('[SmartDownloadCatcher] Native service start notice: $e');
    }
  }

  /// Stops the clipboard observer and native service
  void stopListening() {
    _clipboardTimer?.cancel();
    _clipboardTimer = null;
    _isListening = false;

    try {
      _nativeChannel.invokeMethod('stopService');
      _isForegroundServiceActive = false;
    } catch (_) {}

    debugPrint('[SmartDownloadCatcher] Stopped clipboard monitor.');
  }

  /// Manually inspects the system clipboard for downloadable links
  Future<DetectedDownloadLink?> inspectClipboard() async {
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String? text = data?.text?.trim();

      if (text == null || text.isEmpty || text == _lastCapturedUrl) {
        return null;
      }

      return _processPotentialUrl(text);
    } catch (e) {
      debugPrint('[SmartDownloadCatcher] Clipboard inspection error: $e');
    }
    return null;
  }

  DetectedDownloadLink? _processPotentialUrl(String rawText) {
    final text = rawText.trim();
    if (!text.startsWith('http://') && !text.startsWith('https://')) {
      return null;
    }

    if (text == _lastCapturedUrl) return null;

    // 1. Anti-Ad & Scam Shield Filter
    if (!SmartUrlFilter.isCleanAndSafe(text)) {
      debugPrint('[SmartDownloadCatcher] 🛡️ Rejected ad/tracker link: $text');
      return null;
    }

    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(text);
    final isDownloadable = SmartUrlFilter.isDownloadableFileUrl(cleanUrl);
    final isVideo = CloudExtractorService.isSocialVideoPlatform(cleanUrl);

    if (isDownloadable || isVideo) {
      _lastCapturedUrl = text;
      final detected = DetectedDownloadLink(
        rawUrl: text,
        cleanUrl: cleanUrl,
        inferredExtension: SmartUrlFilter.inferFileExtension(cleanUrl),
        isVideoPlatform: isVideo,
        detectedAt: DateTime.now(),
      );

      debugPrint('[SmartDownloadCatcher] 🎯 Download link caught: ${detected.displayName}');
      _linkStreamController.add(detected);
      return detected;
    }
    return null;
  }

  void resetHistory() {
    _lastCapturedUrl = null;
  }

  void dispose() {
    stopListening();
    _linkStreamController.close();
  }
}
