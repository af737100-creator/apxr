import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
import '../utils/error_handler.dart';
import 'painters/fiery_pulse_ring_painter.dart';
import 'painters/cockpit_grid_painter.dart';
import 'components/glass_cockpit_input.dart';
import 'components/stealth_particle_system.dart';
import 'components/overlay_bubble_widget.dart';
import 'smart_stealth_browser.dart';
import 'downloads_center_sheet.dart';
import '../engine/download_manager_service.dart';

/// [PulseDownloadScreen] is the master high-tech Stealth Jet Cockpit UI for HyperPulse.
///
/// Upgraded Features:
/// 1. Auto-enforcing `.mp4` extension for YouTube, TikTok, and social media videos.
/// 2. Saving videos into `Movies/HyperPulse` so they appear instantly in Gallery/Photos.
/// 3. MediaScannerConnection integration to notify Android MediaStore upon completion.
/// 4. SYSTEM_ALERT_WINDOW ("Draw Over Other Apps") permission radar & direct settings button.
/// 5. POST_NOTIFICATIONS status verification for background radar persistence.
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
  static const Color deepCarbon = Color(0xFF0A0A0C);
  static const Color fieryAmber = Color(0xFFFF4F00);

  // Controllers
  late final TextEditingController _urlInputController;
  late final AnimationController _pulseController;
  late final AnimationController _sparkRotationController;
  late final StealthParticleController _particleController;
  late final Ticker _particleTicker;

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
  bool _hasNotificationPermission = true;
  bool _isCheckingPermissions = false;

  // State Telemetry
  bool _isDownloading = false;
  double _progress = 0.0;
  double _currentSpeedBps = 0.0;
  int _downloadedBytes = 0;
  int _totalBytes = 0;
  int _activeThreads = 16;
  double _bufferedRamMb = 0.0;
  String _statusMessage = 'جاهز لبدء التحميل // أدخل الرابط أو انسخه';
  String? _targetFilePath;
  String _resolvedStorageDir = '';
  bool _extractMp3 = false;
  bool _isVideo = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _urlInputController = TextEditingController(
      text: 'https://releases.ubuntu.com/24.04/ubuntu-24.04-desktop-amd64.iso',
    );

    // 1. Initialize Cockpit Animations
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _sparkRotationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    // 2. Initialize Kinetic Particle Physics
    _particleController = StealthParticleController();
    _particleTicker = createTicker((elapsed) {
      _particleController.tick(0.016);
      if (_isDownloading && _currentSpeedBps > 0) {
        final mediaSize = MediaQuery.of(context).size;
        _particleController.spawnAmbientEmbers(
          Offset(mediaSize.width / 2, mediaSize.height * 0.42),
          count: 1,
        );
      }
    })..start();

    // 3. Instantiate Engines
    _turboService = widget.customTurboService ?? TurboDownloadService();
    _linkAnalyzer = widget.customLinkAnalyzer ?? LinkAnalyzer();
    _cloudExtractor = CloudExtractorService();
    _smartCatcher = SmartDownloadCatcher();

    // 4. AUTOMATIC SMART CLIPBOARD CATCHER ACTIVATION ON BOOT
    _smartCatcher.startListening();
    _catcherSub = _smartCatcher.onDownloadLinkDetected.listen((detectedLink) {
      if (!mounted) return;
      setState(() {
        _floatingLink = detectedLink;
      });
      HapticFeedback.mediumImpact();
    });

    // 5. Check permissions and storage
    _checkSystemPermissions();
    _initStoragePath();

    // 6. Listen to real-time engine telemetry
    _progressSub = _turboService.onProgress.listen((event) {
      if (!mounted) return;
      setState(() {
        _progress = event.progressPercent;
        _currentSpeedBps = event.speedBytesPerSec;
        _downloadedBytes = event.downloadedBytes;
        _totalBytes = event.totalBytes;
        _bufferedRamMb = event.bufferedRamMb;
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
      final notifs = await AndroidSystemBridge.areNotificationsEnabled();
      if (mounted) {
        setState(() {
          _hasOverlayPermission = overlay;
          _hasNotificationPermission = notifs;
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
      _statusMessage = 'اكتمل التحميل بنجاح // تم حفظ الملف في المعرض';
    });

    final mediaSize = MediaQuery.of(context).size;
    _particleController.spawnBurst(
      Offset(mediaSize.width / 2, mediaSize.height * 0.42),
      count: 90,
    );

    // 1. Trigger MediaScanner to index video/audio immediately in Android Gallery
    if (_targetFilePath != null && File(_targetFilePath!).existsSync()) {
      await AndroidSystemBridge.scanMediaFile(_targetFilePath!);
    }

    // 2. Audio Extraction if requested
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
            title: 'تم استخراج MP3',
            message: 'تم حفظ وتحديث ملف الصوت في المعرض: ${result.outputPath!.split("/").last}',
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
        title: 'اكتمل التحميل // جاهز في المعرض',
        message: 'تم حفظ وتحديث الملف: ${_targetFilePath?.split("/").last ?? ""}',
        isSuccess: true,
      );
    }

    // Refresh downloads manager library
    DownloadManagerService().refreshCompletedDownloadsFromStorage();
  }

  /// Opens the integrated stealth mini-browser with link sniffer
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
            title: 'تم التقاط الرابط من المتصفح ⚡',
            message: 'بدء التحميل الفائق لـ: $title',
            isSuccess: true,
          );
        }
      },
    );
  }

  /// Primary launch handler for parallel turbo download with cloud extraction and smart filtering
  Future<void> _initiateTurboDownload({String? overrideUrl}) async {
    final rawInput = (overrideUrl ?? _urlInputController.text).trim();
    if (rawInput.isEmpty) {
      _showCustomToast(
        title: 'تنبيه',
        message: 'يرجى إدخال أو لصق رابط التحميل أولاً',
        isSuccess: false,
      );
      return;
    }

    // 1. Anti-Ad & Scam Shield Filter
    if (!SmartUrlFilter.isCleanAndSafe(rawInput)) {
      _showCustomToast(
        title: 'تم حظر الرابط',
        message: 'هذا الرابط تم تصنيفه كرابط إعلاني أو تتبع وهمي وتم حظره تلقائياً لحماية جهازك.',
        isSuccess: false,
      );
      return;
    }

    final cleanUrl = SmartUrlFilter.extractRealTargetUrl(rawInput);
    _urlInputController.text = cleanUrl;

    setState(() {
      _isDownloading = true;
      _progress = 0.01;
      _statusMessage = 'جاري فحص الرابط واستخراج الوسائط...';
    });

    try {
      final isSocial = CloudExtractorService.isSocialVideoPlatform(cleanUrl);
      String directStreamUrl = cleanUrl;
      String inferredTitle = cleanUrl.split('/').last.split('?').first;
      String inferredFormat = SmartUrlFilter.inferFileExtension(cleanUrl) ?? (isSocial ? 'mp4' : 'bin');

      // 2. If it's a social platform (YouTube, TikTok, etc.), query CloudExtractorService
      if (isSocial) {
        setState(() {
          _statusMessage = 'استخراج رابط الفيديو المباشر من السيرفر السحابي...';
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

      // 3. Guarantee filename ends with .mp4 for video and sanitize illegal characters
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

      // 4. Resolve default save directory to Movies/HyperPulse for videos
      _resolvedStorageDir = await StoragePathResolver.resolveDownloadDirectory(isMediaVideo: isVideo);
      final finalFilePath = '$_resolvedStorageDir/$inferredTitle';

      setState(() {
        _isVideo = isVideo;
        _targetFilePath = finalFilePath;
        _statusMessage = isSocial
            ? 'بدء تيار التحميل المباشر (Movies/HyperPulse)'
            : 'تهيئة الأنوية المتوازية (${inferredFormat.toUpperCase()})';
      });

      // 5. Hardware profile
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

      // 6. Launch download engine
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
          side: const BorderSide(color: Color(0xFFFF4F00), width: 1.2),
        ),
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFFF4F00), size: 20),
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
                    style: const TextStyle(color: Color(0xFFC7BFC2), fontSize: 10),
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
          textColor: const Color(0xFFFF4F00),
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
        backgroundColor: const Color(0xFF161418),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: isSuccess ? const Color(0xFFFF4F00) : const Color(0xFFE53E3E),
            width: 1,
          ),
        ),
        content: Row(
          children: [
            Icon(
              isSuccess ? Icons.check_circle : Icons.error_outline,
              color: isSuccess ? const Color(0xFFFF4F00) : const Color(0xFFE53E3E),
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
      return '$mb MB / STREAM';
    }
    final dlMb = (_downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totMb = (_totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return '$dlMb MB / $totMb MB';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _progressSub?.cancel();
    _catcherSub?.cancel();
    _pulseController.dispose();
    _sparkRotationController.dispose();
    _particleTicker.dispose();
    _particleController.dispose();
    _urlInputController.dispose();
    _smartCatcher.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mediaSize = MediaQuery.of(context).size;
    final ringDimension = mediaSize.width * 0.68;

    return Scaffold(
      backgroundColor: deepCarbon,
      body: Stack(
        children: [
          // 1. Background Cockpit Grid HUD
          Positioned.fill(
            child: CustomPaint(
              painter: CockpitGridPainter(),
            ),
          ),

          // 2. Kinetic Particles System
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _particleController,
              builder: (context, _) {
                return CustomPaint(
                  painter: StealthParticlePainter(
                    particles: _particleController.particles,
                  ),
                );
              },
            ),
          ),

          // 3. Main Cockpit HUD Stage
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Column(
                children: [
                  _buildCockpitHeader(),

                  // OVERLAY PERMISSION WARNING BANNER
                  if (!_hasOverlayPermission)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: _buildOverlayPermissionBanner(),
                    ),

                  const Spacer(),

                  // CENTER: Fiery Speed Ring
                  Center(
                    child: SizedBox(
                      width: ringDimension,
                      height: ringDimension,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          AnimatedBuilder(
                            animation: Listenable.merge([
                              _pulseController,
                              _sparkRotationController,
                            ]),
                            builder: (context, _) {
                              return CustomPaint(
                                size: Size(ringDimension, ringDimension),
                                painter: FieryPulseRingPainter(
                                  progress: _progress,
                                  pulsePhase: _pulseController.value,
                                  sparkAngle: _sparkRotationController.value * 2 * 3.1415926535,
                                  isDownloading: _isDownloading,
                                  segmentCount: _activeThreads,
                                ),
                              );
                            },
                          ),
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${(_progress * 100).toStringAsFixed(0)}%',
                                style: TextStyle(
                                  color: fieryAmber.withOpacity(0.9),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  fontFamily: 'monospace',
                                  letterSpacing: 2.0,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _formattedSpeed,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 34,
                                  fontWeight: FontWeight.w200,
                                  letterSpacing: -0.5,
                                  fontFamily: 'monospace',
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _isDownloading ? _formattedDownloadedSize : 'STANDBY',
                                style: const TextStyle(
                                  color: Color(0xFF8E888A),
                                  fontSize: 11,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 14),
                  _buildCockpitTelemetryBar(),
                  const Spacer(),

                  // BOTTOM: Enhanced Glass Cockpit Input
                  GlassCockpitInput(
                    controller: _urlInputController,
                    onStartDownload: () => _initiateTurboDownload(),
                    isDownloading: _isDownloading,
                    extractMp3Enabled: _extractMp3,
                    onExtractMp3Changed: (val) => setState(() => _extractMp3 = val),
                    isVideoDetected: _isVideo,
                    onOpenBrowser: () => _openInAppBrowser(),
                    onOpenDownloads: () => DownloadsCenterSheet.show(context),
                    currentStoragePath: _resolvedStorageDir.isNotEmpty
                        ? (() {
                            final parts = _resolvedStorageDir.split('/');
                            return parts.length > 2
                                ? parts.sublist(parts.length - 2).join('/')
                                : _resolvedStorageDir;
                          })()
                        : 'Movies/HyperPulse',
                  ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.1, end: 0),

                  const SizedBox(height: 6),
                ],
              ),
            ),
          ),

          // 4. Smart Overlay Bubble (Automatic Linkage)
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

  Widget _buildOverlayPermissionBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF251610),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFFF4F00).withOpacity(0.5)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            color: Color(0xFFFF4F00),
            size: 22,
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'لكي يعمل التقاط الروابط، يرجى الذهاب للإعدادات وتفعيل "الظهور فوق التطبيقات"',
              style: TextStyle(
                color: Color(0xFFFFD4C2),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: () async {
              await AndroidSystemBridge.openOverlaySettings();
              await _checkSystemPermissions();
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: fieryAmber,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              minimumSize: const Size(60, 32),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              elevation: 0,
            ),
            child: const Text(
              'تفعيل',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCockpitHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            GestureDetector(
              onTap: () => _openInAppBrowser(),
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: fieryAmber.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: fieryAmber.withOpacity(0.4)),
                ),
                child: const Icon(
                  Icons.language,
                  color: fieryAmber,
                  size: 18,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'HYPERPULSE // TURBO CORE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                    fontFamily: 'monospace',
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    _statusMessage,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF8A8486),
                      fontSize: 9,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        Row(
          children: [
            // Downloads Center & Installed APKs Button
            GestureDetector(
              onTap: () => DownloadsCenterSheet.show(context),
              child: Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1A22),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: fieryAmber.withOpacity(0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.folder_special, color: fieryAmber, size: 12),
                    SizedBox(width: 4),
                    Text(
                      'التنزيلات',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Mini Browser Launcher in Header
            GestureDetector(
              onTap: () => _openInAppBrowser(),
              child: Container(
                margin: const EdgeInsets.only(left: 6),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1A22),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: const Color(0xFFFF9D00).withOpacity(0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: const [
                    Icon(Icons.public, color: Color(0xFFFF9D00), size: 12),
                    SizedBox(width: 4),
                    Text(
                      'المتصفح',
                      style: TextStyle(
                        color: Color(0xFFFFD4A8),
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: _isDownloading
                    ? fieryAmber.withOpacity(0.15)
                    : const Color(0xFF161416),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: _isDownloading ? fieryAmber : const Color(0xFF332F31),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: _isDownloading ? fieryAmber : const Color(0xFF5E575A),
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _isDownloading ? 'PARALLEL ACTIVE' : 'RADAR ACTIVE',
                    style: TextStyle(
                      color: _isDownloading ? fieryAmber : const Color(0xFF4ADE80),
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCockpitTelemetryBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF100F13).withOpacity(0.7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF262224)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildTelemetryItem(
            label: 'ISOLATES',
            value: _isVideo ? '1 STREAM' : '$_activeThreads THREADS',
            accent: fieryAmber,
          ),
          Container(width: 1, height: 24, color: const Color(0xFF282426)),
          _buildTelemetryItem(
            label: 'LOCATION',
            value: _isVideo ? 'MOVIES' : 'DOWNLOADS',
            accent: const Color(0xFFFF9D00),
          ),
          Container(width: 1, height: 24, color: const Color(0xFF282426)),
          _buildTelemetryItem(
            label: 'GALLERY SCAN',
            value: 'AUTO ON',
            accent: const Color(0xFF4ADE80),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryItem({
    required String label,
    required String value,
    required Color accent,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF6B6568),
            fontSize: 9,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            color: accent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }
}
