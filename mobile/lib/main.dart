import 'package:flutter/material.dart';

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
