import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/nimbus_avatar.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_card.dart';
import '../../core/widgets/nimbus_empty_state.dart';
import '../../core/widgets/nimbus_feedback.dart';
import '../../core/widgets/nimbus_list_row.dart';
import '../../core/widgets/nimbus_skeleton.dart';
import '../encryption/encryption_controller.dart';
import '../encryption/encryption_screen.dart';
import 'models/account.dart';
import 'settings_controller.dart';

/// Account, storage, and the two things that make this app work at all:
/// the Telegram binding and the encryption key.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.controller,
    required this.onManageChannel,
    required this.onDisconnectChannel,
    required this.encryption,
  });

  /// The vault. Lives outside this screen because the key is session state,
  /// not account state — the server knows encryption is on, but only this
  /// process knows whether the key has been derived.
  final EncryptionController encryption;

  /// Opens the guided Telegram binding, and resolves true when the binding
  /// changed so this screen can reload rather than showing stale state.
  final Future<bool> Function() onManageChannel;

  /// Removes the binding and the locally held bot token.
  final Future<void> Function() onDisconnectChannel;

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading) return const _Loading();

        final account = controller.account;
        if (account == null) {
          return NimbusEmptyState(
            icon: Icons.cloud_off_rounded,
            title: 'Could not load your account',
            message: controller.error,
            actionLabel: 'Try again',
            accent: AppColors.danger,
            onAction: controller.load,
          );
        }

        return SafeArea(
          bottom: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, 104),
            children: [
              Text('Settings', style: context.text.headlineMedium),
              const SizedBox(height: Gap.lg),

              _AccountCard(account: account, controller: controller),
              const SizedBox(height: Gap.md),
              _StorageCard(account: account),
              const SizedBox(height: Gap.xl),

              _Group(
                title: 'Storage backend',
                child: _TelegramSection(
                  controller: controller,
                  binding: account.telegram,
                  onManage: onManageChannel,
                  onDisconnect: onDisconnectChannel,
                ),
              ),

              _Group(
                title: 'Encryption',
                child: _EncryptionSection(
                  state: account.encryption,
                  controller: encryption,
                  onChanged: controller.load,
                ),
              ),

              _Group(
                title: 'Security',
                child: Column(
                  children: [
                    NimbusListRow(
                      title: 'Signed-in devices',
                      subtitle: '${account.activeSessions} active sessions',
                      icon: Icons.devices_rounded,
                      iconColor: context.tokens.textSecondary,
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _showSessionsSheet(context, account),
                    ),
                    NimbusListRow(
                      title: 'Sign out everywhere',
                      subtitle: 'Revokes every refresh token',
                      icon: Icons.logout_rounded,
                      iconColor: AppColors.danger,
                      onTap: () => _confirmSignOutAll(context, controller),
                    ),
                  ],
                ),
              ),

              _Group(
                title: 'About',
                child: Column(
                  children: [
                    NimbusListRow(
                      title: 'Version',
                      icon: Icons.info_outline_rounded,
                      iconColor: context.tokens.textSecondary,
                      trailing: Text(
                        '1.0.0',
                        style: context.text.bodyMedium!.copyWith(
                          color: context.tokens.textTertiary,
                        ),
                      ),
                    ),
                    NimbusListRow(
                      title: 'Open-source licences',
                      icon: Icons.gavel_rounded,
                      iconColor: context.tokens.textSecondary,
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: 'Nimbus Drive',
                        applicationVersion: '1.0.0',
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: Gap.xs),
              NimbusButton(
                label: 'Sign out',
                variant: NimbusButtonVariant.ghost,
                icon: Icons.logout_rounded,
                expand: true,
                onPressed: () => _confirmSignOut(context, controller),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.controller});

  final Account account;
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return NimbusCard(
      padding: const EdgeInsets.all(Gap.md),
      onTap: () => _showAccountSheet(context, account, controller),
      child: Row(
        children: [
          NimbusAvatar(name: account.displayName, size: 52),
          const SizedBox(width: Gap.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(account.displayName, style: context.text.titleMedium),
                const SizedBox(height: 2),
                Text(
                  account.email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.bodySmall!.copyWith(
                    color: context.tokens.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: context.tokens.textTertiary),
        ],
      ),
    );
  }
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.account});

  final Account account;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return NimbusCard(
      padding: const EdgeInsets.all(Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Storage', style: context.text.titleMedium)),
              Text(
                '${formatBytes(account.storageUsed)} of '
                '${formatBytes(account.storageQuota)}',
                style: context.text.bodySmall!.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: account.storageFraction,
              minHeight: 8,
              backgroundColor: tokens.raisedHigh,
              valueColor: const AlwaysStoppedAnimation(AppColors.primary),
            ),
          ),
        ],
      ),
    );
  }
}

class _TelegramSection extends StatelessWidget {
  const _TelegramSection({
    required this.controller,
    required this.binding,
    required this.onManage,
    required this.onDisconnect,
  });

  final SettingsController controller;
  final TelegramBinding binding;
  final Future<bool> Function() onManage;
  final Future<void> Function() onDisconnect;

