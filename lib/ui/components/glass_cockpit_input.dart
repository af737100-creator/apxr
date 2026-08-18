import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Glassmorphic Cockpit URL input panel with dark metallic action trigger,
/// functional Clipboard auto-paste, and video-to-MP3 extraction toggle.
class GlassCockpitInput extends StatefulWidget {
  final TextEditingController controller;
  final VoidCallback onStartDownload;
  final bool isDownloading;
  final bool extractMp3Enabled;
  final ValueChanged<bool> onExtractMp3Changed;
  final bool isVideoDetected;
  final String currentStoragePath;
  final VoidCallback? onStorageTap;

  const GlassCockpitInput({
    super.key,
    required this.controller,
    required this.onStartDownload,
    this.isDownloading = false,
    required this.extractMp3Enabled,
    required this.onExtractMp3Changed,
    this.isVideoDetected = false,
    this.currentStoragePath = 'مجلد التنزيلات (Downloads/HyperPulse)',
    this.onStorageTap,
  });

  @override
  State<GlassCockpitInput> createState() => _GlassCockpitInputState();
}

class _GlassCockpitInputState extends State<GlassCockpitInput> {
  bool _isHovered = false;
  bool _isPressed = false;

  /// Reads text from system clipboard and inserts into input field
  Future<void> _handlePasteFromClipboard() async {
    try {
      final ClipboardData? data = await Clipboard.getData(Clipboard.kTextPlain);
      final String? text = data?.text?.trim();

      if (text != null && text.isNotEmpty) {
        widget.controller.text = text;
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF1B181A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFFFF4F00), width: 1),
              ),
              content: Row(
                children: [
                  const Icon(Icons.check_circle, color: Color(0xFFFF4F00), size: 18),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'تم لصق الرابط من الحافظة بنجاح',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ),
                ],
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).hideCurrentSnackBar();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              backgroundColor: const Color(0xFF1B181A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Color(0xFF5A5255), width: 1),
              ),
              content: Row(
                children: [
                  const Icon(Icons.info_outline, color: Color(0xFFFF9D00), size: 18),
                  const SizedBox(width: 10),
                  const Text(
                    'لا يوجد رابط منسوخ حالياً',
                    style: TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[GlassCockpitInput] Clipboard paste error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16.0, sigmaY: 16.0),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF141318).withOpacity(0.6),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFFF4F00).withOpacity(0.22),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.45),
                blurRadius: 24,
                spreadRadius: -4,
                offset: const Offset(0, 12),
              ),
              BoxShadow(
                color: const Color(0xFFFF4F00).withOpacity(0.06),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Header HUD Label & Actions
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF4F00),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'STEALTH TARGET ACQUISITION',
                        style: TextStyle(
                          color: Color(0xFFFF4F00),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),

                  // Real Functional Clipboard Paste Button
                  GestureDetector(
                    onTap: widget.isDownloading ? null : _handlePasteFromClipboard,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF221F21),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFF4F00).withOpacity(0.4)),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFFF4F00).withOpacity(0.1),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.content_paste, size: 12, color: Color(0xFFFF4F00)),
                          SizedBox(width: 4),
                          Text(
                            'لصق الرابط',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // 2. URL Input Field
              Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF09090B),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF2E2B2D),
                    width: 1.0,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: widget.controller,
                        enabled: !widget.isDownloading,
                        style: const TextStyle(
                          color: Color(0xFFEDE9E8),
                          fontSize: 13,
                          fontFamily: 'monospace',
                        ),
                        cursorColor: const Color(0xFFFF4F00),
                        decoration: const InputDecoration(
                          hintText: 'ضع رابط التحميل (MP4, APK, ZIP, YouTube, TikTok...)',
                          hintStyle: TextStyle(
                            color: Color(0xFF5A5456),
                            fontSize: 12,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                    if (widget.controller.text.isNotEmpty && !widget.isDownloading)
                      IconButton(
                        icon: const Icon(Icons.clear, size: 16, color: Color(0xFF6B6366)),
                        onPressed: () => setState(() => widget.controller.clear()),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 10),

              // 3. Audio / MP3 Extraction Switch & Storage Path Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  // MP3 Audio Extraction Switch
                  GestureDetector(
                    onTap: widget.isDownloading
                        ? null
                        : () => widget.onExtractMp3Changed(!widget.extractMp3Enabled),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: widget.extractMp3Enabled
                            ? const Color(0xFFFF4F00).withOpacity(0.15)
                            : const Color(0xFF171518),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: widget.extractMp3Enabled
                              ? const Color(0xFFFF4F00)
                              : const Color(0xFF332E30),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.music_note,
                            size: 14,
                            color: widget.extractMp3Enabled
                                ? const Color(0xFFFF4F00)
                                : const Color(0xFF8C8487),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            'استخراج MP3 (Audio)',
                            style: TextStyle(
                              color: widget.extractMp3Enabled
                                  ? const Color(0xFFFF4F00)
                                  : const Color(0xFF9E9698),
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: widget.extractMp3Enabled
                                  ? const Color(0xFFFF4F00)
                                  : Colors.transparent,
                              border: Border.all(
                                color: widget.extractMp3Enabled
                                    ? const Color(0xFFFF4F00)
                                    : const Color(0xFF554D50),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Destination Storage Path info
                  Flexible(
                    child: GestureDetector(
                      onTap: widget.onStorageTap,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.folder_open, size: 13, color: Color(0xFF7A7376)),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              widget.currentStoragePath,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF8A8285),
                                fontSize: 9.5,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // 4. Dark Metallic Gradient Action Button ("ابدأ التحميل")
              MouseRegion(
                onEnter: (_) => setState(() => _isHovered = true),
                onExit: (_) => setState(() => _isHovered = false),
                child: GestureDetector(
                  onTapDown: (_) => setState(() => _isPressed = true),
                  onTapUp: (_) => setState(() => _isPressed = false),
                  onTapCancel: () => setState(() => _isPressed = false),
                  onTap: widget.isDownloading ? null : widget.onStartDownload,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    transform: Matrix4.identity()..scale(_isPressed ? 0.98 : 1.0),
                    height: 50,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: widget.isDownloading
                            ? const [Color(0xFF1E1A18), Color(0xFF121010)]
                            : _isHovered
                                ? const [Color(0xFF3A3432), Color(0xFF1E1A18), Color(0xFF141212)]
                                : const [Color(0xFF2C2725), Color(0xFF1A1716), Color(0xFF0F0E0E)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: widget.isDownloading
                            ? const Color(0xFF352B26)
                            : _isHovered
                                ? const Color(0xFFFF4F00)
                                : const Color(0xFF4A403C),
                        width: 1.4,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.white.withOpacity(0.1),
                          blurRadius: 1,
                          offset: const Offset(0, -1),
                        ),
                        BoxShadow(
                          color: Colors.black.withOpacity(0.6),
                          blurRadius: 12,
                          offset: const Offset(0, 6),
                        ),
                        if (!widget.isDownloading && _isHovered)
                          BoxShadow(
                            color: const Color(0xFFFF4F00).withOpacity(0.25),
                            blurRadius: 16,
                            spreadRadius: 1,
                          ),
                      ],
                    ),
                    child: Center(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (widget.isDownloading)
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFFFF4F00),
                              ),
                            )
                          else
                            const Icon(
                              Icons.bolt,
                              color: Color(0xFFFF4F00),
                              size: 20,
                            ),
                          const SizedBox(width: 10),
                          Text(
                            widget.isDownloading
                                ? 'جاري التحميل المتوازي الفائق...'
                                : widget.extractMp3Enabled
                                    ? 'ابدأ التحميل واستخراج MP3'
                                    : 'ابدأ التحميل المتسارع',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
