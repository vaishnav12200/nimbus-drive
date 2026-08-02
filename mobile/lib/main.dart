import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'features/showcase/showcase_screen.dart';

void main() => runApp(const NimbusApp());

class NimbusApp extends StatelessWidget {
  const NimbusApp({super.key});

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
      home: const ShowcaseScreen(),
    );
  }
}
