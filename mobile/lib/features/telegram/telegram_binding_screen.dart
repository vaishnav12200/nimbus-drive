import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_card.dart';
import '../../core/widgets/pressable.dart';
import 'telegram_binding_controller.dart';

/// Guided setup for the channel that will hold every file.
///
/// Four of the five steps happen in Telegram, not here, so each one states one
/// task and waits. Cramming them into a single form would mean losing your
/// place every time you switch apps — which is once per step.
class TelegramBindingScreen extends StatefulWidget {
  const TelegramBindingScreen({super.key, required this.controller});

  final TelegramBindingController controller;

  @override
  State<TelegramBindingScreen> createState() => _TelegramBindingScreenState();
}

class _TelegramBindingScreenState extends State<TelegramBindingScreen> {
  final _token = TextEditingController();
  final _channel = TextEditingController();
  final _name = TextEditingController();

  @override
  void dispose() {
    _token.dispose();
    _channel.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    final ok = await widget.controller.submit();
    if (!mounted) return;

    if (ok) {
      // true tells Settings the binding changed, so it reloads rather than
      // showing the "no channel" card it was built with.
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;

        return PopScope(
          // Back moves up the flow before it leaves it, so a mistyped token is
          // one tap from being fixed rather than a restart.
          canPop: c.isFirst,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) c.back();
          },
          child: Scaffold(
            body: SafeArea(
              child: Column(
                children: [
                  _Header(controller: c),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                        Gap.page,
                        Gap.md,
                        Gap.page,
                        Gap.xl,
                      ),
                      children: [_body(c)],
                    ),
                  ),
                  _Footer(controller: c, onFinish: _finish),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _body(TelegramBindingController c) => switch (c.step) {
    BindingStep.channel => const _Instructions(
      title: 'Create a private channel',
      lead:
          'Nimbus stores every file as a message in a Telegram channel that '
          'you own. Nobody else can read it, and you can delete the channel at '
          'any time.',
      steps: [
        'Open Telegram and create a **new channel**.',
        'Make it **private**. A public channel is readable by anyone.',
        'Give it any name you like — "Nimbus Vault" works.',
      ],
    ),

    BindingStep.botToken => _TokenStep(controller: c, field: _token),

    BindingStep.admin => const _Instructions(
      title: 'Add the bot to your channel',
      lead:
          'The bot is what actually posts your files. It needs permission to '
          'write to the channel.',
      steps: [
        'Open your channel, then **Administrators → Add Admin**.',
        'Search for the bot by the username BotFather gave you.',
        'Enable **Post Messages**. The rest can stay off.',
      ],
    ),

    BindingStep.channelId => _ChannelStep(
      controller: c,
      idField: _channel,
      nameField: _name,
    ),

    BindingStep.test => _TestStep(controller: c),
  };
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final TelegramBindingController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.page, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              NimbusIconButton(
                icon: controller.isFirst
                    ? Icons.close_rounded
                    : Icons.arrow_back_rounded,
                size: 40,
                tooltip: controller.isFirst ? 'Cancel' : 'Back',
                onPressed: () => controller.isFirst
                    ? Navigator.of(context).pop(false)
                    : controller.back(),
              ),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  'Step ${controller.step.index + 1} of '
                  '${BindingStep.values.length}',
                  style: context.text.bodyMedium!.copyWith(
                    color: tokens.textSecondary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),
          Padding(
            padding: const EdgeInsets.only(right: Gap.xs),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: TweenAnimationBuilder<double>(
                duration: Motion.of(context, Motion.normal),
                curve: Motion.decelerate,
                tween: Tween(end: controller.progress),
                builder: (context, value, _) => LinearProgressIndicator(
                  value: value,
                  minHeight: 4,
                  backgroundColor: tokens.raisedHigh,
                  valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.controller, required this.onFinish});

  final TelegramBindingController controller;
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final issue = controller.stepIssue;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        Gap.page,
        0,
        Gap.page,
        MediaQuery.viewInsetsOf(context).bottom + Gap.md,
      ),
      child: NimbusButton(
        label: controller.isLast ? 'Connect channel' : 'Continue',
        size: NimbusButtonSize.large,
        expand: true,
        loading: controller.busy,
        // Disabled until the current step's value is plausible, so an
        // obviously wrong token never costs a round trip.
        onPressed: issue != null
            ? null
            : (controller.isLast ? onFinish : controller.next),
      ),
    );
  }
}

