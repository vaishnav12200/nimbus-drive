import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/nimbus_button.dart';
import 'auth_controller.dart';
import 'register_screen.dart';
import 'sign_in_screen.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key, required this.controller});

  final AuthController controller;

  void _open(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ended = controller.endedReason;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Gap.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),

              const Icon(
                Icons.cloud_rounded,
                color: AppColors.primary,
                size: 56,
              ),
              const SizedBox(height: Gap.md),
              Text('Nimbus Drive', style: context.text.displayLarge),
              const SizedBox(height: Gap.sm),
              Text(
                'Your own cloud, stored in a Telegram channel you control. '
                'Encrypted before it leaves your device.',
                style: context.text.bodyLarge!.copyWith(
                  color: tokens.textSecondary,
                ),
              ),

              const Spacer(),

              // Shown when the session ended on its own — otherwise being
              // bounced to this screen looks like the app forgot them.
              if (ended != null) ...[
                Container(
                  padding: const EdgeInsets.all(Gap.sm),
                  decoration: BoxDecoration(
                    color: tokens.raised,
                    borderRadius: BorderRadius.circular(Radii.md),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline_rounded,
                        size: 18,
                        color: tokens.textSecondary,
                      ),
                      const SizedBox(width: Gap.xs),
                      Expanded(
                        child: Text(
                          ended,
                          style: context.text.bodyMedium!.copyWith(
                            color: tokens.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.md),
              ],

              NimbusButton(
                label: 'Create account',
                size: NimbusButtonSize.large,
                expand: true,
                onPressed: () =>
                    _open(context, RegisterScreen(controller: controller)),
              ),
              const SizedBox(height: Gap.xs),
              NimbusButton(
                label: 'I already have an account',
                variant: NimbusButtonVariant.ghost,
                size: NimbusButtonSize.large,
                expand: true,
                onPressed: () =>
                    _open(context, SignInScreen(controller: controller)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shown while a stored session is being checked.
///
/// Normally on screen for one round trip. It explains itself once that stops
/// being true, because a motionless logo is indistinguishable from a crash —
/// and on a free-tier host the first request of the day really can take most
/// of a minute while the server wakes.
class AuthSplash extends StatelessWidget {
  const AuthSplash({super.key, this.slow = false});

  final bool slow;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_rounded, color: AppColors.primary, size: 48),
            const SizedBox(height: Gap.xl),
            AnimatedOpacity(
              duration: Motion.of(context, Motion.slow),
              opacity: slow ? 1 : 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.xxl),
                child: Column(
                  children: [
                    SizedBox(
                      width: 120,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(Radii.pill),
                        child: LinearProgressIndicator(
                          minHeight: 3,
                          backgroundColor: context.tokens.raisedHigh,
                          valueColor: const AlwaysStoppedAnimation(
                            AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: Gap.md),
                    Text(
                      'Waking the server…',
                      textAlign: TextAlign.center,
                      style: context.text.bodyMedium!.copyWith(
                        color: context.tokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: Gap.xxs),
                    Text(
                      'The first start after a while can take a minute.',
                      textAlign: TextAlign.center,
                      style: context.text.bodySmall!.copyWith(
                        color: context.tokens.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
