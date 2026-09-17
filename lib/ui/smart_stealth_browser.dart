import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../engine/smart_url_filter.dart';
import '../engine/download_manager_service.dart';
import '../engine/cloud_extractor_service.dart';
import '../engine/universal_app_store_resolver.dart';
import 'multi_downloads_screen.dart';

/// [SmartStealthBrowser] is an integrated in-app web browser designed for flawless
/// downloading from any source (MediaFire, APKPure, Uptodown, GitHub releases, Google Drive, Social Media, etc.).
///
/// Features:
/// 1. Completely removed intrusive "التحميل الصاروخي" blocking popups.
/// 2. Direct automatic background download enqueueing into Multi-Download queue.
/// 3. Injected JavaScript listener catching clicks on download buttons & direct links seamlessly.
/// 4. Live Multi-Downloads Badge Button in the top toolbar to track concurrent tasks.
class SmartStealthBrowser extends StatefulWidget {
  final String initialUrl;
  final Function(String downloadUrl, String? suggestedTitle)? onDownloadCaught;

  const SmartStealthBrowser({
    super.key,
    this.initialUrl = 'https://www.google.com',
    this.onDownloadCaught,
  });

  static Future<void> open({
    required BuildContext context,
    String initialUrl = 'https://www.google.com',
    Function(String downloadUrl, String? suggestedTitle)? onDownloadCaught,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (ctx) => SmartStealthBrowser(
          initialUrl: initialUrl,
          onDownloadCaught: onDownloadCaught,
        ),
      ),
    );
  }

  @override
  State<SmartStealthBrowser> createState() => _SmartStealthBrowserState();
}

class _SmartStealthBrowserState extends State<SmartStealthBrowser> {
  // Theme
  static const Color deepCarbon = Color(0xFF0A0A0C);
  static const Color fieryAmber = Color(0xFFFF4F00);
  static const Color surfaceCard = Color(0xFF161418);

  late final WebViewController _webViewController;
  late final TextEditingController _urlBarController;
  final DownloadManagerService _manager = DownloadManagerService();
  final CloudExtractorService _cloudExtractor = CloudExtractorService();

  bool _isLoading = true;
  double _loadingProgress = 0.0;
  String _currentTitle = 'المتصفح // HyperPulse';
  String _currentUrl = '';
  String? _lastDownloadedUrl;
  DateTime? _lastDownloadTime;
  String? _detectedMediaStreamUrl;
  String? _detectedMediaTitle;

  final List<Map<String, String>> _quickBookmarks = [
    {'name': 'MediaFire', 'url': 'https://www.mediafire.com', 'icon': '🔥'},
    {'name': 'APKPure', 'url': 'https://apkpure.net', 'icon': '📦'},
    {'name': 'Uptodown', 'url': 'https://en.uptodown.com/android', 'icon': '📲'},
    {'name': 'YouTube', 'url': 'https://m.youtube.com', 'icon': '▶️'},
    {'name': 'TikTok', 'url': 'https://www.tiktok.com', 'icon': '🎵'},
    {'name': 'Facebook', 'url': 'https://m.facebook.com', 'icon': '👥'},
    {'name': 'Instagram', 'url': 'https://www.instagram.com', 'icon': '📸'},
    {'name': 'Google', 'url': 'https://www.google.com', 'icon': '🔍'},
  ];

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl;
    _urlBarController = TextEditingController(text: widget.initialUrl);
    _manager.addListener(_onManagerUpdate);

