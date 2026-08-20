import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../engine/smart_url_filter.dart';
import '../engine/cloud_extractor_service.dart';

/// [SmartStealthBrowser] is an in-app integrated stealth web browser.
/// It enables users to browse any video or download site (YouTube, MediaFire, TikTok, APK sites, etc.)
/// and automatically intercepts download links and streams with 1-click Turbo download.
class SmartStealthBrowser extends StatefulWidget {
  final String initialUrl;
  final Function(String downloadUrl, String? suggestedTitle) onDownloadCaught;

  const SmartStealthBrowser({
    super.key,
    this.initialUrl = 'https://www.google.com',
    required this.onDownloadCaught,
  });

  static Future<void> open({
    required BuildContext context,
    String initialUrl = 'https://www.google.com',
    required Function(String downloadUrl, String? suggestedTitle) onDownloadCaught,
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

  bool _isLoading = true;
  double _loadingProgress = 0.0;
  String _currentTitle = 'المتصفح الداخلي // HyperPulse';
  String _currentUrl = '';
  String? _sniffedDownloadUrl;
  String? _sniffedDownloadTitle;

  final List<Map<String, String>> _quickBookmarks = [
    {'name': 'YouTube', 'url': 'https://m.youtube.com', 'icon': '▶️'},
    {'name': 'TikTok', 'url': 'https://www.tiktok.com', 'icon': '🎵'},
    {'name': 'Facebook', 'url': 'https://m.facebook.com', 'icon': '👥'},
    {'name': 'Instagram', 'url': 'https://www.instagram.com', 'icon': '📸'},
    {'name': 'MediaFire', 'url': 'https://www.mediafire.com', 'icon': '🔥'},
    {'name': 'APKPure', 'url': 'https://apkpure.net', 'icon': '📦'},
    {'name': 'Google', 'url': 'https://www.google.com', 'icon': '🔍'},
  ];

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.initialUrl;
    _urlBarController = TextEditingController(text: widget.initialUrl);

    _initWebViewController();
  }

  void _initWebViewController() {
    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(deepCarbon)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 14; Mobile; rv:124.0) Gecko/124.0 Firefox/124.0 HyperPulseBrowser/3.0',
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
              _sniffUrl(url);
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
              _sniffUrl(url);
            }
          },
          onNavigationRequest: (request) {
            final targetUrl = request.url;
            // Sniff if clicked link is a direct downloadable file
            if (SmartUrlFilter.isDownloadableFileUrl(targetUrl)) {
              _triggerDownloadCapture(targetUrl);
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      );

    _webViewController.loadRequest(Uri.parse(_formatUrl(widget.initialUrl)));
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

  void _sniffUrl(String url) {
    if (SmartUrlFilter.isDownloadableFileUrl(url)) {
      _triggerDownloadCapture(url);
    } else if (CloudExtractorService.isSocialVideoPlatform(url)) {
      setState(() {
        _sniffedDownloadUrl = url;
        _sniffedDownloadTitle = _currentTitle;
      });
    }
  }

  void _triggerDownloadCapture(String url) {
    HapticFeedback.heavyImpact();
    setState(() {
      _sniffedDownloadUrl = url;
      _sniffedDownloadTitle = url.split('/').last.split('?').first;
    });

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1B181A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: fieryAmber, width: 1.5),
        ),
        content: Row(
          children: [
            const Icon(Icons.download_for_offline, color: fieryAmber, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'تم التقاط ملف قابل للتحميل!',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    _sniffedDownloadTitle ?? url,
                    style: const TextStyle(color: Color(0xFFB5AFB2), fontSize: 10),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'تحميل فوري ⚡',
          textColor: fieryAmber,
          onPressed: _startDownloadingSniffedFile,
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  }

  void _startDownloadingSniffedFile() {
    if (_sniffedDownloadUrl != null) {
      widget.onDownloadCaught(_sniffedDownloadUrl!, _sniffedDownloadTitle);
      Navigator.of(context).pop();
    }
  }

  void _navigateToUrl(String input) {
    final target = _formatUrl(input);
    _webViewController.loadRequest(Uri.parse(target));
    FocusScope.of(context).unfocus();
  }

  @override
  void dispose() {
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
              child: Stack(
                children: [
                  WebViewWidget(controller: _webViewController),

                  // Floating Sniffer HUD Action Button
                  if (_sniffedDownloadUrl != null)
                    Positioned(
                      bottom: 20,
                      left: 20,
                      right: 20,
                      child: _buildFloatingSnifferHUD(),
                    ),
                ],
              ),
            ),

            // 5. Bottom Navigation Bar
            _buildBottomNavControls(),
          ],
        ),
      ),
    );
  }

  Widget _buildTopAppBar() {
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
                        hintText: 'ابحث في Google أو أدخل رابط موقع...',
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
              if (_isLoading) {
                // webview controller has no cancel, reload instead
                _webViewController.reload();
              } else {
                _webViewController.reload();
              }
            },
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

  Widget _buildFloatingSnifferHUD() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF1B181A).withOpacity(0.95),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: fieryAmber, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: fieryAmber.withOpacity(0.25),
            blurRadius: 16,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.8),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: fieryAmber.withOpacity(0.2),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.bolt, color: fieryAmber, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'جاهز للتحميل الصاروخي',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _sniffedDownloadTitle ?? _sniffedDownloadUrl ?? '',
                  style: const TextStyle(
                    color: Color(0xFFB5AFB2),
                    fontSize: 10,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: _startDownloadingSniffedFile,
            style: ElevatedButton.styleFrom(
              backgroundColor: fieryAmber,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              elevation: 4,
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.download, size: 16),
                SizedBox(width: 4),
                Text(
                  'تحميل',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
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

          // Sniff Active Page Button
          TextButton.icon(
            onPressed: () => _triggerDownloadCapture(_currentUrl),
            icon: const Icon(Icons.radar, color: fieryAmber, size: 16),
            label: const Text(
              'التقاط الرابط الحالي',
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
