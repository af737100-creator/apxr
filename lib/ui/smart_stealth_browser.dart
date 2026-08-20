import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../engine/smart_url_filter.dart';
import '../engine/download_manager_service.dart';
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

  bool _isLoading = true;
  double _loadingProgress = 0.0;
  String _currentTitle = 'المتصفح // HyperPulse';
  String _currentUrl = '';

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
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (progress) {
            if (mounted) {
              setState(() {
                _loadingProgress = progress / 100.0;
                _isLoading = progress < 100;
              });
            }
          },
          onPageStarted: (url) {
            if (mounted) {
              setState(() {
                _currentUrl = url;
                _urlBarController.text = url;
                _isLoading = true;
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

        function findDownloadLink(element) {
          if (!element) return null;
          // Check data-url attribute (common in Uptodown / APKPure)
          var dataUrl = element.getAttribute('data-url') || element.getAttribute('data-href');
          if (dataUrl && dataUrl.startsWith('http')) return dataUrl;

          var href = element.getAttribute('href');
          if (href && (
            href.match(/\\.(apk|xapk|zip|rar|7z|mp4|mkv|mp3|pdf|iso|exe|tar|gz)(\\?|\$)/i) ||
            href.includes('mediafire.com/download') ||
            href.includes('mediafire.com/file/') ||
            href.includes('objects.githubusercontent.com') ||
            href.includes('download.uptodown.com') ||
            href.includes('dw.uptodown.com') ||
            href.includes('/post-download/') ||
            href.includes('/download/apk')
          )) {
            return href;
          }
          return null;
        }

        document.addEventListener('click', function(e) {
          var target = e.target;
          while (target && target.tagName !== 'A' && target.tagName !== 'BUTTON') {
            target = target.parentElement;
          }
          if (target) {
            var directUrl = findDownloadLink(target);
            if (directUrl && window.HyperPulseDownloader) {
              window.HyperPulseDownloader.postMessage(directUrl);
            }
          }
        }, true);
      })();
    ''';
    _webViewController.runJavaScript(script).catchError((_) {});
  }

  Future<void> _extractAndDownloadFromPage() async {
    HapticFeedback.mediumImpact();
    // 1. If current page is a social / YouTube URL, let CloudExtractor handle it directly
    if (CloudExtractorService.isSocialVideoPlatform(_currentUrl)) {
      _startDownloadDirectly(_currentUrl);
      return;
    }

    // 2. Try extracting direct binary download URL from the page DOM (Uptodown, Mediafire, APKPure, GitHub, etc.)
    try {
      final jsResult = await _webViewController.runJavaScriptReturningResult('''
        (function() {
          // Check for Uptodown direct download button
          var uptodownBtn = document.querySelector('#detail-download-button, a[data-url*="uptodown"], a.button.download');
          if (uptodownBtn) {
            var uUrl = uptodownBtn.getAttribute('data-url') || uptodownBtn.getAttribute('href');
            if (uUrl && uUrl.startsWith('http')) return uUrl;
          }

          // Check for MediaFire download button
          var mfBtn = document.querySelector('#downloadButton, a[aria-label="Download file"], .download_link a');
          if (mfBtn && mfBtn.href && mfBtn.href.startsWith('http')) {
            return mfBtn.href;
          }

          // Check for standard APK / Media links on page
          var links = document.querySelectorAll('a[href*=".apk"], a[href*=".zip"], a[href*=".mp4"], a[href*="download"]');
          for (var i = 0; i < links.length; i++) {
            var h = links[i].href;
            if (h && (h.includes('.apk') || h.includes('.zip') || h.includes('.mp4') || h.includes('uptodown.com/dwn/'))) {
              return h;
            }
          }

          // Check for HTML5 video sources
          var vid = document.querySelector('video source, video');
          if (vid && vid.src && vid.src.startsWith('http')) {
            return vid.src;
          }

          // If no direct link extracted, trigger click on primary download button on the page
          var primaryBtn = document.querySelector('#detail-download-button, #downloadButton, a.button.download, button[type="submit"]');
          if (primaryBtn) {
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
              content: Text('⚡ جاري بدء التحميل عبر الزر الرئيسي في الصفحة...'),
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

    // Fallback if URL is already a direct file or social media
    if (SmartUrlFilter.isDownloadableFileUrl(_currentUrl) || CloudExtractorService.isSocialVideoPlatform(_currentUrl)) {
      _startDownloadDirectly(_currentUrl);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('اضغط على زر التنزيل داخل الصفحة لتحميل الملف الحقيقي'),
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
    HapticFeedback.mediumImpact();

    try {
      final task = await _manager.enqueueDownload(
        url: url,
        preferredTitle: customTitle ?? _currentTitle,
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

            // 5. Bottom Navigation Bar
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
}