/// A numbered list of things to do in Telegram.
class _Instructions extends StatelessWidget {
  const _Instructions({
    required this.title,
    required this.lead,
    required this.steps,
  });

  final String title;
  final String lead;

  /// `**bold**` is honoured, since the important word in each line is the one
  /// to tap in Telegram.
  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Reused inside steps that already have their own heading, where both
        // are empty — rendering them anyway left a block of dead space.
        if (title.isNotEmpty) ...[
          Text(title, style: context.text.headlineMedium),
          const SizedBox(height: Gap.xs),
        ],
        if (lead.isNotEmpty) ...[
          Text(
            lead,
            style: context.text.bodyLarge!.copyWith(
              color: tokens.textSecondary,
            ),
          ),
          const SizedBox(height: Gap.xl),
        ],
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: context.text.labelSmall!.copyWith(
                      color: AppColors.primary,
                    ),
                  ),
                ),
                const SizedBox(width: Gap.sm),
                Expanded(child: _RichLine(text: steps[i])),
              ],
            ),
          ),
      ],
    );
  }
}

/// Renders `**bold**` spans without pulling in a markdown package.
class _RichLine extends StatelessWidget {
  const _RichLine({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final base = context.text.bodyLarge!;
    final parts = text.split('**');

    return Text.rich(
      TextSpan(
        children: [
          for (var i = 0; i < parts.length; i++)
            TextSpan(
              text: parts[i],
              // Odd indices sit between a pair of markers.
              style: i.isOdd
                  ? base.copyWith(fontWeight: FontWeight.w600)
                  : base.copyWith(color: context.tokens.textSecondary),
            ),
        ],
      ),
    );
  }
}

class _TokenStep extends StatelessWidget {
  const _TokenStep({required this.controller, required this.field});

  final TelegramBindingController controller;
  final TextEditingController field;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Create a bot', style: context.text.headlineMedium),
        const SizedBox(height: Gap.xs),
        Text(
          'The bot posts your files into the channel. It belongs to you and is '
          'used by nothing else.',
          style: context.text.bodyLarge!.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: Gap.lg),

        const _Instructions(
          title: '',
          lead: '',
          steps: [
            'Message **@BotFather** in Telegram.',
            'Send **/newbot** and follow the prompts.',
            'Copy the **HTTP API token** it gives you.',
          ],
        ),

        Text(
          'Bot token',
          style: context.text.labelLarge!.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: Gap.xs),
        TextField(
          controller: field,
          onChanged: controller.setBotToken,
          autocorrect: false,
          enableSuggestions: false,
          style: context.text.bodyLarge,
          decoration: InputDecoration(
            hintText: '123456789:AAHdqTcvCH1vGWJxfSeofSAs0K5PALDsaw',
            suffixIcon: IconButton(
              icon: Icon(
                Icons.paste_rounded,
                size: 20,
                color: tokens.textTertiary,
              ),
              tooltip: 'Paste',
              onPressed: () async {
                final data = await Clipboard.getData(Clipboard.kTextPlain);
                final text = data?.text?.trim();
                if (text == null || text.isEmpty) return;
                field.text = text;
                controller.setBotToken(text);
              },
            ),
          ),
        ),
        if (controller.botToken.isNotEmpty && controller.stepIssue != null) ...[
          const SizedBox(height: Gap.xxs),
          Text(
            controller.stepIssue!,
            style: context.text.bodySmall!.copyWith(color: AppColors.danger),
          ),
        ],
        const SizedBox(height: Gap.md),

        _Note(
          icon: Icons.lock_rounded,
          text:
              'The token is stored in this device\'s keychain and sent to your '
              'Nimbus server encrypted. Small files upload straight from here '
              'to Telegram using it.',
        ),
      ],
    );
  }
}

class _ChannelStep extends StatelessWidget {
  const _ChannelStep({
    required this.controller,
    required this.idField,
    required this.nameField,
  });

