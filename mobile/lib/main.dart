import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app/auth_gate.dart';
import 'app/dependencies.dart';
import 'core/theme/app_theme.dart';

/// Runs against the in-memory drive instead of the backend:
/// `flutter run --dart-define=NIMBUS_FAKE=true`
///
/// Useful for design work and for a device with no route to the API. The fakes
/// reproduce latency, name clashes and the encrypted-share refusal, so screens
/// still exercise their loading and error paths.
const bool _useFakes = bool.fromEnvironment('NIMBUS_FAKE');

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Draw behind the status and navigation bars so the app fills the display on
  // every phone, whatever shape its cutouts and gesture bar are. Individual
  // screens already wrap their content in SafeArea, so nothing lands under a
  // system bar — this only removes the letterboxing around them.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      // Transparent rather than tinted: a coloured bar over a near-black canvas
      // reads as a seam, and Android 15 ignores the colour anyway.
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );

  runApp(
    NimbusApp(
      dependencies: _useFakes ? Dependencies.fake() : Dependencies.live(),
    ),
  );
}

class NimbusApp extends StatefulWidget {
  const NimbusApp({super.key, required this.dependencies});

  final Dependencies dependencies;

  @override
  State<NimbusApp> createState() => _NimbusAppState();
}

class _NimbusAppState extends State<NimbusApp> {
  @override
  void dispose() {
    widget.dependencies.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nimbus Drive',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      // Dark-only for now. The palette is built around a near-black canvas and
      // a light theme is a design decision, not a colour inversion — so it
      // waits until there is a reference for it.
      themeMode: ThemeMode.dark,
      darkTheme: AppTheme.dark,
      scrollBehavior: const NimbusScrollBehavior(),
      home: AuthGate(dependencies: widget.dependencies),
    );
  }
}
