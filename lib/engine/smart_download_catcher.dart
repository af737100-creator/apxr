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
      return 'فيديو وسائط';
    }
    final segment = cleanUrl.split('/').last.split('?').first;
    return segment.isNotEmpty ? segment : 'ملف ${inferredExtension?.toUpperCase() ?? "تحميل"}';
  }
}

/// [SmartDownloadCatcher] monitors the device Clipboard in real time,
/// cleans URLs through [SmartUrlFilter], and alerts the user via overlay prompts.
class SmartDownloadCatcher {
  static final SmartDownloadCatcher _instance = SmartDownloadCatcher._internal();
  factory SmartDownloadCatcher() => _instance;
  SmartDownloadCatcher._internal();

  Timer? _clipboardTimer;
  String? _lastCapturedUrl;
  bool _isListening = false;

  final StreamController<DetectedDownloadLink> _linkStreamController =
      StreamController<DetectedDownloadLink>.broadcast();

  Stream<DetectedDownloadLink> get onDownloadLinkDetected =>
      _linkStreamController.stream;

  bool get isListening => _isListening;

  /// Starts the intelligent clipboard observer (polls every 1200ms)
  void startListening({Duration pollInterval = const Duration(milliseconds: 1200)}) {
    if (_isListening) return;
    _isListening = true;
    debugPrint('[SmartDownloadCatcher] Started clipboard monitor.');

    _clipboardTimer = Timer.periodic(pollInterval, (_) async {
      await inspectClipboard();
    });
  }

  /// Stops the clipboard observer
  void stopListening() {
    _clipboardTimer?.cancel();
    _clipboardTimer = null;
    _isListening = false;
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

      // Check if text is a valid HTTP/HTTPS URL
      if (!text.startsWith('http://') && !text.startsWith('https://')) {
        return null;
      }

      // 1. Apply Anti-Ad & Scam Shield Filter
      if (!SmartUrlFilter.isCleanAndSafe(text)) {
        debugPrint('[SmartDownloadCatcher] Rejected ad/tracker link: $text');
        return null;
      }

      final cleanUrl = SmartUrlFilter.extractRealTargetUrl(text);
      final isDownloadable = SmartUrlFilter.isDownloadableFileUrl(cleanUrl);
      final isVideo = CloudExtractorService.isSocialVideoPlatform(cleanUrl);

      // Only capture if it matches downloadable file extensions (apk, zip, mp4, pdf, etc.)
      // OR recognized video platforms (YouTube, TikTok, etc.)
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
    } catch (e) {
      debugPrint('[SmartDownloadCatcher] Clipboard inspection error: $e');
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
