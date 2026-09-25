import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'ui/pulse_download_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure Deep Carbon Stealth Theme for Android System Bars
  try {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFF0A0A0C),
        systemNavigationBarIconBrightness: Brightness.light,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
    );
  } catch (_) {}

  // Initialize GlitchTip & Sentry Flutter Real-Time Error Tracking SDK
  await SentryFlutter.init(
    (options) => options
      ..dsn = const String.fromEnvironment(
        'SENTRY_DSN',
        defaultValue: 'https://a28c32fad54a4457a1a636d821200065@app.glitchtip.com/28213',
      )
      ..tracesSampleRate = 0.01 // 1% of transactions
      ..enableAutoSessionTracking = false // GlitchTip does not support sessions
      ..attachScreenshot = true
      ..attachViewHierarchy = true
      ..environment = 'production',
    appRunner: () => runApp(
      DefaultAssetBundle(
        bundle: SentryAssetBundle(),
        child: const HyperPulseApp(),
      ),
    ),
  );
}

class HyperPulseApp extends StatelessWidget {
  const HyperPulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'نبضة كروية - PulseSphere',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0A0A0C),
        fontFamily: 'monospace',
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF4F00),
          secondary: Color(0xFFFF9D00),
          surface: Color(0xFF141318),
          background: Color(0xFF0A0A0C),
        ),
      ),
      home: const PulseDownloadScreen(),
    );
  }
}
