import 'dart:ui';
import 'package:flutter/material.dart';
import '../../engine/smart_download_catcher.dart';

/// [OverlayBubbleWidget] is a floating cockpit-styled banner that slides down
/// from the top of the screen when [SmartDownloadCatcher] detects a new link.
class OverlayBubbleWidget extends StatefulWidget {
  final DetectedDownloadLink link;
  final ValueChanged<DetectedDownloadLink> onDownloadPressed;
  final VoidCallback onDismiss;

  const OverlayBubbleWidget({
    super.key,
    required this.link,
    required this.onDownloadPressed,
    required this.onDismiss,
  });

  @override
  State<OverlayBubbleWidget> createState() => _OverlayBubbleWidgetState();
}

class _OverlayBubbleWidgetState extends State<OverlayBubbleWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));

    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeOut),
    );

    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _dismissWithAnimation() async {
    await _controller.reverse();
    widget.onDismiss();
  }

  IconData _getIconForExtension(String? ext) {
    switch (ext?.toLowerCase()) {
      case 'apk':
        return Icons.android;
      case 'mp4':
      case 'mkv':
      case 'webm':
        return Icons.movie;
      case 'mp3':
      case 'wav':
        return Icons.audiotrack;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'exe':
      case 'msi':
        return Icons.laptop_windows;
      default:
        return Icons.download_for_offline;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fieryAmber = const Color(0xFFFF4F00);

    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141318).withOpacity(0.92),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: fieryAmber.withOpacity(0.45), width: 1.2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.6),
                        blurRadius: 20,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: fieryAmber.withOpacity(0.18),
                        blurRadius: 16,
                        spreadRadius: -2,
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      // Glowing Icon Container
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: fieryAmber.withOpacity(0.15),
                          shape: BoxShape.circle,
                          border: Border.all(color: fieryAmber.withOpacity(0.6)),
                        ),
                        child: Icon(
                          widget.link.isVideoPlatform
                              ? Icons.play_circle_filled
                              : _getIconForExtension(widget.link.inferredExtension),
                          color: fieryAmber,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Text Info
                      Expanded(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    color: fieryAmber,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 6),
                                const Text(
                                  'تم اكتشاف رابط تحميل جديد!',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.2,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Text(
                              widget.link.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFFCCC5C8),
                                fontSize: 11,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 8),

                      // Quick Action Download Button
                      GestureDetector(
                        onTap: () {
                          widget.onDownloadPressed(widget.link);
                          _dismissWithAnimation();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFF4F00), Color(0xFFD63B00)],
                            ),
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [
                              BoxShadow(
                                color: fieryAmber.withOpacity(0.4),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.bolt, color: Colors.white, size: 14),
                              SizedBox(width: 4),
                              Text(
                                'تحميل الآن',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(width: 4),

                      // Dismiss Button
                      IconButton(
                        icon: const Icon(Icons.close, color: Color(0xFF7A7376), size: 18),
                        onPressed: _dismissWithAnimation,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
