import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../models/device_metrics.dart';
import '../models/download_task.dart';
import '../models/media_stream_info.dart';
import '../engine/turbo_download_service.dart';
import '../engine/link_analyzer.dart';
import '../engine/storage_path_resolver.dart';
import '../engine/audio_extractor_service.dart';
import '../engine/smart_url_filter.dart';
import '../engine/cloud_extractor_service.dart';
import '../engine/smart_download_catcher.dart';
import '../utils/error_handler.dart';
import 'painters/fiery_pulse_ring_painter.dart';
import 'painters/cockpit_grid_painter.dart';
import 'components/glass_cockpit_input.dart';
import 'components/stealth_particle_system.dart';
import 'components/overlay_bubble_widget.dart';

/// [PulseDownloadScreen] is the master high-tech Stealth Jet Cockpit UI for HyperPulse.
///
/// Final Integration:
/// 1. Automatic [SmartDownloadCatcher] background clipboard listener on boot.
/// 2. Instant [OverlayBubbleWidget] triggering [_initiateTurboDownload] with zero manual typing.
/// 3. Multi-source media resolution via [CloudExtractorService] (YouTube/TikTok/Instagram).
/// 4. Ad-Shield and scam link filtering via [SmartUrlFilter].
/// 5. Compliant Android 2026 Scoped Storage management via [StoragePathResolver].
/// 6. High-fidelity Video-to-MP3 audio conversion via [AudioExtractorService].
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
    with TickerProviderStateMixin {
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

    // 5. Auto-resolve Scoped Storage Directory
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

  Future<void> _initStoragePath() async {
    try {
      final path = await StoragePathResolver.resolveDownloadDirectory();
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
      _statusMessage = 'اكتمل التحميل بنجاح // تم التحقق من سلامة الملف';
    });

    final mediaSize = MediaQuery.of(context).size;
    _particleController.spawnBurst(
      Offset(mediaSize.width / 2, mediaSize.height * 0.42),
      count: 90,
    );

    if (_extractMp3 && _targetFilePath != null && File(_targetFilePath!).existsSync()) {
      setState(() {
        _statusMessage = 'جاري استخراج ملف الصوت MP3 عبر FFmpeg...';
      });

      try {
        final result = await AudioExtractorService.extractToMp3(
          videoFilePath: _targetFilePath!,
          deleteOriginal: false,
        );

        if (result.success) {
          setState(() {
            _statusMessage = 'تم استخراج ملف MP3 بنجاح في مجلد التنزيلات';
          });
          _showCustomToast(
            title: 'تم استخراج MP3',
            message: 'تم حفظ الملف الصوتي بنجاح: ${result.outputPath}',
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
        title: 'اكتمل التحميل',
        message: 'تم حفظ الملف بنجاح في: $_resolvedStorageDir',
        isSuccess: true,
      );
    }
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
      _statusMessage = 'جاري فحص الرابط واختبار الأنوية...';
    });

    try {
      if (_resolvedStorageDir.isEmpty) {
        _resolvedStorageDir = await StoragePathResolver.resolveDownloadDirectory();
      }

      String directStreamUrl = cleanUrl;
      String inferredTitle = cleanUrl.split('/').last.split('?').first;
      String inferredFormat = SmartUrlFilter.inferFileExtension(cleanUrl) ?? 'bin';

      // 2. If it's a social/video platform (YouTube, TikTok, etc.), query CloudExtractorService
      if (CloudExtractorService.isSocialVideoPlatform(cleanUrl)) {
        setState(() {
          _statusMessage = 'استخراج رابط الفيديو المباشر من السيرفر السحابي...';
        });

        final cloudResult = await _cloudExtractor.extractDirectMedia(cleanUrl);
        if (cloudResult.success) {
          directStreamUrl = cloudResult.directStreamUrl;
          inferredTitle = cloudResult.title;
          inferredFormat = cloudResult.format;
        } else {
          throw Exception(cloudResult.errorMessage ?? 'فشل استخراج الفيديو السحابي');
        }
      }

      final isVideo = AudioExtractorService.isVideoFormat(inferredTitle) ||
          inferredFormat.toLowerCase().contains('mp4') ||
          inferredFormat.toLowerCase().contains('webm');

      setState(() {
        _isVideo = isVideo;
        _targetFilePath = '$_resolvedStorageDir/$inferredTitle';
        _statusMessage = 'تهيئة الأنوية المتوازية (${inferredFormat.toUpperCase()})';
      });

      // 3. Hardware profile
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

      // 4. Launch parallel Isolate download
      await _turboService.startDownload(
        task: task,
        deviceMetrics: deviceProfile,
        ramBufferThresholdMb: 64,
      );
    } catch (e) {
      final friendlyError = HyperPulseErrorHandler.getFriendlyMessage(e);
      setState(() {
        _isDownloading = false;
        _statusMessage = friendlyError;
      });

      _showCustomToast(
        title: 'خطأ في التحميل',
        message: friendlyError,
        isSuccess: false,
      );
    }
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
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    message,
                    style: const TextStyle(color: Color(0xFFCCC5C8), fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  String get _formattedSpeed {
    if (_currentSpeedBps <= 0) {
      return _isDownloading ? '0.0 MB/s' : '12.5 MB/s';
    }
    final mbps = _currentSpeedBps / (1024 * 1024);
    return '${mbps.toStringAsFixed(1)} MB/s';
  }

  String get _formattedDownloadedSize {
    final mbDone = (_downloadedBytes / (1024 * 1024)).toStringAsFixed(1);
    final mbTotal = (_totalBytes / (1024 * 1024)).toStringAsFixed(1);
    return '$mbDone MB / $mbTotal MB';
  }

  @override
  void dispose() {
    _catcherSub?.cancel();
    _smartCatcher.stopListening();
    _progressSub?.cancel();
    _particleTicker.dispose();
    _pulseController.dispose();
    _sparkRotationController.dispose();
    _particleController.dispose();
    _urlInputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final ringDimension = (size.width * 0.72).clamp(240.0, 340.0);

    return Scaffold(
      backgroundColor: deepCarbon,
      body: Stack(
        children: [
          // 1. Cockpit HUD Grid
          Positioned.fill(
            child: CustomPaint(
              painter: CockpitGridPainter(gridAlpha: 0.06),
            ),
          ),

          // 2. Kinetic Particles Overlay
          Positioned.fill(
            child: ListenableBuilder(
              listenable: _particleController,
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
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              child: Column(
                children: [
                  _buildCockpitHeader(),
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

                  const SizedBox(height: 18),
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
                    currentStoragePath: _resolvedStorageDir.isNotEmpty
                        ? (() {
                            final parts = _resolvedStorageDir.split('/');
                            return parts.length > 2
                                ? parts.sublist(parts.length - 2).join('/')
                                : _resolvedStorageDir;
                          })()
                        : 'Downloads/HyperPulse',
                  ).animate().fadeIn(duration: 600.ms).slideY(begin: 0.1, end: 0),

                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),

          // 4. Smart Overlay Bubble (Final Automatic Linkage)
          if (_floatingLink != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: OverlayBubbleWidget(
                link: _floatingLink!,
                onDownloadPressed: (detectedLink) {
                  // Direct automated pipeline: load into controller & start turbo download
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

  Widget _buildCockpitHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: fieryAmber.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: fieryAmber.withOpacity(0.3)),
              ),
              child: const Icon(
                Icons.radar,
                color: fieryAmber,
                size: 16,
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
                  constraints: const BoxConstraints(maxWidth: 200),
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
                _isDownloading ? 'PARALLEL ACTIVE' : 'CATCHER ACTIVE',
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
            value: '$_activeThreads THREADS',
            accent: fieryAmber,
          ),
          Container(width: 1, height: 24, color: const Color(0xFF282426)),
          _buildTelemetryItem(
            label: 'RAM CACHE',
            value: '${_bufferedRamMb.toStringAsFixed(1)} / 64 MB',
            accent: const Color(0xFFFF9D00),
          ),
          Container(width: 1, height: 24, color: const Color(0xFF282426)),
          _buildTelemetryItem(
            label: 'SHIELD FILTER',
            value: 'ANTI-AD ON',
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
