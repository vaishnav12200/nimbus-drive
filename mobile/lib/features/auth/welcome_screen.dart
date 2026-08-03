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
/// Deliberately plain: it is on screen for one round trip, and anything that
/// animates in would still be animating when it disappears.
class AuthSplash extends StatelessWidget {
  const AuthSplash({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Icon(Icons.cloud_rounded, color: AppColors.primary, size: 48),
      ),
    );
  }
}