  /// Reloads the account when the flow reports a change, so the card flips
  /// from "no channel" to the bound state without a manual refresh.
  Future<void> _manage() async {
    if (await onManage()) await controller.load();
  }

  Future<void> _confirmDisconnect(BuildContext context) async {
    final confirmed = await NimbusFeedback.confirm(
      context,
      title: 'Disconnect this channel?',
      message:
          'Nimbus stops being able to upload or download. The files already in '
          'your Telegram channel are untouched, and reconnecting the same '
          'channel restores access to them.',
      confirmLabel: 'Disconnect',
    );
    if (!confirmed || !context.mounted) return;

    await onDisconnect();
    await controller.load();
    if (context.mounted) NimbusFeedback.toast(context, 'Channel disconnected');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    // An unbound account cannot store anything, so this is a broken install
    // rather than an unset preference — it leads with the fix.
    if (!binding.isBound) {
      return NimbusCard(
        color: AppColors.danger.withValues(alpha: 0.12),
        bordered: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: AppColors.danger,
                  size: 20,
                ),
                const SizedBox(width: Gap.xs),
                Text('No channel connected', style: context.text.titleMedium),
              ],
            ),
            const SizedBox(height: Gap.xs),
            Text(
              'Nimbus stores your files in a Telegram channel you own. '
              'Nothing can be uploaded until one is bound.',
              style: context.text.bodyMedium!.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(height: Gap.md),
            NimbusButton(
              label: 'Connect a channel',
              expand: true,
              onPressed: _manage,
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        NimbusListRow(
          title: binding.channelName ?? 'Channel',
          subtitle: binding.botUsername == null
              ? '${binding.channelId}'
              : '${binding.channelId} · @${binding.botUsername}',
          icon: Icons.send_rounded,
          iconColor: AppColors.primary,
          trailing: Icon(
            binding.lastTestOk == false
                ? Icons.error_outline_rounded
                : Icons.check_circle_rounded,
            color: binding.lastTestOk == false
                ? AppColors.danger
                : AppColors.success,
            size: 20,
          ),
          onTap: _manage,
        ),
        // No chevron and no tap: the server never returns the token in full,
        // so there is nothing to open and nothing to copy.
        NimbusListRow(
          title: 'Bot token',
          subtitle: binding.maskedBotToken,
          icon: Icons.key_rounded,
          iconColor: tokens.textSecondary,
        ),
        NimbusListRow(
          title: 'Test connection',
          subtitle: binding.lastTestedAt == null
              ? 'Never tested'
              : 'Last tested ${formatWhen(binding.lastTestedAt!)}',
          icon: Icons.wifi_tethering_rounded,
          iconColor: tokens.textSecondary,
          trailing: controller.testing
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right_rounded),
          onTap: controller.testing ? null : () => _test(context, controller),
        ),
        NimbusListRow(
          title: 'Disconnect channel',
          subtitle: 'Existing files stay in Telegram',
          icon: Icons.link_off_rounded,
          iconColor: AppColors.danger,
          onTap: () => _confirmDisconnect(context),
        ),
      ],
    );
  }

  static Future<void> _test(
    BuildContext context,
    SettingsController controller,
  ) async {
    final result = await controller.testTelegram();
    if (!context.mounted) return;

    // The server writes this text for display, so it is shown as-is.
    result.ok
        ? NimbusFeedback.success(context, result.detail)
        : NimbusFeedback.error(context, result.detail);
  }
}

class _EncryptionSection extends StatelessWidget {
  const _EncryptionSection({
    required this.state,
    required this.controller,
    required this.onChanged,
  });

  /// What the *server* knows: whether a salt exists, and how many files use it.
  final EncryptionState state;

  /// What this *process* knows: whether the key has been derived.
  final EncryptionController controller;

  final Future<void> Function() onChanged;

  Future<void> _open(BuildContext context) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => EncryptionScreen(controller: controller),
      ),
    );
    // Setting up flips `encryption_enabled` server-side, so the account has to
    // be refetched for the file count to be right.
    if (changed ?? false) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final tokens = context.tokens;
        final vault = describeVault(controller.state, context);
        final locked = controller.state == VaultState.locked;
        final off = controller.state == VaultState.off;

        return Column(
          children: [
            NimbusListRow(
              title: vault.title,
              subtitle: state.enabled && controller.state != VaultState.off
                  ? '${state.encryptedFileCount} files · ${state.kdf}'
                  : vault.subtitle,
              icon: vault.icon,
              iconColor: vault.color,
              trailing: off || locked
                  ? const Icon(Icons.chevron_right_rounded)
                  : null,
              // Only offers a tap when there is something to do: set it up, or
              // unlock it. An unlocked vault needs nothing.
              onTap: off || locked ? () => _open(context) : null,
            ),

            if (controller.state == VaultState.unlocked)
              NimbusListRow(
                title: 'Lock now',
                subtitle: 'Forgets the key until you enter the password again',
                icon: Icons.lock_outline_rounded,
                iconColor: tokens.textSecondary,
                onTap: controller.lock,
              ),

            if (!off)
              NimbusListRow(
                title: 'Password never leaves this device',
                subtitle: 'Forget it and the data is unrecoverable',
                icon: Icons.info_outline_rounded,
                iconColor: tokens.textTertiary,
              ),
          ],
        );
      },
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: Gap.xs, bottom: Gap.xs),
            child: Text(
              title.toUpperCase(),
              style: context.text.labelSmall!.copyWith(
                color: context.tokens.textTertiary,
              ),
            ),
          ),
          NimbusCard(
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: child,
          ),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      bottom: false,
      child: NimbusSkeletonGroup(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Gap.page),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(height: Gap.md),
              NimbusSkeleton(width: 160, height: 28),
              SizedBox(height: Gap.lg),
              NimbusSkeleton(height: 84, radius: Radii.lg),
              SizedBox(height: Gap.md),
              NimbusSkeleton(height: 72, radius: Radii.lg),
              SizedBox(height: Gap.xl),
              NimbusSkeleton(height: 160, radius: Radii.lg),
            ],
          ),
        ),
      ),
    );
  }
}

