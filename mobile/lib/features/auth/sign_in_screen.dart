import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/pressable.dart';
import 'auth_controller.dart';
import 'register_screen.dart';
import 'widgets/auth_form.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key, required this.controller});

  final AuthController controller;

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();

  /// Client-side complaints, kept apart from the server's so a stale server
  /// message cannot outlive the field it belonged to.
  String? _emailIssue;
  String? _passwordIssue;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    final password = _password.text;

    setState(() {
      _emailIssue = email.isEmpty
          ? 'Enter your email'
          : (!isProbablyEmail(email)
                ? 'That does not look like an email'
                : null);
      // Not the 8-character rule here. On sign-in the password either matches
      // or it does not, and pre-judging an existing password is noise.
      _passwordIssue = password.isEmpty ? 'Enter your password' : null;
    });
    if (_emailIssue != null || _passwordIssue != null) return;

    final ok = await widget.controller.signIn(email: email, password: password);
    if (!mounted) return;

    // The gate swaps its child for the app, but these screens were *pushed*
    // on top of it — leaving the app rendering underneath a form the user
    // already submitted. Unwinding to the root is what makes the swap visible.
    if (ok) {
      Navigator.of(context).popUntil((route) => route.isFirst);
    } else {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final serverFields = controller.fieldErrors;

        return AuthScaffold(
          title: 'Welcome back',
          subtitle: 'Sign in to reach your drive.',
          busy: controller.busy,
          error: controller.error,
          actionLabel: 'Sign in',
          onSubmit: controller.busy ? null : _submit,
          footer: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'New here?',
                style: context.text.bodyMedium!.copyWith(
                  color: context.tokens.textSecondary,
                ),
              ),
              const SizedBox(width: Gap.xxs),
              Pressable(
                onTap: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute<void>(
                    builder: (_) => RegisterScreen(controller: controller),
                  ),
                ),
                scale: 0.95,
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xxs),
                  child: Text(
                    'Create an account',
                    style: context.text.labelLarge,
                  ),
                ),
              ),
            ],
          ),
          children: [
            AuthField(
              label: 'Email',
              controller: _email,
              hint: 'you@example.com',
              autofocus: true,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.username],
              error: _emailIssue ?? serverFields['email'],
            ),
            AuthField(
              label: 'Password',
              controller: _password,
              obscure: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              error: _passwordIssue ?? serverFields['password'],
              onSubmitted: (_) => controller.busy ? null : _submit(),
            ),
          ],
        );
      },
    );
  }
}
