import 'package:flutter/material.dart';

/// Painter that renders stealth jet cockpit HUD telemetry lines,
/// grid intersections, radar brackets, and ambient carbon depth.
class CockpitGridPainter extends CustomPainter {
  final double gridAlpha;

  CockpitGridPainter({this.gridAlpha = 0.08});

  @override
  void paint(Canvas canvas, Size size) {
    final linePaint = Paint()
      ..color = const Color(0xFFFF4F00).withOpacity(gridAlpha)
      ..strokeWidth = 1.0;

    final hudBracketPaint = Paint()
      ..color = const Color(0xFFFF4F00).withOpacity(gridAlpha * 2.5)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;

    // 1. Draw subtle isometric grid
    const double gridSize = 40.0;
    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }

    // 2. Draw Top-Left HUD Cockpit Tactical Corner Bracket
    _drawCornerBracket(canvas, const Offset(20, 20), 24, hudBracketPaint, 1, 1);
    // Top-Right
    _drawCornerBracket(canvas, Offset(size.width - 20, 20), 24, hudBracketPaint, -1, 1);
    // Bottom-Left
    _drawCornerBracket(canvas, Offset(20, size.height - 20), 24, hudBracketPaint, 1, -1);
    // Bottom-Right
    _drawCornerBracket(canvas, Offset(size.width - 20, size.height - 20), 24, hudBracketPaint, -1, -1);

    // 3. Central Target Crosshair markers
    final center = Offset(size.width / 2, size.height / 2);
    final crossPaint = Paint()
      ..color = const Color(0xFFFF4F00).withOpacity(0.12)
      ..strokeWidth = 1.0;

    canvas.drawLine(Offset(center.dx - 12, center.dy), Offset(center.dx + 12, center.dy), crossPaint);
    canvas.drawLine(Offset(center.dx, center.dy - 12), Offset(center.dx, center.dy + 12), crossPaint);
  }

  void _drawCornerBracket(Canvas canvas, Offset origin, double length, Paint paint, double dirX, double dirY) {
    final path = Path();
    path.moveTo(origin.dx, origin.dy + (length * dirY));
    path.lineTo(origin.dx, origin.dy);
    path.lineTo(origin.dx + (length * dirX), origin.dy);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CockpitGridPainter oldDelegate) => oldDelegate.gridAlpha != gridAlpha;
}
