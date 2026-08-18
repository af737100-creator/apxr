import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Single glowing particle model in the particle simulation.
class Particle {
  double x;
  double y;
  double vx;
  double vy;
  double life;
  double maxLife;
  double size;
  Color color;

  Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
    required this.maxLife,
    required this.size,
    required this.color,
  });

  bool update(double dt) {
    x += vx * dt;
    y += vy * dt;
    // Apply air drag and slight upward draft
    vx *= 0.96;
    vy = (vy * 0.96) - 15 * dt;
    life -= dt;
    return life > 0;
  }
}

/// Particle System rendering energetic embers during turbo speed and bursting on completion.
class StealthParticleController extends ChangeNotifier {
  final List<Particle> particles = [];
  final math.Random _rng = math.Random();

  void spawnBurst(Offset origin, {int count = 60}) {
    final colors = [
      const Color(0xFFFF4F00),
      const Color(0xFFFF9D00),
      const Color(0xFFFFD500),
      Colors.white,
    ];

    for (int i = 0; i < count; i++) {
      final angle = _rng.nextDouble() * 2 * math.pi;
      final speed = _rng.nextDouble() * 220 + 80;
      final life = _rng.nextDouble() * 1.2 + 0.6;
      final size = _rng.nextDouble() * 3.5 + 1.5;
      final color = colors[_rng.nextInt(colors.length)];

      particles.add(
        Particle(
          x: origin.dx,
          y: origin.dy,
          vx: math.cos(angle) * speed,
          vy: math.sin(angle) * speed,
          life: life,
          maxLife: life,
          size: size,
          color: color,
        ),
      );
    }
    notifyListeners();
  }

  void spawnAmbientEmbers(Offset origin, {int count = 2}) {
    for (int i = 0; i < count; i++) {
      final angle = _rng.nextDouble() * 2 * math.pi;
      final speed = _rng.nextDouble() * 60 + 20;
      final life = _rng.nextDouble() * 0.8 + 0.4;

      particles.add(
        Particle(
          x: origin.dx + (_rng.nextDouble() * 40 - 20),
          y: origin.dy + (_rng.nextDouble() * 40 - 20),
          vx: math.cos(angle) * speed,
          vy: math.sin(angle) * speed - 30,
          life: life,
          maxLife: life,
          size: _rng.nextDouble() * 2.5 + 1.0,
          color: const Color(0xFFFF4F00).withOpacity(0.8),
        ),
      );
    }
    notifyListeners();
  }

  void tick(double dt) {
    if (particles.isEmpty) return;
    particles.removeWhere((p) => !p.update(dt));
    notifyListeners();
  }
}

/// CustomPainter that paints all active fiery particles
class StealthParticlePainter extends CustomPainter {
  final List<Particle> particles;

  StealthParticlePainter({required this.particles});

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      final progress = (p.life / p.maxLife).clamp(0.0, 1.0);
      final alpha = progress;
      final currentSize = p.size * (0.5 + 0.5 * progress);

      final paint = Paint()
        ..color = p.color.withOpacity(alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);

      canvas.drawCircle(Offset(p.x, p.y), currentSize, paint);

      final corePaint = Paint()..color = Colors.white.withOpacity(alpha * 0.9);
      canvas.drawCircle(Offset(p.x, p.y), currentSize * 0.4, corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant StealthParticlePainter oldDelegate) => true;
}
