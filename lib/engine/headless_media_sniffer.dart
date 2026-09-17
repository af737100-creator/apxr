import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'cloud_extractor_service.dart';
import 'smart_url_filter.dart';

/// [HeadlessMediaSniffer] implements the VidMate/SnapTube architectural pattern:
/// Offscreen / Headless WebView Sniffing with JavaScript Injection to intercept
/// media streams directly from HTML5 players, network requests, and DOM nodes
/// across all platforms (Instagram, Facebook, Twitter/X, TikTok, Reddit, Pinterest, etc.).
class HeadlessMediaSniffer {
  /// User-Agent mimicking a modern Android Chrome mobile device
  static const String mobileUserAgent =
      'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36';

  /// Performs headless sniffing on the target webpage URL.
  /// Returns a [CloudExtractedMedia] if a valid direct video/audio stream was captured within [timeout],
  /// or null if no media stream was detected in time.
  static Future<CloudExtractedMedia?> sniffMediaUrl(
    String targetUrl, {
    Duration timeout = const Duration(seconds: 7),
  }) async {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(targetUrl.trim());
    if (cleanUrl.isEmpty || !cleanUrl.startsWith('http')) return null;

    final completer = Completer<CloudExtractedMedia?>();
    Timer? timeoutTimer;
    WebViewController? controller;

    try {
      controller = WebViewController();
      await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.setUserAgent(mobileUserAgent);

      // JavaScript channel receiving intercepted media events (equivalent to VidMate's JS Bridge)
      await controller.addJavaScriptChannel(
        'HeadlessSnifferBridge',
        onMessageReceived: (JavaScriptMessage message) {
          if (completer.isCompleted) return;

          try {
            final raw = message.message;
            String? mediaUrl;
            String pageTitle = 'Video_${DateTime.now().millisecondsSinceEpoch}';

            if (raw.startsWith('{')) {
              final Map<String, dynamic> data = jsonDecode(raw);
              mediaUrl = data['url']?.toString();
              if (data['title'] != null && data['title'].toString().trim().isNotEmpty) {
                pageTitle = data['title'].toString().trim();
              }
            } else if (raw.startsWith('http')) {
              mediaUrl = raw;
            }

            if (mediaUrl != null && _isValidMediaUrl(mediaUrl)) {
              debugPrint('⚡ [HeadlessMediaSniffer] Intercepted stream: $mediaUrl');
              timeoutTimer?.cancel();
              // Abort active webview immediately to cease all background network activity
              controller?.loadRequest(Uri.parse('about:blank')).catchError((_) {});
              completer.complete(
                CloudExtractedMedia(
                  success: true,
                  originalUrl: cleanUrl,
                  directStreamUrl: mediaUrl,
                  title: CloudExtractedMedia.sanitizeFilename(pageTitle, 'mp4'),
                  format: 'mp4',
                  quality: 'Headless Sniffer (VidMate Architecture) ⚡',
                  serverUsed: 'Local Headless Engine',
                  isDirectFallback: false,
                ),
              );
            }
          } catch (e) {
            debugPrint('[HeadlessMediaSniffer] Message parse notice: $e');
          }
        },
      );

      await controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            final navUrl = request.url;

            // 1. Block analytics, telemetry, and ad trackers (prevents TCP errors & battery drain)
            if (SmartUrlFilter.isAdOrTrackingUrl(navUrl)) {
              return NavigationDecision.prevent;
            }

            // 2. Intercept direct stream URLs
            if (_isValidMediaUrl(navUrl)) {
              if (!completer.isCompleted) {
                timeoutTimer?.cancel();
                controller?.loadRequest(Uri.parse('about:blank')).catchError((_) {});
                completer.complete(
                  CloudExtractedMedia(
                    success: true,
                    originalUrl: cleanUrl,
                    directStreamUrl: navUrl,
                    title: CloudExtractedMedia.sanitizeFilename(
                        'Video_${DateTime.now().millisecondsSinceEpoch}', 'mp4'),
                    format: 'mp4',
                    quality: 'Headless Sniffer Navigation ⚡',
                    serverUsed: 'Local Headless Engine',
                    isDirectFallback: false,
                  ),
                );
              }
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
          onPageFinished: (url) async {
            if (completer.isCompleted || controller == null) return;
            // Inject VidMate-style deep media interception JavaScript
            _injectSnifferScript(controller);
          },
        ),
      );

      // Set safety timeout so the process never hangs indefinitely
      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          debugPrint('[HeadlessMediaSniffer] Timeout reached for: $cleanUrl');
          controller?.loadRequest(Uri.parse('about:blank')).catchError((_) {});
          completer.complete(null);
        }
      });

      // Load target URL in background
      await controller.loadRequest(Uri.parse(cleanUrl));
      return await completer.future;
    } catch (e) {
      debugPrint('[HeadlessMediaSniffer] Headless sniffer unsupported or error: $e');
      timeoutTimer?.cancel();
      if (!completer.isCompleted) {
        completer.complete(null);
      }
      return null;
    }
  }

  /// Injects VidMate PageBrowserJS-style interception scripts into the active page DOM
  static void _injectSnifferScript(WebViewController controller) {
    const snifferScript = '''
      (function() {
        if (window.__hyperpulse_sniffer_injected) return;
        window.__hyperpulse_sniffer_injected = true;

        function reportMedia(url, type) {
          if (!url || typeof url !== 'string') return;
          if (!url.startsWith('http://') && !url.startsWith('https://')) return;
          if (url.includes('googleads') || url.includes('analytics') || url.includes('doubleclick')) return;

          var lower = url.toLowerCase();
          var isMedia = lower.includes('.mp4') ||
                        lower.includes('.m3u8') ||
                        lower.includes('.mpd') ||
                        lower.includes('.webm') ||
                        lower.includes('tiktokcdn') ||
                        lower.includes('fbcdn.net') ||
                        lower.includes('cdninstagram.com') ||
                        lower.includes('twimg.com/video') ||
                        lower.includes('v.redd.it') ||
                        lower.includes('googlevideo.com/videoplayback');

          if (isMedia && window.HeadlessSnifferBridge) {
            window.HeadlessSnifferBridge.postMessage(JSON.stringify({
              url: url,
              title: document.title || 'Video',
              type: type || 'stream'
            }));
          }
        }

        // 1. Hook HTMLMediaElement play & src
        try {
          var origPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function() {
            if (this.currentSrc) reportMedia(this.currentSrc, 'media_play');
            else if (this.src) reportMedia(this.src, 'media_play');
            return origPlay.apply(this, arguments);
          };
        } catch(e) {}

        // 2. Hook window.fetch
        try {
          if (window.fetch) {
            var origFetch = window.fetch;
            window.fetch = function() {
              try {
                var input = arguments[0];
                var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                if (url) reportMedia(url, 'fetch');
              } catch(e) {}
              return origFetch.apply(this, arguments);
            };
          }
        } catch(e) {}

        // 3. Hook XMLHttpRequest
        try {
          if (window.XMLHttpRequest) {
            var origOpen = XMLHttpRequest.prototype.open;
            XMLHttpRequest.prototype.open = function(method, url) {
              try {
                if (url) reportMedia(url, 'xhr');
              } catch(e) {}
              return origOpen.apply(this, arguments);
            };
          }
        } catch(e) {}

        // 4. Scan existing DOM video/audio tags and OpenGraph meta tags
        function scanDOM() {
          var vids = document.querySelectorAll('video, audio, source');
          for (var i = 0; i < vids.length; i++) {
            var s = vids[i].currentSrc || vids[i].src;
            if (s) reportMedia(s, 'dom');
          }
          var metas = document.querySelectorAll('meta[property*="video"], meta[name*="video"], meta[property*="secure_url"]');
          for (var j = 0; j < metas.length; j++) {
            var content = metas[j].getAttribute('content');
            if (content) reportMedia(content, 'meta');
          }
        }

        scanDOM();
        setTimeout(scanDOM, 1000);
        setTimeout(scanDOM, 2500);
      })();
    ''';

    controller.runJavaScript(snifferScript).catchError((_) {});
  }

  /// Verifies if a detected URL represents a direct stream/video link
  static bool _isValidMediaUrl(String url) {
    if (url.isEmpty || !url.startsWith('http')) return false;
    final lower = url.toLowerCase();

    // Ignore tracking/ads
    if (lower.contains('googleads') || lower.contains('analytics') || lower.contains('doubleclick')) {
      return false;
    }

    return lower.contains('.mp4') ||
        lower.contains('.m3u8') ||
        lower.contains('.mpd') ||
        lower.contains('.webm') ||
        lower.contains('tiktokcdn') ||
        lower.contains('fbcdn.net') ||
        lower.contains('cdninstagram.com') ||
        lower.contains('twimg.com/video') ||
        lower.contains('v.redd.it') ||
        lower.contains('googlevideo.com/videoplayback');
  }
}
