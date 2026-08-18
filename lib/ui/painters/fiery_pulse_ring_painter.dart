import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Custom Painter rendering the glowing "Fiery Amber" Speed Ring
/// with orbiting electrical energy spark, HUD tick notches, and dual-layer bloom.
class FieryPulseRingPainter extends CustomPainter {
  /// Download progress between 0.0 and 1.0
  final double progress;

  /// Current pulsating phase (0.0 to 1.0) driven by AnimationController
  final double pulsePhase;

  /// Continuous rotation angle (0 to 2*PI) for the orbiting electric spark
  final double sparkAngle;

  /// Number of active download thread segments to draw as HUD notches
  final int segmentCount;

  /// Whether active download is in progress
  final bool isDownloading;

  /// Primary fiery amber energy color (0xFFFF4F00)
  static const Color primaryFlame = Color(0xFFFF4F00);
  static const Color brightCore = Color(0xFFFF9D00);
  static const Color deepPlasma = Color(0xFF9E1F00);
  static const Color darkTrack = Color(0xFF1B1817);

  FieryPulseRingPainter({
    required this.progress,
    required this.pulsePhase,
    required this.sparkAngle,
    this.segmentCount = 16,
    this.isDownloading = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadius = math.min(size.width, size.height) / 2 - 24;

    // 1. Calculate dynamic pulse radius expansion
    final dynamicRadius = isDownloading
        ? baseRadius + (math.sin(pulsePhase * 2 * math.pi) * 3.5)
        : baseRadius;

    // 2. Draw Outer HUD Tactical Notches (Cockpit Telemetry Ring)
    _drawTacticalHUDNotches(canvas, center, dynamicRadius + 14);

    // 3. Draw Background Dark Track Ring
    final trackPaint = Paint()
      ..color = darkTrack
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, dynamicRadius, trackPaint);

    // If progress is zero and idle, draw subtle baseline aura
    if (progress <= 0.0 && !isDownloading) {
      final idleGlow = Paint()
        ..color = primaryFlame.withOpacity(0.15)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0;
      canvas.drawCircle(center, dynamicRadius, idleGlow);
      return;
    }

    // 4. Draw Layer 1: Intense Outer Atmospheric Heat Blur (Glow Aura)
    if (isDownloading) {
      final glowPaint = Paint()
        ..color = primaryFlame.withOpacity(0.35 + (0.2 * math.sin(pulsePhase * 2 * math.pi)))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 24.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18.0)
        ..strokeCap = StrokeCap.round;

      _drawProgressArc(canvas, center, dynamicRadius, glowPaint, progress);
    }

    // 5. Draw Layer 2: Main Fiery Plasma Sweep Gradient
    final sweepGradient = SweepGradient(
      startAngle: -math.pi / 2,
      endAngle: 3 * math.pi / 2,
      colors: const [
        deepPlasma,
        primaryFlame,
        brightCore,
        Color(0xFFFFF0D0),
      ],
      stops: const [0.0, 0.5, 0.85, 1.0],
      transform: const GradientRotation(-math.pi / 2),
    );

    final flamePaint = Paint()
      ..shader = sweepGradient.createShader(Rect.fromCircle(center: center, radius: dynamicRadius))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10.0
      ..strokeCap = StrokeCap.round;

    _drawProgressArc(canvas, center, dynamicRadius, flamePaint, progress);

    // 6. Draw Layer 3: High-Intensity White-Hot Core Line
    final corePaint = Paint()
      ..color = Colors.white.withOpacity(0.75)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    _drawProgressArc(canvas, center, dynamicRadius, corePaint, progress);

    // 7. Draw Layer 4: Orbiting Electrical Energy Spark / Comet
    if (isDownloading) {
      _drawOrbitingElectricSpark(canvas, center, dynamicRadius);
    }

    // 8. Draw Head Flame Orb at current progress tip
    final currentAngle = -math.pi / 2 + (2 * math.pi * progress.clamp(0.01, 1.0));
    final tipX = center.dx + dynamicRadius * math.cos(currentAngle);
    final tipY = center.dy + dynamicRadius * math.sin(currentAngle);
    final tipOffset = Offset(tipX, tipY);

    // Tip plasma glow
    final tipGlow = Paint()
      ..color = brightCore
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(tipOffset, 8.0, tipGlow);

    // Tip white core
    final tipCore = Paint()..color = Colors.white;
    canvas.drawCircle(tipOffset, 4.0, tipCore);
  }

  void _drawProgressArc(Canvas canvas, Offset center, double radius, Paint paint, double currentProgress) {
    final startAngle = -math.pi / 2;
    final sweepAngle = (2 * math.pi * currentProgress.clamp(0.005, 1.0));
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepAngle,
      false,
      paint,
    );
  }

  /// Draws sharp cockpit HUD notches around perimeter
  void _drawTacticalHUDNotches(Canvas canvas, Offset center, double radius) {
    final notchPaint = Paint()
      ..color = const Color(0xFF2A2624)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.square;

    final activeNotchPaint = Paint()
      ..color = primaryFlame.withOpacity(0.7)
      ..strokeWidth = 2.0;

    const int totalTicks = 48;
    final int activeTicks = (totalTicks * progress).round();

    for (int i = 0; i < totalTicks; i++) {
      final angle = (2 * math.pi / totalTicks) * i - (math.pi / 2);
      final isMajor = i % 4 == 0;
      final tickLength = isMajor ? 8.0 : 4.0;

      final startX = center.dx + (radius) * math.cos(angle);
      final startY = center.dy + (radius) * math.sin(angle);
      final endX = center.dx + (radius + tickLength) * math.cos(angle);
      final endY = center.dy + (radius + tickLength) * math.sin(angle);

      final isPast = i <= activeTicks;
      canvas.drawLine(
        Offset(startX, startY),
        Offset(endX, endY),
        isPast ? activeNotchPaint : notchPaint,
      );
    }
  }

  /// Draws a high-voltage electrical spark comet orbiting along the ring
  void _drawOrbitingElectricSpark(Canvas canvas, Offset center, double radius) {
    const int tailSegments = 12;
    for (int i = 0; i < tailSegments; i++) {
      final angleOffset = sparkAngle - (i * 0.06);
      final opacity = (1.0 - (i / tailSegments)).clamp(0.0, 1.0);
      final sparkX = center.dx + radius * math.cos(angleOffset);
      final sparkY = center.dy + radius * math.sin(angleOffset);

      final sparkPaint = Paint()
        ..color = Color.lerp(Colors.white, primaryFlame, i / tailSegments)!.withOpacity(opacity * 0.9)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, (tailSegments - i) * 0.6 + 1.0);

      canvas.drawCircle(Offset(sparkX, sparkY), 3.5 * opacity + 1.0, sparkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant FieryPulseRingPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.pulsePhase != pulsePhase ||
        oldDelegate.sparkAngle != sparkAngle ||
        oldDelegate.isDownloading != isDownloading;
  }
}
