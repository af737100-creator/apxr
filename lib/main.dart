import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'ui/pulse_download_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Configure Deep Carbon Stealth Theme for Android System Bars
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: Color(0xFF0A0A0C),
      systemNavigationBarIconBrightness: Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    ),
  );

  runApp(const HyperPulseApp());
}

class HyperPulseApp extends StatelessWidget {
  const HyperPulseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyperPulse',
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