/// Account details, and the one action that belongs to the account itself.
void _showAccountSheet(
  BuildContext context,
  Account account,
  SettingsController controller,
) {
  NimbusFeedback.sheet<void>(
    context,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NimbusSheetHeader(title: 'Account'),
        Row(
          children: [
            NimbusAvatar(name: account.displayName, size: 56),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    account.displayName,
                    style: sheetContext.text.titleLarge,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    account.email,
                    style: sheetContext.text.bodyMedium!.copyWith(
                      color: sheetContext.tokens.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.md),
        NimbusListRow(
          title: 'Storage used',
          icon: Icons.pie_chart_rounded,
          iconColor: AppColors.primary,
          trailing: Text(
            '${(account.storageFraction * 100).round()}%',
            style: sheetContext.text.bodyLarge,
          ),
        ),
        NimbusListRow(
          title: 'Encrypted files',
          icon: Icons.lock_rounded,
          iconColor: AppColors.success,
          trailing: Text(
            '${account.encryption.encryptedFileCount}',
            style: sheetContext.text.bodyLarge,
          ),
        ),
        NimbusListRow(
          title: 'Signed-in devices',
          icon: Icons.devices_rounded,
          iconColor: sheetContext.tokens.textSecondary,
          trailing: Text(
            '${account.activeSessions}',
            style: sheetContext.text.bodyLarge,
          ),
        ),
        const SizedBox(height: Gap.md),
        NimbusButton(
          label: 'Sign out',
          variant: NimbusButtonVariant.ghost,
          icon: Icons.logout_rounded,
          expand: true,
          onPressed: () {
            Navigator.of(sheetContext).pop();
            _confirmSignOut(context, controller);
          },
        ),
      ],
    ),
  );
}

void _showSessionsSheet(BuildContext context, Account account) {
  NimbusFeedback.sheet<void>(
    context,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NimbusSheetHeader(title: 'Signed-in devices'),
        for (final session in account.sessions)
          NimbusListRow(
            title: session.device,
            subtitle: [
              if (session.location != null) session.location!,
              session.isCurrent
                  ? 'Active now'
                  : 'Last seen ${formatWhen(session.lastSeen)}',
            ].join(' · '),
            icon: session.isCurrent
                ? Icons.smartphone_rounded
                : Icons.devices_other_rounded,
            iconColor: session.isCurrent
                ? AppColors.primary
                : sheetContext.tokens.textSecondary,
            // The current session has no per-row revoke: signing itself out is
            // "Sign out", not something you do to a device in a list.
            trailing: session.isCurrent
                ? Text(
                    'This device',
                    style: sheetContext.text.bodySmall!.copyWith(
                      color: AppColors.primary,
                    ),
                  )
                : null,
          ),
        const SizedBox(height: Gap.xs),
        Text(
          'Individual revocation needs the sessions endpoint; today the only '
          'lever is signing every device out.',
          style: sheetContext.text.bodySmall!.copyWith(
            color: sheetContext.tokens.textTertiary,
          ),
        ),
        const SizedBox(height: Gap.sm),
      ],
    ),
  );
}

Future<void> _confirmSignOut(
  BuildContext context,
  SettingsController controller,
) async {
  final confirmed = await NimbusFeedback.confirm(
    context,
    title: 'Sign out?',
    message: 'Your files stay in your Telegram channel.',
    confirmLabel: 'Sign out',
    destructive: false,
  );
  if (!confirmed || !context.mounted) return;

  await controller.signOut();
  if (context.mounted) NimbusFeedback.toast(context, 'Signed out');
}

Future<void> _confirmSignOutAll(
  BuildContext context,
  SettingsController controller,
) async {
  final confirmed = await NimbusFeedback.confirm(
    context,
    title: 'Sign out everywhere?',
    message:
        'Every device is signed out, including this one. You will need to '
        'sign in again.',
    confirmLabel: 'Sign out all',
  );
  if (!confirmed || !context.mounted) return;

  await controller.signOutEverywhere();
  if (context.mounted) NimbusFeedback.toast(context, 'All sessions revoked');
}
