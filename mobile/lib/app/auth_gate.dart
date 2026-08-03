import 'package:flutter/material.dart';

import '../core/theme/app_dimens.dart';
import '../features/auth/auth_controller.dart';
import '../features/auth/welcome_screen.dart';
import 'app_shell.dart';
import 'dependencies.dart';

/// Decides between the splash, the sign-in flow and the app.
///
/// Everything hangs off [AuthController], so a session lost mid-request drops
/// the user here from wherever they were — no screen has to check for itself.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key, required this.dependencies});

  final Dependencies dependencies;

  @override
  Widget build(BuildContext context) {
    final auth = dependencies.auth;

    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        final child = switch (auth.status) {
          AuthStatus.restoring => const AuthSplash(),
          AuthStatus.signedOut => WelcomeScreen(controller: auth),
          AuthStatus.signedIn => AppShell(
            // Keyed by account so switching users rebuilds every tab rather
            // than showing the previous user's folders under a new name.
            key: ValueKey(auth.user?.id),
            dependencies: dependencies,
          ),
        };

        return AnimatedSwitcher(
          duration: Motion.of(context, Motion.normal),
          switchInCurve: Motion.decelerate,
          switchOutCurve: Motion.accelerate,
          child: KeyedSubtree(key: ValueKey(auth.status), child: child),
        );
      },
    );
  }
}