  final TelegramBindingController controller;
  final TextEditingController idField;
  final TextEditingController nameField;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Find the channel ID', style: context.text.headlineMedium),
        const SizedBox(height: Gap.xs),
        Text(
          'Telegram identifies channels by a number, not a name.',
          style: context.text.bodyLarge!.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: Gap.lg),

        const _Instructions(
          title: '',
          lead: '',
          steps: [
            'Forward any message from your channel to **@userinfobot**.',
            'It replies with an id like **-1001234567890**.',
            'Copy the whole thing, including the minus sign.',
          ],
        ),

        Text(
          'Channel ID',
          style: context.text.labelLarge!.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: Gap.xs),
        TextField(
          controller: idField,
          onChanged: controller.setChannelId,
          keyboardType: const TextInputType.numberWithOptions(signed: true),
          style: context.text.bodyLarge,
          decoration: const InputDecoration(hintText: '-1001234567890'),
        ),
        if (controller.channelId.isNotEmpty &&
            controller.stepIssue != null) ...[
          const SizedBox(height: Gap.xxs),
          Text(
            controller.stepIssue!,
            style: context.text.bodySmall!.copyWith(color: AppColors.danger),
          ),
        ],
        const SizedBox(height: Gap.md),

        Text(
          'Channel name (optional)',
          style: context.text.labelLarge!.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: Gap.xs),
        TextField(
          controller: nameField,
          onChanged: controller.setChannelName,
          style: context.text.bodyLarge,
          decoration: const InputDecoration(hintText: 'Nimbus Vault'),
        ),
      ],
    );
  }
}

class _TestStep extends StatelessWidget {
  const _TestStep({required this.controller});

  final TelegramBindingController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final error = controller.error;
    final fix = controller.stepToFix;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ready to connect', style: context.text.headlineMedium),
        const SizedBox(height: Gap.xs),
        Text(
          'Nimbus will check the bot can reach your channel and post a test '
          'message.',
          style: context.text.bodyLarge!.copyWith(color: tokens.textSecondary),
        ),
        const SizedBox(height: Gap.lg),

        NimbusCard(
          child: Column(
            children: [
              _Row(
                label: 'Bot token',
                value: _mask(controller.botToken),
                icon: Icons.key_rounded,
              ),
              const SizedBox(height: Gap.sm),
              _Row(
                label: 'Channel',
                value: controller.channelId,
                icon: Icons.send_rounded,
              ),
            ],
          ),
        ),

        if (error != null) ...[
          const SizedBox(height: Gap.md),
          Container(
            padding: const EdgeInsets.all(Gap.sm),
            decoration: BoxDecoration(
              color: AppColors.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      size: 18,
                      color: AppColors.danger,
                    ),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: Text(
                        error,
                        style: context.text.bodyMedium!.copyWith(
                          color: AppColors.danger,
                        ),
                      ),
                    ),
                  ],
                ),
                // Jumps straight to the step that can fix it, rather than
                // making the user work out which one was wrong.
                if (fix != null) ...[
                  const SizedBox(height: Gap.xs),
                  Pressable(
                    onTap: () => controller.goTo(fix),
                    scale: 0.96,
                    child: Padding(
                      padding: const EdgeInsets.all(Gap.xxs),
                      child: Text(
                        'Go back to "${fix.title}"',
                        style: context.text.labelLarge!.copyWith(
                          color: AppColors.danger,
                          decoration: TextDecoration.underline,
                          decorationColor: AppColors.danger,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// Shows enough of the token to recognise, not enough to use.
  static String _mask(String token) {
    if (token.length < 12) return token;
    return '${token.substring(0, 8)}${'•' * 12}${token.substring(token.length - 4)}';
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value, required this.icon});

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Row(
      children: [
        Icon(icon, size: 18, color: tokens.textTertiary),
        const SizedBox(width: Gap.xs),
        Text(
          label,
          style: context.text.bodyMedium!.copyWith(color: tokens.textTertiary),
        ),
        const Spacer(),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodyMedium,
          ),
        ),
      ],
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: tokens.textTertiary),
        const SizedBox(width: Gap.xs),
        Expanded(
          child: Text(
            text,
            style: context.text.bodySmall!.copyWith(color: tokens.textTertiary),
          ),
        ),
      ],
    );
  }
}
