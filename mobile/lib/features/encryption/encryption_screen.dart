import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../auth/widgets/auth_form.dart';
import 'encryption_controller.dart';

/// Minimum for the vault password.
///
/// Longer than the account password's eight, and deliberately so: an account
/// password is defended by a server-side rate limit, while this one defends
/// ciphertext that an attacker could grind offline for as long as they like.
const int kMinVaultPasswordLength = 12;

/// Sets up encryption, or unlocks it on a device that did not.
///
/// One screen for both because they ask the same question. What differs is the
/// stakes: setup is the last moment the password can be chosen, and the only
/// moment the warning means anything.
class EncryptionScreen extends StatefulWidget {
  const EncryptionScreen({super.key, required this.controller});

  final EncryptionController controller;

  @override
  State<EncryptionScreen> createState() => _EncryptionScreenState();
}

class _EncryptionScreenState extends State<EncryptionScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  String? _passwordIssue;
  String? _confirmIssue;
  bool _acknowledged = false;

  bool get _isSetup => widget.controller.state == VaultState.off;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;

    setState(() {
      _passwordIssue = _isSetup && password.length < kMinVaultPasswordLength
          ? 'Use at least $kMinVaultPasswordLength characters'
          : (password.isEmpty ? 'Enter your password' : null);
      _confirmIssue = _isSetup && _confirm.text != password
          ? 'The two passwords do not match'
          : null;
    });
    if (_passwordIssue != null || _confirmIssue != null) return;

    final ok = _isSetup
        ? await widget.controller.setUp(password)
        : await widget.controller.unlock(password);

    if (ok && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final setup = _isSetup;

        return AuthScaffold(
          title: setup ? 'Set an encryption password' : 'Unlock your drive',
          subtitle: setup
              ? 'Files are encrypted on this device before they are uploaded. '
                    'Nobody who sees the channel can read them — including us.'
              : 'This drive is encrypted. Enter the password you chose when you '
                    'set it up.',
          busy: c.busy,
          error: c.error,
          actionLabel: setup ? 'Turn on encryption' : 'Unlock',
          // Setup is gated on the warning being acknowledged. There is no
          // recovery path, so a distracted tap should not be enough.
          onSubmit: c.busy || (setup && !_acknowledged) ? null : _submit,
          children: [
            AuthField(
              label: setup ? 'Encryption password' : 'Password',
              controller: _password,
              obscure: true,
              autofocus: true,
              textInputAction: setup
                  ? TextInputAction.next
                  : TextInputAction.done,
              error: _passwordIssue,
              onSubmitted: (_) => setup ? null : _submit(),
            ),
            if (setup)
              AuthField(
                label: 'Confirm password',
                controller: _confirm,
                obscure: true,
                textInputAction: TextInputAction.done,
                error: _confirmIssue,
                onSubmitted: (_) => _submit(),
              ),
            if (setup) ...[
              Text(
                'At least $kMinVaultPasswordLength characters. Different from '
                'your account password.',
                style: context.text.bodySmall!.copyWith(
                  color: context.tokens.textTertiary,
                ),
              ),
              const SizedBox(height: Gap.lg),
              _Warning(
                acknowledged: _acknowledged,
                onChanged: (v) => setState(() => _acknowledged = v),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The one thing a user must understand before turning this on.
class _Warning extends StatelessWidget {
  const _Warning({required this.acknowledged, required this.onChanged});

  final bool acknowledged;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Container(
      padding: const EdgeInsets.all(Gap.md),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 20,
                color: AppColors.warning,
              ),
              const SizedBox(width: Gap.xs),
              Text(
                'There is no way to reset this',
                style: context.text.titleMedium!.copyWith(
                  color: AppColors.warning,
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text(
            'The password never leaves this device, so nobody — not us, not a '
            'support request, not a password reset — can recover it. Forget it '
            'and every encrypted file is gone for good.',
            style: context.text.bodyMedium!.copyWith(
              color: tokens.textSecondary,
            ),
          ),
          const SizedBox(height: Gap.sm),
          InkWell(
            onTap: () => onChanged(!acknowledged),
            borderRadius: BorderRadius.circular(Radii.xs),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xxs),
              child: Row(
                children: [
                  Checkbox(
                    value: acknowledged,
                    onChanged: (v) => onChanged(v ?? false),
                    activeColor: AppColors.primary,
                    checkColor: AppColors.onPrimary,
                    visualDensity: VisualDensity.compact,
                  ),
                  const SizedBox(width: Gap.xxs),
                  Expanded(
                    child: Text(
                      'I have saved this password somewhere safe',
                      style: context.text.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for the password when something needs the key right now.
///
/// Returns true once unlocked. Used before a download of an encrypted file,
/// where sending the user to Settings and back would lose what they were doing.
Future<bool> promptUnlock(
  BuildContext context,
  EncryptionController controller,
) async {
  if (controller.canEncrypt) return true;

  final unlocked = await Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      builder: (_) => EncryptionScreen(controller: controller),
    ),
  );
  return unlocked ?? false;
}

/// A one-line summary of the vault, for Settings.
({String title, String subtitle, IconData icon, Color color}) describeVault(
  VaultState state,
  BuildContext context,
) => switch (state) {
  VaultState.loading => (
    title: 'Checking…',
    subtitle: '',
    icon: Icons.lock_outline_rounded,
    color: context.tokens.textSecondary,
  ),
  VaultState.off => (
    title: 'Not set up',
    subtitle: 'Files are stored unencrypted',
    icon: Icons.lock_open_rounded,
    color: context.tokens.textSecondary,
  ),
  VaultState.locked => (
    title: 'Locked',
    subtitle: 'Enter your password to read or add encrypted files',
    icon: Icons.lock_rounded,
    color: AppColors.warning,
  ),
  VaultState.unlocked => (
    title: 'Unlocked',
    subtitle: 'New uploads are encrypted on this device',
    icon: Icons.lock_rounded,
    color: AppColors.success,
  ),
};
