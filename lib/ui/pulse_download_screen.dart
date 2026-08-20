import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/device_metrics.dart';
import '../models/download_task.dart';
import '../engine/turbo_download_service.dart';
import '../engine/link_analyzer.dart';
import '../engine/storage_path_resolver.dart';
import '../engine/audio_extractor_service.dart';
import '../engine/smart_url_filter.dart';
import '../engine/cloud_extractor_service.dart';
import '../engine/smart_download_catcher.dart';
import '../engine/android_system_bridge.dart';
import '../engine/download_manager_service.dart';
import '../utils/error_handler.dart';
import 'components/overlay_bubble_widget.dart';
import 'smart_stealth_browser.dart';
import 'multi_downloads_screen.dart';

/// [PulseDownloadScreen] - 1DM+ Architecture with HyperPulse Carbon & Fiery Orange Aesthetics.
class PulseDownloadScreen extends StatefulWidget {
  final TurboDownloadService? customTurboService;
  final LinkAnalyzer? customLinkAnalyzer;

  const PulseDownloadScreen({
    super.key,
    this.customTurboService,
    this.customLinkAnalyzer,
  });

  @override
  State<PulseDownloadScreen> createState() => _PulseDownloadScreenState();
}

class _PulseDownloadScreenState extends State<PulseDownloadScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // Brand Color Palette
  static const Color carbonBg = Color(0xFF0A0A0C);
  static const Color cardBg = Color(0xFF141318);
  static const Color cardSubBg = Color(0xFF0D0C10);
  static const Color fieryAmber = Color(0xFFFF4F00);
  static const Color fieryYellow = Color(0xFFFF9D00);
  static const Color borderSubtle = Color(0x33FF4F00);
  static const Color textMuted = Color(0xFFA0999C);

  // Controllers
  late final TextEditingController _urlInputController;
  late final AnimationController _pulseGlowController;

  // Low-Level Engines & Services
  late final TurboDownloadService _turboService;
  late final LinkAnalyzer _linkAnalyzer;
  late final CloudExtractorService _cloudExtractor;
  late final SmartDownloadCatcher _smartCatcher;

  // Stream Subscriptions
  StreamSubscription<TurboProgressEvent>? _progressSub;
  StreamSubscription<DetectedDownloadLink>? _catcherSub;

  // Active floating overlay link
  DetectedDownloadLink? _floatingLink;

  // Permissions & OS States
  bool _hasOverlayPermission = true;
  bool _isCheckingPermissions = false;

  // State Telemetry
  bool _isDownloading = false;
  double _progress = 0.0;
  double _currentSpeedBps = 0.0;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  int _activeThreads = 16;
  String _currentFileName = 'ubuntu-24.04-desktop-amd64.iso';
  String _statusMessage = 'في وضع الاستعداد // أدخل أو الصق رابط التحميل';
  String? _targetFilePath;
  String _resolvedStorageDir = '';
  bool _extractMp3 = false;
  bool _isVideo = false;

  // Speed Waveform Telemetry History (Last 15 sample points for smooth graph)
  final List<double> _speedHistory = List.filled(16, 0.0);
  Timer? _speedSampleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _urlInputController = TextEditingController(
      text: 'https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso',
    );

    // Glow Animation Controller
    _pulseGlowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);

    // Instantiate Engines
    _turboService = widget.customTurboService ?? TurboDownloadService();
    _linkAnalyzer = widget.customLinkAnalyzer ?? LinkAnalyzer();
    _cloudExtractor = CloudExtractorService();
    _smartCatcher = SmartDownloadCatcher();

    // Start Clipboard Listener
    _smartCatcher.startListening();
    _catcherSub = _smartCatcher.onDownloadLinkDetected.listen((detectedLink) {
      if (!mounted) return;
      setState(() {
        _floatingLink = detectedLink;
      });
      HapticFeedback.mediumImpact();
    });

    // Check system permissions and directory
    _checkSystemPermissions();
    _initStoragePath();

    // Speed sampling timer (records speed every 500ms for the waveform graph)
    _speedSampleTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (!mounted) return;
      setState(() {
        _speedHistory.removeAt(0);
        _speedHistory.add(_isDownloading ? _currentSpeedBps : 0.0);
      });
    });

    // Listen to real-time engine telemetry
    _progressSub = _turboService.onProgress.listen((event) {
      if (!mounted) return;
      setState(() {
        _progress = event.progressPercent;
        _currentSpeedBps = event.speedBytesPerSec;
        _downloadedBytes = event.downloadedBytes;
        _totalBytes = event.totalBytes;
        _activeThreads = event.isSingleStream ? 1 : (event.segments.isNotEmpty ? event.segments.length : _activeThreads);
        if (event.statusText.isNotEmpty) {
          _statusMessage = event.statusText;
        }

        if (event.progressPercent >= 1.0) {
          _handleDownloadComplete();
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkSystemPermissions();
    }
  }

  Future<void> _checkSystemPermissions() async {
    if (_isCheckingPermissions) return;
    _isCheckingPermissions = true;
    try {
      final overlay = await AndroidSystemBridge.canDrawOverlays();
      if (mounted) {
        setState(() {
          _hasOverlayPermission = overlay;
        });
      }
    } catch (e) {
      debugPrint('[PulseDownloadScreen] Permission check warning: $e');
    } finally {
      _isCheckingPermissions = false;
    }
  }

  Future<void> _initStoragePath() async {
    try {
      final path = await StoragePathResolver.resolveDownloadDirectory(isMediaVideo: _isVideo);
      if (mounted) {
        setState(() {
          _resolvedStorageDir = path;
        });
      }
    } catch (e) {
      debugPrint('[PulseDownloadScreen] Storage path init error: $e');
    }
  }

  Future<void> _handleDownloadComplete() async {
    setState(() {
      _isDownloading = false;
      _statusMessage = 'اكتمل التنزيل بنجاح // تم الحفظ وفحص الملف';
    });

    HapticFeedback.heavyImpact();

    // Trigger MediaScanner for Gallery/Photos indexation
    if (_targetFilePath != null && File(_targetFilePath!).existsSync()) {
      await AndroidSystemBridge.scanMediaFile(_targetFilePath!);
    }

    // Audio Extraction if requested
    if (_extractMp3 && _targetFilePath != null && File(_targetFilePath!).existsSync()) {
      setState(() {
        _statusMessage = 'جاري استخراج ملف الصوت MP3 عبر FFmpeg...';
      });

      try {
        final result = await AudioExtractorService.extractToMp3(
          videoFilePath: _targetFilePath!,
          deleteOriginal: false,
        );

        if (result.success && result.outputPath != null) {
          await AndroidSystemBridge.scanMediaFile(result.outputPath!);
          setState(() {
            _statusMessage = 'تم استخراج ملف MP3 وحفظه في المعرض والموسيقى';
          });
          _showCustomToast(
            title: 'تم استخراج MP3 بنجاح',
            message: 'تم حفظ الصوت: ${result.outputPath!.split("/").last}',
            isSuccess: true,
          );
        } else {
          setState(() {
            _statusMessage = 'تعذر استخراج الصوت: ${result.errorMessage}';
          });
        }
      } catch (e) {
        setState(() {
          _statusMessage = HyperPulseErrorHandler.getFriendlyMessage(e);
        });
      }
    } else {
      _showCustomToast(
        title: 'اكتمل التحميل ⚡',
        message: 'تم حفظ الملف بنجاح في: ${_targetFilePath?.split("/").last ?? ""}',
        isSuccess: true,
      );
    }

    DownloadManagerService().refreshCompletedDownloadsFromStorage();
  }

  void _openInAppBrowser([String? initialUrl]) {
    final target = (initialUrl ?? _urlInputController.text).trim();
    SmartStealthBrowser.open(
      context: context,
      initialUrl: target.startsWith('http') ? target : 'https://www.google.com',
      onDownloadCaught: (caughtUrl, title) {
        _urlInputController.text = caughtUrl;
        _initiateTurboDownload(overrideUrl: caughtUrl);
        if (title != null && title.isNotEmpty) {
          _showCustomToast(
            title: 'تم التقاط الرابط ⚡',
            message: 'بدء التحميل الفائق لـ: $title',
            isSuccess: true,
          );
        }
      },
    );
  }

  Future<void> _handlePasteFromClipboard() async {
    HapticFeedback.lightImpact();
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String? text = data?.text?.trim();

      if (text != null && text.isNotEmpty) {
        setState(() {
          _urlInputController.text = text;
        });
        _showCustomToast(
          title: 'تم اللصق بنجاح',
          message: 'تم وضع الرابط في حقل الإدخال',
          isSuccess: true,
        );
      } else {
        _showCustomToast(
          title: 'الحافظة فارغة',
          message: 'انسخ رابط التحميل أولاً من المتصفح أو أي تطبيق',
          isSuccess: false,
        );
      }
    } catch (e) {
      debugPrint('[PulseDownloadScreen] Paste error: $e');
    }
  }

  Future<void> _initiateTurboDownload({String? overrideUrl}) async {
    HapticFeedback.mediumImpact();
    final rawInput = (overrideUrl ?? _urlInputController.text).trim();
    if (rawInput.isEmpty) {
      _showCustomToast(
        title: 'تنبيه',
        message: 'يرجى إدخال أو لصق رابط التحميل أولاً',
        isSuccess: false,
      );
      return;
    }

    if (!SmartUrlFilter.isCleanAndSafe(rawInput)) {
      _showCustomToast(
        title: 'تم حظر الرابط',
        message: 'تم تصنيف الرابط كإعلان أو تتبع وهمي وتم حظره لحماية جهازك.',
        isSuccess: false,
      );
      return;
    }

    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(rawInput);
    _urlInputController.text = cleanUrl;

    var extractedFileName = cleanUrl.split('/').last.split('?').first;
    if (extractedFileName.isEmpty) extractedFileName = 'HyperPulse_Download_${DateTime.now().millisecondsSinceEpoch}';

    setState(() {
      _isDownloading = true;
      _progress = 0.01;
      _currentFileName = extractedFileName;
      _statusMessage = 'جاري فحص الرابط واستخراج تيار البيانات...';
      _speedHistory.fillRange(0, _speedHistory.length, 0.0);
    });

    try {
      final isSocial = CloudExtractorService.isSocialVideoPlatform(cleanUrl);
      String directStreamUrl = cleanUrl;
      String inferredTitle = extractedFileName;
      String inferredFormat = SmartUrlFilter.inferFileExtension(cleanUrl) ?? (isSocial ? 'mp4' : 'bin');

      if (isSocial) {
        setState(() {
          _statusMessage = 'استخراج رابط الفيديو المباشر عبر السيرفر السحابي...';
        });

        final cloudResult = await _cloudExtractor.extractDirectMedia(cleanUrl);
        if (cloudResult.success) {
          directStreamUrl = cloudResult.directStreamUrl;
          inferredTitle = cloudResult.title;
          inferredFormat = 'mp4';
        } else {
          throw Exception(cloudResult.errorMessage ?? 'فشل استخراج الفيديو السحابي');
        }
      }

      final isVideo = isSocial ||
          AudioExtractorService.isVideoFormat(inferredTitle) ||
          inferredFormat.toLowerCase().contains('mp4') ||
          inferredFormat.toLowerCase().contains('webm');

      if (isVideo) {
        inferredFormat = 'mp4';
        inferredTitle = inferredTitle.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
        if (inferredTitle.isEmpty) {
          inferredTitle = 'HyperPulse_Video_${DateTime.now().millisecondsSinceEpoch}.mp4';
        }
        if (!inferredTitle.toLowerCase().endsWith('.mp4')) {
          inferredTitle = '$inferredTitle.mp4';
        }
      }

      _resolvedStorageDir = await StoragePathResolver.resolveDownloadDirectory(isMediaVideo: isVideo);
      final finalFilePath = '$_resolvedStorageDir/$inferredTitle';

      setState(() {
        _isVideo = isVideo;
        _currentFileName = inferredTitle;
        _targetFilePath = finalFilePath;
        _statusMessage = isSocial
            ? 'تنزيل مباشر عالي السرعة (Movies/HyperPulse)'
            : 'تهيئة الأنوية المتوازية ($_activeThreads خيوط)';
      });

      final deviceProfile = DeviceMetrics(
        totalRamMb: 8192,
        availableRamMb: 4096,
        logicalCores: 8,
        currentNetworkSpeedMbps: 180.0,
        latencyMs: 22,
      );

      final task = DownloadTask(
        id: 'pulse_${DateTime.now().millisecondsSinceEpoch}',
        sourceUrl: directStreamUrl,
        fileName: inferredTitle,
        destinationDirectory: _resolvedStorageDir,
      );

      await _turboService.startDownload(
        task: task,
        deviceMetrics: deviceProfile,
        ramBufferThresholdMb: 64,
        forceSingleStream: isSocial,
      );
    } catch (e) {
      final friendlyError = HyperPulseErrorHandler.getFriendlyMessage(e);
      setState(() {
        _isDownloading = false;
        _statusMessage = friendlyError;
      });

      _showErrorWithBrowserOption(friendlyError, cleanUrl);
    }
  }

  void _showErrorWithBrowserOption(String message, String targetUrl) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF1B1618),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: fieryAmber, width: 1.2),
        ),
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: fieryAmber, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'تعذر الاستخراج المباشر',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    message,
                    style: const TextStyle(color: Color(0xFFC7BFC2), fontSize: 11),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        action: SnackBarAction(
          label: 'فتح بالمتصفح 🌐',
          textColor: fieryAmber,
          onPressed: () => _openInAppBrowser(targetUrl),
        ),
        duration: const Duration(seconds: 8),
      ),
    );
  }

  void _showCustomToast({required String title, required String message, required bool isSuccess}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF18161A),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isSuccess ? fieryAmber : const Color(0xFFE53E3E),
            width: 1,
          ),
        ),
        content: Row(
          children: [
            Icon(
              isSuccess ? Icons.check_circle : Icons.error_outline,
              color: isSuccess ? fieryAmber : const Color(0xFFE53E3E),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    message,
                    style: const TextStyle(
                      color: Color(0xFFB5AFB2),
                      fontSize: 11,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String get _formattedSpeed {
    if (_currentSpeedBps <= 0) return '0.0 MB/s';
    if (_currentSpeedBps < 1024) {
      return '${_currentSpeedBps.toStringAsFixed(0)} B/s';
    } else if (_currentSpeedBps < 1024 * 1024) {
      return '${(_currentSpeedBps / 1024).toStringAsFixed(1)} KB/s';
    } else {
      return '${(_currentSpeedBps / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    }
  }

  String get _formattedDownloadedSize {
    if (_totalBytes <= 0) {
      final mb = (_downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
      return '$mb MB / غير محدد';
    }
    final dlMb = (_downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totMb = (_totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return '$dlMb MB / $totMb MB';
  }

  String get _formattedEta {
    if (!_isDownloading || _currentSpeedBps <= 1024 || _totalBytes <= 0) {
      return '--:--';
    }
    final remainingBytes = _totalBytes - _downloadedBytes;
    if (remainingBytes <= 0) return '00:00';
    final seconds = (remainingBytes / _currentSpeedBps).round();
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progressSub?.cancel();
    _catcherSub?.cancel();
    _speedSampleTimer?.cancel();
    _pulseGlowController.dispose();
    _urlInputController.dispose();
    _smartCatcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: carbonBg,
      body: Stack(
        children: [
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. TOP SECTION: 1DM-Style Header Bar
                  _buildHeaderBar(),

                  // Optional Overlay Permission Banner if needed
                  if (!_hasOverlayPermission)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: _buildOverlayPermissionBanner(),
                    ),

                  const SizedBox(height: 12),

                  // 2. MIDDLE SECTION: Massive 1DM-Style Download Card with Live Waveform Graph
                  Expanded(
                    child: _buildMassiveDownloadCard(),
                  ),

                  const SizedBox(height: 12),

                  // 3. BOTTOM SECTION: Clean Input & Control Area
                  _buildInputAndControlArea(),
                ],
              ),
            ),
          ),

          // Floating Smart Overlay Bubble when clipboard detects a link
          if (_floatingLink != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: OverlayBubbleWidget(
                link: _floatingLink!,
                onDownloadPressed: (detectedLink) {
                  _urlInputController.text = detectedLink.cleanUrl;
                  _initiateTurboDownload(overrideUrl: detectedLink.cleanUrl);
                  setState(() => _floatingLink = null);
                },
                onDismiss: () {
                  setState(() => _floatingLink = null);
                },
              ),
            ),
        ],
      ),
    );
  }

  // ==========================================
  // 1. TOP HEADER SECTION
  // ==========================================
  Widget _buildHeaderBar() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        // App Identity Brand
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [fieryAmber, fieryYellow],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(10),
                boxShadow: [
                  BoxShadow(
                    color: fieryAmber.withOpacity(0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: const Icon(
                Icons.bolt,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'HYPERPULSE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.0,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: _isDownloading ? fieryAmber : const Color(0xFF4ADE80),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _isDownloading ? 'محرك التنزيل نشط ⚡' : 'رادار الالتقاط نشط',
                      style: TextStyle(
                        color: _isDownloading ? fieryAmber : const Color(0xFF4ADE80),
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),

        // Quick Top Action Buttons (Browser & Files)
        Row(
          children: [
            // Browser Button (Dark Grey Pill)
            _buildTopActionButton(
              icon: Icons.language,
              label: 'المتصفح',
              onTap: () => _openInAppBrowser(),
            ),
            const SizedBox(width: 8),

            // Downloads / Files Button (Dark Grey Pill)
            _buildTopActionButton(
              icon: Icons.folder,
              label: 'الملفات',
              onTap: () => MultiDownloadsScreen.open(context),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTopActionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: const Color(0xFF1C1A20),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2C2833)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: const Color(0xFFD4C8C5)),
            const SizedBox(width: 5),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ==========================================
  // 2. MIDDLE MASSIVE DOWNLOAD CARD (1DM STYLE)
  // ==========================================
  Widget _buildMassiveDownloadCard() {
    final percentInt = (_progress * 100).toInt().clamp(0, 100);

    return Container(
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: borderSubtle, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.6),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
          if (_isDownloading)
            BoxShadow(
              color: fieryAmber.withOpacity(0.08),
              blurRadius: 24,
              spreadRadius: 2,
            ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(
          children: [
            // Background Real-Time Speed Waveform Graph
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: 140,
              child: CustomPaint(
                painter: _SpeedWaveformPainter(
                  speedHistory: _speedHistory,
                  isDownloading: _isDownloading,
                  primaryColor: fieryAmber,
                  accentColor: fieryYellow,
                ),
              ),
            ),

            // Card Foreground Content
            Padding(
              padding: const EdgeInsets.all(18.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. File Name Header & File Format Tag
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // File Icon with Glowing Backdrop
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: const Color(0xFF221F28),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: fieryAmber.withOpacity(0.4)),
                        ),
                        child: Icon(
                          _getFileTypeIcon(_currentFileName),
                          color: fieryAmber,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),

                      // File Title and Subtext
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _currentFileName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14.5,
                                fontWeight: FontWeight.bold,
                                height: 1.25,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              _statusMessage,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Thread / Status Badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E1A22),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: fieryAmber.withOpacity(0.3)),
                        ),
                        child: Text(
                          _isDownloading ? '$_activeThreads خيوط' : 'جاهز',
                          style: const TextStyle(
                            color: fieryAmber,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),

                  const Spacer(),

                  // 2. Big Percentage & Main Telemetry Numbers
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Speed Metric Display
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'سرعة التنزيل',
                            style: TextStyle(
                              color: textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _formattedSpeed,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ],
                      ),

                      // Percentage Display
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            '$percentInt',
                            style: const TextStyle(
                              color: fieryAmber,
                              fontSize: 38,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const Text(
                            '%',
                            style: TextStyle(
                              color: fieryYellow,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // 3. Wide Horizontal Glowing Progress Bar
                  Stack(
                    children: [
                      // Track
                      Container(
                        height: 14,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0C0B0E),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF28252E)),
                        ),
                      ),
                      // Active Progress Fill
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final barWidth = constraints.maxWidth * _progress.clamp(0.0, 1.0);
                          return Container(
                            width: math.max(barWidth, _isDownloading ? 8.0 : 0.0),
                            height: 14,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [fieryAmber, fieryYellow],
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                              ),
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: [
                                BoxShadow(
                                  color: fieryAmber.withOpacity(0.6),
                                  blurRadius: 10,
                                  offset: const Offset(0, 1),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 12),

                  // 4. Download Details Telemetry Row (Size, Remaining, ETA)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: cardSubBg.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF201D24)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildCardSubMetric(
                          label: 'الحجم المكتمل',
                          value: _formattedDownloadedSize,
                          icon: Icons.data_usage,
                        ),
                        Container(width: 1, height: 20, color: const Color(0xFF2B2733)),
                        _buildCardSubMetric(
                          label: 'الوقت المتبقي',
                          value: _formattedEta,
                          icon: Icons.timer,
                        ),
                        Container(width: 1, height: 20, color: const Color(0xFF2B2733)),
                        _buildCardSubMetric(
                          label: 'الحالة',
                          value: _isDownloading ? 'نشط ⚡' : 'متوقف',
                          icon: Icons.bolt,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCardSubMetric({
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: fieryAmber),
        const SizedBox(width: 5),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: const TextStyle(
                color: textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ],
    );
  }

  IconData _getFileTypeIcon(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.apk') || lower.endsWith('.xapk')) return Icons.android;
    if (lower.endsWith('.mp4') || lower.endsWith('.mkv') || lower.endsWith('.webm') || lower.endsWith('.avi')) {
      return Icons.movie;
    }
    if (lower.endsWith('.mp3') || lower.endsWith('.m4a') || lower.endsWith('.wav') || lower.endsWith('.flac')) {
      return Icons.music_note;
    }
    if (lower.endsWith('.zip') || lower.endsWith('.rar') || lower.endsWith('.7z') || lower.endsWith('.iso')) {
      return Icons.folder_zip;
    }
    if (lower.endsWith('.pdf') || lower.endsWith('.doc') || lower.endsWith('.docx')) {
      return Icons.description;
    }
    return Icons.download_for_offline;
  }

  // ==========================================
  // 3. BOTTOM INPUT & CONTROL AREA
  // ==========================================
  Widget _buildInputAndControlArea() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderSubtle, width: 1.0),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row 1: Label & Paste Button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'رابط التحميل المباشر',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),

              // Paste Button (Translucent Orange Pill)
              GestureDetector(
                onTap: _isDownloading ? null : _handlePasteFromClipboard,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: fieryAmber.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: fieryAmber.withOpacity(0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.content_paste, size: 13, color: fieryAmber),
                      SizedBox(width: 4),
                      Text(
                        'لصق الرابط',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Row 2: Input Field Container
          Container(
            decoration: BoxDecoration(
              color: cardSubBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFF2C2833)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: Row(
              children: [
                const Icon(Icons.link, size: 18, color: textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _urlInputController,
                    enabled: !_isDownloading,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                    ),
                    cursorColor: fieryAmber,
                    decoration: const InputDecoration(
                      hintText: 'ضع رابط الفيديو أو الملف هنا (YouTube, APK, MP4...)',
                      hintStyle: TextStyle(
                        color: textMuted,
                        fontSize: 11.5,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
                if (_urlInputController.text.isNotEmpty && !_isDownloading)
                  GestureDetector(
                    onTap: () => setState(() => _urlInputController.clear()),
                    child: const Icon(Icons.clear, size: 16, color: textMuted),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Row 3: Options (MP3 Audio Toggle & Storage Directory Path)
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Audio MP3 Toggle Pill
              GestureDetector(
                onTap: _isDownloading
                    ? null
                    : () => setState(() => _extractMp3 = !_extractMp3),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _extractMp3 ? fieryAmber.withOpacity(0.2) : const Color(0xFF1A1820),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _extractMp3 ? fieryAmber : const Color(0xFF2E2A36),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.music_note,
                        size: 13,
                        color: _extractMp3 ? fieryAmber : textMuted,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'استخراج صوت MP3',
                        style: TextStyle(
                          color: _extractMp3 ? Colors.white : textMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Storage Path Display
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.folder_open, size: 13, color: textMuted),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _resolvedStorageDir.isNotEmpty
                            ? _resolvedStorageDir.split('/').sublist(math.max(0, _resolvedStorageDir.split('/').length - 2)).join('/')
                            : 'Movies/HyperPulse',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: textMuted,
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Row 4: Big Glowing Rectangular "ابدأ التحميل" Action Button
          GestureDetector(
            onTap: _isDownloading ? null : () => _initiateTurboDownload(),
            child: Container(
              height: 48,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _isDownloading
                      ? [const Color(0xFF2A2220), const Color(0xFF1A1616)]
                      : [fieryAmber, const Color(0xFFE03C00)],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  if (!_isDownloading)
                    BoxShadow(
                      color: fieryAmber.withOpacity(0.4),
                      blurRadius: 14,
                      offset: const Offset(0, 4),
                    ),
                ],
              ),
              child: Center(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (_isDownloading)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: fieryAmber,
                        ),
                      )
                    else
                      const Icon(
                        Icons.bolt,
                        color: Colors.white,
                        size: 20,
                      ),
                    const SizedBox(width: 8),
                    Text(
                      _isDownloading
                          ? 'جاري التنزيل المتوازي الفائق...'
                          : _extractMp3
                              ? 'ابدأ التنزيل واستخراج MP3 ⚡'
                              : 'ابدأ التحميل المتسارع ⚡',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverlayPermissionBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF251610),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: fieryAmber.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: fieryAmber, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'لتفعيل ميزة التقاط الروابط التلقائية، يرجى منح إذن "الظهور فوق التطبيقات"',
              style: TextStyle(color: Color(0xFFFFD4C2), fontSize: 10.5, fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              await AndroidSystemBridge.openOverlaySettings();
              await _checkSystemPermissions();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: fieryAmber,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(50, 28),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
            child: const Text('تفعيل', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}

/// [ _SpeedWaveformPainter ] Renders the real-time speed waveform graph inside the download card.
class _SpeedWaveformPainter extends CustomPainter {
  final List<double> speedHistory;
  final bool isDownloading;
  final Color primaryColor;
  final Color accentColor;

  _SpeedWaveformPainter({
    required this.speedHistory,
    required this.isDownloading,
    required this.primaryColor,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (speedHistory.isEmpty) return;

    final maxSpeed = speedHistory.reduce((a, b) => math.max(a, b));
    final effectiveMax = maxSpeed <= 0 ? 1024 * 1024.0 : maxSpeed; // Default baseline 1MB/s

    final path = Path();
    final fillPath = Path();

    final stepX = size.width / (speedHistory.length - 1);
    final points = <Offset>[];

    for (int i = 0; i < speedHistory.length; i++) {
      final speed = speedHistory[i];
      final normalizedY = (speed / effectiveMax).clamp(0.05, 0.95);
      final x = i * stepX;
      // Invert Y so highest speed is near top of graph area
      final y = size.height - (normalizedY * (size.height - 20)) - 10;
      points.add(Offset(x, y));
    }

    if (points.isEmpty) return;

    path.moveTo(points.first.dx, points.first.dy);
    fillPath.moveTo(points.first.dx, size.height);
    fillPath.lineTo(points.first.dx, points.first.dy);

    // Build smooth cubic bezier curve through points
    for (int i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final midX = (p0.dx + p1.dx) / 2;
      path.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
      fillPath.cubicTo(midX, p0.dy, midX, p1.dy, p1.dx, p1.dy);
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    // 1. Draw glowing gradient under the waveform
    final gradient = LinearGradient(
      colors: [
        primaryColor.withOpacity(isDownloading ? 0.25 : 0.05),
        primaryColor.withOpacity(0.0),
      ],
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
    );

    final fillPaint = Paint()
      ..shader = gradient.createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // 2. Draw the luminous waveform stroke line
    final strokePaint = Paint()
      ..color = primaryColor.withOpacity(isDownloading ? 0.75 : 0.25)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(path, strokePaint);

    // 3. Draw active pulsing dot at the latest point
    if (isDownloading && points.isNotEmpty) {
      final latestPoint = points.last;
      final glowPaint = Paint()
        ..color = accentColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(latestPoint, 5, glowPaint);

      final dotPaint = Paint()..color = Colors.white;
      canvas.drawCircle(latestPoint, 2.5, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpeedWaveformPainter oldDelegate) {
    return true;
  }
}
