import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/pressable.dart';
import 'auth_controller.dart';
import 'widgets/auth_form.dart';

/// Matches the server's `MIN_PASSWORD_LENGTH`. Checked here so the rule is
/// stated before submission rather than bounced back as a 422.
const int kMinPasswordLength = 8;

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key, required this.controller});

  final AuthController controller;

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  String? _emailIssue;
  String? _passwordIssue;

  @override
  void dispose() {
    _name.dispose();
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
          : (!email.contains('@') ? 'That does not look like an email' : null);
      _passwordIssue = password.length < kMinPasswordLength
          ? 'Use at least $kMinPasswordLength characters'
          : null;
    });
    if (_emailIssue != null || _passwordIssue != null) return;

    final ok = await widget.controller.register(
      email: email,
      password: password,
      displayName: _name.text,
    );
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
          title: 'Create your account',
          subtitle:
              'Your files live in a Telegram channel you own. Nimbus only '
              'keeps track of where they are.',
          busy: controller.busy,
          error: controller.error,
          actionLabel: 'Create account',
          onSubmit: controller.busy ? null : _submit,
          footer: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Already have an account?',
                style: context.text.bodyMedium!.copyWith(
                  color: context.tokens.textSecondary,
                ),
              ),
              const SizedBox(width: Gap.xxs),
              Pressable(
                onTap: () => Navigator.of(context).maybePop(),
                scale: 0.95,
                child: Padding(
                  padding: const EdgeInsets.all(Gap.xxs),
                  child: Text('Sign in', style: context.text.labelLarge),
                ),
              ),
            ],
          ),
          children: [
            AuthField(
              label: 'Name',
              controller: _name,
              hint: 'Optional',
              autofocus: true,
              keyboardType: TextInputType.name,
              autofillHints: const [AutofillHints.name],
              error: serverFields['display_name'],
            ),
            AuthField(
              label: 'Email',
              controller: _email,
              hint: 'you@example.com',
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              error: _emailIssue ?? serverFields['email'],
            ),
            AuthField(
              label: 'Password',
              controller: _password,
              obscure: true,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.newPassword],
              error: _passwordIssue ?? serverFields['password'],
              onSubmitted: (_) => controller.busy ? null : _submit(),
            ),
            Text(
              'At least $kMinPasswordLength characters.',
              style: context.text.bodySmall!.copyWith(
                color: context.tokens.textTertiary,
              ),
            ),
          ],
        );
      },
    );
  }
}
