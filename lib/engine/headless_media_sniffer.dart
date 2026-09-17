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
    Duration timeout = const Duration(seconds: 14),
  }) async {
    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(targetUrl.trim());
    if (cleanUrl.isEmpty || !cleanUrl.startsWith('http')) return null;

    final completer = Completer<CloudExtractedMedia?>();
    Timer? timeoutTimer;
    Timer? domScanTimer;
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
              domScanTimer?.cancel();
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
                domScanTimer?.cancel();
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
          onProgress: (int progress) {
            if (progress > 25 && !completer.isCompleted && controller != null) {
              _injectSnifferScript(controller);
            }
          },
          onPageFinished: (url) async {
            if (completer.isCompleted || controller == null) return;
            // Inject VidMate-style deep media interception JavaScript
            _injectSnifferScript(controller);
          },
        ),
      );

      // Fast periodic DOM scanner to catch active <video> tags immediately
      domScanTimer = Timer.periodic(const Duration(milliseconds: 350), (timer) async {
        if (completer.isCompleted || controller == null) {
          timer.cancel();
          return;
        }
        try {
          final res = await controller.runJavaScriptReturningResult('''
            (function() {
              var vids = document.querySelectorAll('video');
              for (var i = 0; i < vids.length; i++) {
                var s = vids[i].currentSrc || vids[i].src;
                if (s && s.startsWith('http') && !s.startsWith('blob:')) return s;
                var sources = vids[i].querySelectorAll('source');
                for (var j = 0; j < sources.length; j++) {
                  var src = sources[j].src;
                  if (src && src.startsWith('http') && !src.startsWith('blob:')) return src;
                }
              }
              var og = document.querySelector('meta[property="og:video:secure_url"], meta[property="og:video"], meta[name="twitter:player:stream"]');
              if (og) {
                var c = og.getAttribute('content');
                if (c && c.startsWith('http')) return c;
              }
              return null;
            })()
          ''');
          final found = res.toString().replaceAll('"', '').trim();
          if (found.isNotEmpty && found != 'null' && found.startsWith('http') && _isValidMediaUrl(found)) {
            if (!completer.isCompleted) {
              timer.cancel();
              timeoutTimer?.cancel();
              controller.loadRequest(Uri.parse('about:blank')).catchError((_) {});
              completer.complete(
                CloudExtractedMedia(
                  success: true,
                  originalUrl: cleanUrl,
                  directStreamUrl: found,
                  title: CloudExtractedMedia.sanitizeFilename('Video_${DateTime.now().millisecondsSinceEpoch}', 'mp4'),
                  format: 'mp4',
                  quality: 'Headless DOM Scan ⚡',
                  serverUsed: 'Local Headless Engine',
                  isDirectFallback: false,
                ),
              );
            }
          }
        } catch (_) {}
      });

      // Set safety timeout so the process never hangs indefinitely
      timeoutTimer = Timer(timeout, () {
        if (!completer.isCompleted) {
          debugPrint('[HeadlessMediaSniffer] Timeout reached for: $cleanUrl');
          domScanTimer?.cancel();
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
      domScanTimer?.cancel();
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

          var lower = url.toLowerCase();
          // Filter out images, avatars, icons, analytics and ads
          if (lower.includes('.jpg') || lower.includes('.jpeg') || lower.includes('.png') ||
              lower.includes('.webp') || lower.includes('.gif') || lower.includes('.svg') ||
              lower.includes('avatar') || lower.includes('googleads') || lower.includes('doubleclick') ||
              lower.includes('analytics') || lower.includes('telemetry') || lower.includes('tiktokv.com') ||
              lower.includes('ttwstatic') || lower.includes('mcs-sg') || lower.includes('mon-sg')) {
            return;
          }

          var isMedia = lower.includes('.mp4') ||
                        lower.includes('.m3u8') ||
                        lower.includes('.mpd') ||
                        lower.includes('.webm') ||
                        (lower.includes('tiktokcdn.com') && (lower.includes('/video/') || lower.includes('/tos/'))) ||
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

        // Helper to detect tracker / ad domain
        function isTrackerUrl(u) {
          if (!u || typeof u !== 'string') return false;
          var l = u.toLowerCase();
          return l.includes('tiktokv.com') ||
                 l.includes('ttwstatic.com') ||
                 l.includes('mcs-sg') ||
                 l.includes('mon-sg') ||
                 l.includes('doubleclick') ||
                 l.includes('googleads') ||
                 l.includes('google-analytics') ||
                 l.includes('googlesyndication') ||
                 l.includes('adnxs') ||
                 l.includes('telemetry') ||
                 l.includes('app-measurement') ||
                 l.includes('/telemetry') ||
                 l.includes('/beacon') ||
                 l.includes('taboola') ||
                 l.includes('outbrain');
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

        // 2. Hook window.fetch & BLOCK tracking / telemetry requests
        try {
          if (window.fetch) {
            var origFetch = window.fetch;
            window.fetch = function() {
              try {
                var input = arguments[0];
                var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                if (url) {
                  if (isTrackerUrl(url)) {
                    // Instantly resolve empty response so no TCP connection is made
                    return Promise.resolve(new Response('{}', { status: 200, statusText: 'OK' }));
                  }
                  reportMedia(url, 'fetch');
                }
              } catch(e) {}
              return origFetch.apply(this, arguments);
            };
          }
        } catch(e) {}

        // 3. Hook XMLHttpRequest & BLOCK tracking / telemetry requests
        try {
          if (window.XMLHttpRequest) {
            var origOpen = XMLHttpRequest.prototype.open;
            var origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
              try {
                if (url) {
                  if (isTrackerUrl(String(url))) {
                    this.__isBlockedTracker = true;
                  }
                  reportMedia(url, 'xhr');
                }
              } catch(e) {}
              return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
              if (this.__isBlockedTracker) {
                // Silently swallow tracker request without sending packets
                return;
              }
              return origSend.apply(this, arguments);
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
        setTimeout(scanDOM, 800);
        setTimeout(scanDOM, 2000);
      })();
    ''';

    controller.runJavaScript(snifferScript).catchError((_) {});
  }

  /// Verifies if a detected URL represents a direct stream/video link
  static bool _isValidMediaUrl(String url) {
    if (url.isEmpty || !url.startsWith('http')) return false;
    final lower = url.toLowerCase();

    // Reject images, thumbnails, avatars, tracking, fonts, stylesheets, and scripts
    if (lower.contains('.jpg') ||
        lower.contains('.jpeg') ||
        lower.contains('.png') ||
        lower.contains('.webp') ||
        lower.contains('.gif') ||
        lower.contains('.svg') ||
        lower.contains('.ico') ||
        lower.contains('.css') ||
        lower.contains('.js') ||
        lower.contains('.woff') ||
        lower.contains('.ttf') ||
        lower.contains('avatar') ||
        SmartUrlFilter.isAdOrTrackingUrl(url)) {
      return false;
    }

    return lower.contains('.mp4') ||
        lower.contains('.m3u8') ||
        lower.contains('.mpd') ||
        lower.contains('.webm') ||
        (lower.contains('tiktokcdn') && (lower.contains('video') || lower.contains('tos-') || lower.contains('.mp4') || lower.contains('mime_type=video'))) ||
        (lower.contains('fbcdn.net') && (lower.contains('video') || lower.contains('.mp4') || lower.contains('bytestart') || lower.contains('.m3u8'))) ||
        (lower.contains('cdninstagram.com') && (lower.contains('video') || lower.contains('.mp4') || lower.contains('bytestart') || lower.contains('.m3u8'))) ||
        (lower.contains('twimg.com') && (lower.contains('video') || lower.contains('.mp4') || lower.contains('.m3u8'))) ||
        (lower.contains('v.redd.it') && (lower.contains('dash') || lower.contains('.mp4') || lower.contains('hls'))) ||
        lower.contains('googlevideo.com/videoplayback');
  }
}