    _initWebViewController();
  }

  void _onManagerUpdate() {
    if (mounted) setState(() {});
  }

  void _initWebViewController() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(deepCarbon)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Mobile; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.6478.122 Mobile Safari/537.36',
      )
      ..addJavaScriptChannel(
        'HyperPulseDownloader',
        onMessageReceived: (JavaScriptMessage message) {
          final downloadUrl = message.message.trim();
          if (downloadUrl.isNotEmpty && downloadUrl.startsWith('http')) {
            _startDownloadDirectly(downloadUrl);
          }
        },
      )
      ..addJavaScriptChannel(
        'HyperPulseMediaSniffer',
        onMessageReceived: (JavaScriptMessage message) {
          try {
            final raw = message.message.trim();
            if (raw.startsWith('{')) {
              final Map<String, dynamic> data = jsonDecode(raw);
              final streamUrl = data['url']?.toString();
              if (streamUrl != null && streamUrl.startsWith('http')) {
                if (mounted) {
                  setState(() {
                    _detectedMediaStreamUrl = streamUrl;
                    if (data['title'] != null && data['title'].toString().trim().isNotEmpty) {
                      _detectedMediaTitle = data['title'].toString().trim();
                    }
                  });
                }
              }
            } else if (raw.startsWith('http')) {
              if (mounted) {
                setState(() {
                  _detectedMediaStreamUrl = raw;
                });
              }
            }
          } catch (_) {}
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                _loadingProgress = progress / 100.0;
                _isLoading = progress < 100;
              });
              // Early injection when page structure is ready (instant stream interception)
              if (progress >= 30) {
                _injectDownloadInterceptorScript();
              }
            }
          },
          onUrlChange: (UrlChange change) {
            final newUrl = change.url;
            if (newUrl != null && newUrl.isNotEmpty && mounted) {
              setState(() {
                _currentUrl = newUrl;
                _urlBarController.text = newUrl;
                _detectedMediaStreamUrl = null;
                _detectedMediaTitle = null;
              });
              _injectDownloadInterceptorScript();
            }
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _currentUrl = url;
                _urlBarController.text = url;
                _isLoading = true;
                _detectedMediaStreamUrl = null;
                _detectedMediaTitle = null;
              });
            }
          },
          onPageFinished: (url) async {
            if (mounted) {
              final title = await _webViewController.getTitle();
              setState(() {
                _currentUrl = url;
                _urlBarController.text = url;
                _isLoading = false;
                if (title != null && title.isNotEmpty) {
                  _currentTitle = title;
                }
              });

              // Inject Smart Download Interceptor Script
              _injectDownloadInterceptorScript();
            }
          },
          onNavigationRequest: (request) {
            final targetUrl = request.url;

            // 1. Block aggressive ad networks & telemetry trackers (saves bandwidth & prevents unreachable TCP loops)
            if (SmartUrlFilter.isAdOrTrackingUrl(targetUrl)) {
              return NavigationDecision.prevent;
            }

            if (SmartUrlFilter.isDownloadableFileUrl(targetUrl)) {
              _startDownloadDirectly(targetUrl);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    _webViewController.loadRequest(Uri.parse(_formatUrl(widget.initialUrl)));
  }

  void _injectDownloadInterceptorScript() {
    const script = '''
      (function() {
        if (window.__hyperpulse_injected) return;
        window.__hyperpulse_injected = true;

        function isPromoStoreLink(href) {
          if (!href) return false;
          var lower = href.toLowerCase();
          return lower.includes('apkpure-app') ||
                 lower.includes('com.apkpure.aegon') ||
                 lower.includes('uptodown-app') ||
                 lower.includes('from=banner') ||
                 lower.includes('from=popup_app') ||
                 lower.includes('from=app_detail_install');
        }

        function findDownloadLink(element) {
          if (!element) return null;
          
          // Check data-url attribute (common in Uptodown / APKPure)
          var dataUrl = element.getAttribute('data-url') || element.getAttribute('data-href');
          if (dataUrl && dataUrl.startsWith('http') && !isPromoStoreLink(dataUrl)) return dataUrl;

          var href = element.getAttribute('href') || element.getAttribute('src');
          if (href && !isPromoStoreLink(href)) {
            if (
              href.match(/\\.(apk|xapk|zip|rar|7z|mp4|mkv|mp3|pdf|iso|exe|tar|gz)(\\?|\$)/i) ||
              href.includes('/b/APK/') ||
              href.includes('/b/XAPK/') ||
              href.includes('d.apkpure.net') ||
              href.includes('d.apkpure.com') ||
              href.includes('download.apkpure.com') ||
              href.includes('mediafire.com/download') ||
              href.includes('mediafire.com/file/') ||
              href.includes('objects.githubusercontent.com') ||
              href.includes('download.uptodown.com') ||
              href.includes('dw.uptodown.com') ||
              href.includes('/dwn/') ||
              href.includes('/post-download/') ||
              href.includes('/download/apk') ||
              href.includes('download.php') ||
              href.includes('releases/download') ||
              href.includes('files/latest/download')
            ) {
              return href;
            }
          }

          // Check if element is the APKPure "Click here" link
          if (element.id === 'download_link' || (element.textContent && element.textContent.toLowerCase().includes('click here'))) {
            var dl = element.getAttribute('href');
            if (dl && dl.startsWith('http') && !isPromoStoreLink(dl)) return dl;
          }

          return null;
        }

        // Intercept link and button clicks to prevent continuous page reloading
        document.addEventListener('click', function(e) {
          var target = e.target;
          while (target && target.tagName !== 'A' && target.tagName !== 'BUTTON') {
            target = target.parentElement;
          }
          if (target) {
            var directUrl = findDownloadLink(target);
            if (directUrl && window.HyperPulseDownloader) {
              e.preventDefault();
              e.stopPropagation();
              window.HyperPulseDownloader.postMessage(directUrl);
              return false;
            }
          }
        }, true);

        // Auto-sniff APKPure / Uptodown automatic download redirection once
        function checkAutoDownloadLink() {
          var apkPureLink = document.querySelector('#download_link, a[href*="/b/APK/"], a[href*="/b/XAPK/"], a[href*="d.apkpure.net"]');
          if (apkPureLink) {
            var dlUrl = apkPureLink.getAttribute('href');
            if (dlUrl && dlUrl.startsWith('http') && !isPromoStoreLink(dlUrl) && window.HyperPulseDownloader) {
              window.HyperPulseDownloader.postMessage(dlUrl);
              return;
            }
          }
        }

        setTimeout(checkAutoDownloadLink, 1500);

        // VidMate Media Stream Interception Hooks
        function reportMedia(url, type) {
          if (!url || typeof url !== 'string') return;
          if (!url.startsWith('http://') && !url.startsWith('https://')) return;
          if (url.includes('googleads') || url.includes('analytics') || url.includes('doubleclick')) return;

          var lower = url.toLowerCase();

          // Reject static image assets, scripts, stylesheets, and icons
          if (lower.includes('.jpg') || lower.includes('.jpeg') || lower.includes('.png') ||
              lower.includes('.webp') || lower.includes('.gif') || lower.includes('.svg') ||
              lower.includes('.ico') || lower.includes('.css') || lower.includes('.js') ||
              lower.includes('.woff') || lower.includes('.ttf') || lower.includes('avatar')) {
            return;
          }

          var isMedia = lower.includes('.mp4') ||
                        lower.includes('.m3u8') ||
                        lower.includes('.mpd') ||
                        lower.includes('.webm') ||
                        (lower.includes('tiktokcdn') && (lower.includes('video') || lower.includes('tos-') || lower.includes('.mp4') || lower.includes('mime_type=video'))) ||
                        (lower.includes('fbcdn.net') && (lower.includes('video') || lower.includes('.mp4') || lower.includes('bytestart') || lower.includes('.m3u8'))) ||
                        (lower.includes('cdninstagram.com') && (lower.includes('video') || lower.includes('.mp4') || lower.includes('bytestart') || lower.includes('.m3u8'))) ||
                        (lower.includes('twimg.com') && (lower.includes('video') || lower.includes('.mp4') || lower.includes('.m3u8'))) ||
                        (lower.includes('v.redd.it') && (lower.includes('dash') || lower.includes('.mp4') || lower.includes('hls'))) ||
                        lower.includes('googlevideo.com/videoplayback');

          if (isMedia && window.HyperPulseMediaSniffer) {
            window.HyperPulseMediaSniffer.postMessage(JSON.stringify({
              url: url,
              title: document.title || 'Video',
              type: type || 'stream'
            }));
          }
        }

        try {
          var origPlay = HTMLMediaElement.prototype.play;
          HTMLMediaElement.prototype.play = function() {
            if (this.currentSrc) reportMedia(this.currentSrc, 'play');
            else if (this.src) reportMedia(this.src, 'play');
            return origPlay.apply(this, arguments);
          };
        } catch(e) {}

        try {
          if (window.fetch) {
            var origFetch = window.fetch;
            window.fetch = function() {
              try {
                var input = arguments[0];
                var u = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                if (u) reportMedia(u, 'fetch');
              } catch(e) {}
              return origFetch.apply(this, arguments);
            };
          }
        } catch(e) {}

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

        // Global capture-phase listeners for video play events
        try {
          window.addEventListener('play', function(e) {
            var t = e.target;
            if (t && (t.tagName === 'VIDEO' || t.tagName === 'AUDIO')) {
              var s = t.currentSrc || t.src;
              if (s) reportMedia(s, 'play-event');
            }
          }, true);
          window.addEventListener('playing', function(e) {
            var t = e.target;
            if (t && (t.tagName === 'VIDEO' || t.tagName === 'AUDIO')) {
              var s = t.currentSrc || t.src;
              if (s) reportMedia(s, 'playing-event');
            }
          }, true);
        } catch(e) {}

        function scanPageMedia() {
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

        // MutationObserver to immediately detect dynamically mounted videos (SPA, infinite scroll, Reels, Shorts)
        try {
          if (window.MutationObserver) {
            var observer = new MutationObserver(function() {
              scanPageMedia();
            });
            observer.observe(document.documentElement, {
              childList: true,
              subtree: true,
              attributes: true,
              attributeFilter: ['src', 'currentsrc']
            });
          }
        } catch(e) {}

        scanPageMedia();
        setTimeout(scanPageMedia, 500);
        setTimeout(scanPageMedia, 1200);
        setTimeout(scanPageMedia, 2500);
        setTimeout(scanPageMedia, 4500);
      })();
    ''';
    _webViewController.runJavaScript(script).catchError((_) {});
  }

  Future<void> _extractAndDownloadFromPage() async {
    HapticFeedback.mediumImpact();

    // 0. If media stream was already sniffed from video playback or network:
    if (_detectedMediaStreamUrl != null && _detectedMediaStreamUrl!.isNotEmpty) {
      _startDownloadDirectly(_detectedMediaStreamUrl!, customTitle: _detectedMediaTitle);
      return;
    }

    // 1. If current page is a social / video platform (Instagram, Facebook, Twitter, TikTok, YouTube, etc.)
    if (CloudExtractorService.isSocialVideoPlatform(_currentUrl)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚡ جاري فحص الصفحة واستخراج تيار الفيديو المباشر...'),
            backgroundColor: Color(0xFF1F1D24),
            duration: Duration(seconds: 2),
          ),
        );
      }

      // First check active video element or OpenGraph video tags in the DOM
      try {
        final domVideoResult = await _webViewController.runJavaScriptReturningResult('''
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
        final domUrl = domVideoResult.toString().replaceAll('"', '').trim();
        if (domUrl.isNotEmpty && domUrl != 'null' && domUrl.startsWith('http')) {
          _startDownloadDirectly(domUrl, customTitle: _currentTitle);
          return;
        }
      } catch (_) {}

      // If not directly present in DOM, pass to CloudExtractorService to extract the stream
      final extracted = await _cloudExtractor.extractDirectMedia(_currentUrl);
      if (extracted.success && extracted.directStreamUrl.isNotEmpty) {
        _startDownloadDirectly(extracted.directStreamUrl, customTitle: extracted.title);
        return;
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🎬 يرجى الضغط على زر تشغيل الفيديو داخل الصفحة ليتم التقاطه وتحميله فوراً'),
              backgroundColor: Color(0xFFEAB308),
              duration: Duration(seconds: 4),
            ),
          );
        }
        return;
      }
    }

    // 2. First attempt: Use UniversalAppStoreResolver directly for store URLs
    if (UniversalAppStoreResolver.isStoreOrHostingPage(_currentUrl)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚡ جاري استخراج رابط التطبيق المباشر من المتجر...'),
            backgroundColor: Color(0xFF1F1D24),
            duration: Duration(seconds: 2),
          ),
        );
      }
      final resolved = await UniversalAppStoreResolver.resolveStoreUrl(_currentUrl, pageTitle: _currentTitle);
      if (resolved != null && resolved.directDownloadUrl.isNotEmpty) {
        _startDownloadDirectly(resolved.directDownloadUrl, customTitle: resolved.cleanFileName);
        return;
      }
    }

    // 3. Try extracting direct binary download URL from the page DOM (APKPure, Uptodown, Mediafire, GitHub, etc.)
    try {
      final jsResult = await _webViewController.runJavaScriptReturningResult('''
        (function() {
          function isPromo(url) {
            if (!url) return true;
            var l = url.toLowerCase();
            return l.includes('apkpure-app') || l.includes('com.apkpure.aegon') || l.includes('uptodown-app');
          }

          // 1. Check for APKPure direct app download link
          var apkPureBtn = document.querySelector('#download_link, a[href*="/b/APK/"], a[href*="/b/XAPK/"], a[href*="d.apkpure.net"], a[href*="download.apkpure.com"]');
          if (apkPureBtn) {
            var apkUrl = apkPureBtn.getAttribute('href');
            if (apkUrl && apkUrl.startsWith('http') && !isPromo(apkUrl)) return apkUrl;
          }

          // 2. Check for Uptodown direct download button
          var uptodownBtn = document.querySelector('#detail-download-button, a[data-url*="uptodown"], a[href*="dw.uptodown.com"], a[href*="/dwn/"]');
          if (uptodownBtn) {
            var uUrl = uptodownBtn.getAttribute('data-url') || uptodownBtn.getAttribute('href');
            if (uUrl && uUrl.startsWith('http') && !isPromo(uUrl)) return uUrl;
          }

          // 3. Check for MediaFire download button
          var mfBtn = document.querySelector('#downloadButton, a[aria-label="Download file"], .download_link a');
          if (mfBtn && mfBtn.href && mfBtn.href.startsWith('http')) {
            return mfBtn.href;
          }

          // 4. Check for GitHub release download asset
          var ghAsset = document.querySelector('a[href*="/releases/download/"]');
          if (ghAsset && ghAsset.href && ghAsset.href.startsWith('http')) {
            return ghAsset.href;
          }

          // 5. Check for SourceForge latest download
          var sfBtn = document.querySelector('a[href*="/files/latest/download"]');
          if (sfBtn && sfBtn.href && sfBtn.href.startsWith('http')) {
            return sfBtn.href;
          }

          // 6. Scan all download links on page, filtering out promo store links
          var links = document.querySelectorAll('a[href*=".apk"], a[href*=".xapk"], a[href*=".zip"], a[href*=".mp4"], a[href*="download"]');
          for (var i = 0; i < links.length; i++) {
            var h = links[i].href;
            if (h && h.startsWith('http') && !isPromo(h)) {
              if (h.includes('.apk') || h.includes('.xapk') || h.includes('.zip') || h.includes('.mp4') || h.includes('/b/APK/') || h.includes('/b/XAPK/') || h.includes('uptodown.com/dwn/')) {
                return h;
              }
            }
          }

          // 7. Check for HTML5 video sources
          var vid = document.querySelector('video source, video');
          if (vid && vid.src && vid.src.startsWith('http')) {
            return vid.src;
          }

          // 8. If on download page with standard download button, extract its direct attribute or trigger it safely
          var primaryBtn = document.querySelector('#download_link, #detail-download-button, #downloadButton, a.button.download');
          if (primaryBtn) {
            var dataUrl = primaryBtn.getAttribute('data-url') || primaryBtn.getAttribute('href');
            if (dataUrl && dataUrl.startsWith('http') && !isPromo(dataUrl)) return dataUrl;
            primaryBtn.click();
            return 'CLICKED_PAGE_BUTTON';
          }

          return null;
        })();
      ''');

      var foundUrl = jsResult.toString().replaceAll('"', '').trim();
      if (foundUrl == 'CLICKED_PAGE_BUTTON') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('⚡ جاري بدء التحميل واستخراج حزمة التطبيق المباشرة...'),
              backgroundColor: Color(0xFF1F1D24),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }

      if (foundUrl.isNotEmpty && foundUrl != 'null' && foundUrl.startsWith('http')) {
        _startDownloadDirectly(foundUrl);
        return;
      }
    } catch (e) {
      debugPrint('[SmartStealthBrowser] DOM sniffing error: $e');
    }

    // Fallback if URL is already a direct file (APK, ZIP, MP4, etc.)
    if (SmartUrlFilter.isDownloadableFileUrl(_currentUrl)) {
      _startDownloadDirectly(_currentUrl);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('اضغط على زر التنزيل داخل الصفحة لبدء تحميل التطبيق مباشرة دون إعادة تحميل المتصفح'),
            backgroundColor: Color(0xFFEAB308),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  String _formatUrl(String input) {
    var trimmed = input.trim();
    if (trimmed.isEmpty) return 'https://www.google.com';
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      if (trimmed.contains('.') && !trimmed.contains(' ')) {
        trimmed = 'https://$trimmed';
      } else {
        trimmed = 'https://www.google.com/search?q=${Uri.encodeComponent(trimmed)}';
      }
    }
    return trimmed;
  }

  Future<void> _startDownloadDirectly(String url, {String? customTitle}) async {
    final now = DateTime.now();
    if (_lastDownloadedUrl == url &&
        _lastDownloadTime != null &&
        now.difference(_lastDownloadTime!).inSeconds < 4) {
      debugPrint('[SmartStealthBrowser] 🛡️ Ignored duplicate download request within 4s: $url');
      return;
    }
    _lastDownloadedUrl = url;
    _lastDownloadTime = now;

    HapticFeedback.mediumImpact();

    try {
      final cleanTitle = UniversalAppStoreResolver.cleanAppTitle(customTitle ?? _currentTitle);
      final task = await _manager.enqueueDownload(
        url: url,
        preferredTitle: cleanTitle,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            backgroundColor: const Color(0xFF181519),
            duration: const Duration(seconds: 4),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: fieryAmber, width: 1.2),
            ),
            content: Row(
              children: [
                const Icon(Icons.bolt, color: fieryAmber, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'بدأ التحميل المتزامن ⚡',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                      Text(
                        task.fileName,
                        style: const TextStyle(color: Color(0xFFB5AFB2), fontSize: 11),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            action: SnackBarAction(
              label: 'التنزيلات (${_manager.activeCount})',
              textColor: fieryAmber,
              onPressed: () => MultiDownloadsScreen.open(context),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في بدء التنزيل: $e'),
            backgroundColor: const Color(0xFFEF4444),
          ),
        );
      }
    }
  }

  void _navigateToUrl(String input) {
    final target = _formatUrl(input);
    _webViewController.loadRequest(Uri.parse(target));
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
    _manager.removeListener(_onManagerUpdate);
    _urlBarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: deepCarbon,
      body: SafeArea(
        child: Column(
          children: [
            // 1. Top Stealth Cockpit App Bar
            _buildTopAppBar(),

            // 2. Linear Loading Bar
            if (_isLoading)
              LinearProgressIndicator(
                value: _loadingProgress,
                backgroundColor: Colors.transparent,
                valueColor: const AlwaysStoppedAnimation<Color>(fieryAmber),
                minHeight: 2.5,
              ),

            // 3. Quick Bookmarks Pill Carousel
            _buildBookmarksBar(),

            // 4. Embedded WebView
            Expanded(
              child: WebViewWidget(controller: _webViewController),
            ),

            // 5. Detected Video Floating Banner (VidMate Architecture)
            if (_detectedMediaStreamUrl != null)
              _buildDetectedMediaBanner(),

            // 6. Bottom Navigation Bar
            _buildBottomNavControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopAppBar() {
    final activeCount = _manager.activeCount;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: surfaceCard,
        border: Border(
          bottom: BorderSide(color: fieryAmber.withOpacity(0.2)),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'رجوع للقمرة الرئيسية',
          ),
          Expanded(
            child: Container(
              height: 38,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF0F0E12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF2C282B)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline, color: Color(0xFF4ADE80), size: 14),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _urlBarController,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                      decoration: const InputDecoration(
                        hintText: 'ابحث أو أدخل رابط للتحميل...',
                        hintStyle: TextStyle(color: Color(0xFF6B6568), fontSize: 11),
                        border: InputBorder.none,
                        isDense: true,
                      ),
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.go,
                      onSubmitted: _navigateToUrl,
                    ),
                  ),
                  if (_urlBarController.text.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _urlBarController.clear();
                        setState(() {});
                      },
                      child: const Icon(Icons.clear, color: Color(0xFF8E888A), size: 16),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: Icon(
              _isLoading ? Icons.close : Icons.refresh,
              color: fieryAmber,
              size: 20,
            ),
            onPressed: () {
              _webViewController.reload();
            },
          ),

          // Multi-Downloads Button with Live Active Badge
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(
                icon: Icon(
                  Icons.download_rounded,
                  color: activeCount > 0 ? fieryAmber : Colors.white,
                  size: 22,
                ),
                onPressed: () => MultiDownloadsScreen.open(context),
                tooltip: 'قمرة التنزيلات المتعددة',
              ),
              if (activeCount > 0)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: fieryAmber,
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: [
                        BoxShadow(
                          color: fieryAmber.withOpacity(0.5),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                    child: Text(
                      '$activeCount',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBookmarksBar() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(vertical: 4),
      color: const Color(0xFF100F13),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _quickBookmarks.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final bookmark = _quickBookmarks[index];
          return GestureDetector(
            onTap: () => _navigateToUrl(bookmark['url']!),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1D1B20),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF332F32)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(bookmark['icon']!, style: const TextStyle(fontSize: 12)),
                  const SizedBox(width: 6),
                  Text(
                    bookmark['name']!,
                    style: const TextStyle(
                      color: Color(0xFFD6D0D3),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBottomNavControls() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: surfaceCard,
        border: Border(
          top: BorderSide(color: const Color(0xFF2C282B).withOpacity(0.5)),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios, color: Color(0xFFD6D0D3), size: 16),
                onPressed: () async {
                  if (await _webViewController.canGoBack()) {
                    await _webViewController.goBack();
                  }
                },
                tooltip: 'السابق',
              ),
              IconButton(
                icon: const Icon(Icons.arrow_forward_ios, color: Color(0xFFD6D0D3), size: 16),
                onPressed: () async {
                  if (await _webViewController.canGoForward()) {
                    await _webViewController.goForward();
                  }
                },
                tooltip: 'التالي',
              ),
              IconButton(
                icon: const Icon(Icons.home_outlined, color: Color(0xFFD6D0D3), size: 20),
                onPressed: () => _navigateToUrl('https://www.google.com'),
                tooltip: 'الصفحة الرئيسية',
              ),
            ],
          ),

          // Direct Download Active Page Button
          TextButton.icon(
            onPressed: _extractAndDownloadFromPage,
            icon: const Icon(Icons.bolt, color: fieryAmber, size: 16),
            label: const Text(
              'استخراج وتنزيل ⚡',
              style: TextStyle(
                color: fieryAmber,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            style: TextButton.styleFrom(
              backgroundColor: fieryAmber.withOpacity(0.12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: fieryAmber.withOpacity(0.3)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDetectedMediaBanner() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            fieryAmber.withOpacity(0.92),
            const Color(0xFFD9381E).withOpacity(0.96),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: fieryAmber.withOpacity(0.4),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.play_circle_fill, color: Colors.white, size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'تم التقاط فيديو مباشر ⚡ (VidMate Sniffer)',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
                Text(
                  _detectedMediaTitle ?? _currentTitle,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            icon: const Icon(Icons.download, size: 14, color: fieryAmber),
            label: const Text(
              'تحميل',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            onPressed: () {
              final streamUrl = _detectedMediaStreamUrl;
              if (streamUrl != null) {
                _startDownloadDirectly(streamUrl, customTitle: _detectedMediaTitle);
              }
            },
          ),
          const SizedBox(width: 4),
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70, size: 18),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () {
              setState(() {
                _detectedMediaStreamUrl = null;
              });
            },
          ),
        ],
      ),
    );
  }
}
