import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_card.dart';
import '../../core/widgets/nimbus_empty_state.dart';
import '../../core/widgets/nimbus_feedback.dart';
import '../../core/widgets/nimbus_list_row.dart';
import '../../core/widgets/nimbus_transfer_row.dart';
import 'models/transfer.dart';
import 'uploads_controller.dart';

/// The upload queue.
///
/// Uploads here are not a brief spinner — a large file is cut into 19 MB
/// chunks and forwarded over MTProto, and Telegram can rate-limit the bot
/// mid-flight. The screen is built around that: routes are labelled, chunk
/// positions are shown, and failures explain themselves and offer a retry.
class UploadsScreen extends StatelessWidget {
  const UploadsScreen({super.key, required this.controller});

  final UploadsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, 104),
          children: [
            _Header(controller: controller),
            const SizedBox(height: Gap.lg),
            _PickCard(controller: controller),
            const SizedBox(height: Gap.md),

            if (controller.isEmpty)
              const _Empty()
            else ...[
              if (controller.active.isNotEmpty) ...[
                NimbusSectionHeader(
                  title: 'In progress',
                  actionLabel: '${controller.activeCount} active',
                ),
                const SizedBox(height: Gap.xs),
                _Group(transfers: controller.active, controller: controller),
                const SizedBox(height: Gap.lg),
              ],
              if (controller.completed.isNotEmpty) ...[
                NimbusSectionHeader(
                  title: 'Completed',
                  actionLabel: 'Clear',
                  onAction: controller.clearCompleted,
                ),
                const SizedBox(height: Gap.xs),
                _Group(transfers: controller.completed, controller: controller),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens the picker and reports only what is worth reporting.
///
/// Backing out of the picker returns nothing and says nothing — it is not an
/// error. A refused upload usually means no channel is bound, which is worth
/// saying plainly since it is fixed in Settings, not here.
Future<void> _pick(BuildContext context, UploadsController controller) async {
  try {
    final added = await controller.pickFiles();
    if (added == 0 || !context.mounted) return;
    NimbusFeedback.toast(
      context,
      added == 1 ? 'Added 1 file to the queue' : 'Added $added files',
    );
  } catch (e) {
    if (context.mounted) NimbusFeedback.error(context, '$e');
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final UploadsController controller;

  @override
  Widget build(BuildContext context) {
    final progress = controller.overallProgress;

    return Row(
      children: [
        Expanded(child: Text('Upload', style: context.text.headlineMedium)),
        if (progress != null)
          Text(
            '${(progress * 100).round()}%',
            style: context.text.titleMedium!.copyWith(color: AppColors.primary),
          ),
      ],
    );
  }
}

/// The lime call to action. This screen exists to start an upload, so the
/// primary action gets the hero treatment rather than a button in a row.
class _PickCard extends StatelessWidget {
  const _PickCard({required this.controller});

  final UploadsController controller;

  @override
  Widget build(BuildContext context) {
    const ink = AppColors.onPrimary;

    return NimbusCard(
      color: AppColors.primary,
      radius: Radii.xl,
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.cloud_upload_rounded, size: 26, color: ink),
              const SizedBox(width: Gap.xs),
              Expanded(
                child: Text(
                  'Add to your drive',
                  style: context.text.titleLarge!.copyWith(color: ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.xs),
          Text(
            'Files up to 20 MB go straight to Telegram. Larger ones are '
            'chunked and streamed through the server.',
            style: context.text.bodyMedium!.copyWith(
              color: ink.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: Gap.md),

          Row(
            children: [
              Expanded(
                child: NimbusButton(
                  label: 'Choose files',
                  icon: Icons.add_rounded,
                  variant: NimbusButtonVariant.secondary,
                  expand: true,
                  onPressed: () => _pick(context, controller),
                ),
              ),
              const SizedBox(width: Gap.xs),
              NimbusIconButton(
                icon: Icons.photo_library_rounded,
                size: 52,
                background: ink,
                foreground: AppColors.primary,
                tooltip: 'From photos',
                onPressed: () => _pick(context, controller),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),

          Row(
            children: [
              Icon(
                Icons.folder_rounded,
                size: 15,
                color: ink.withValues(alpha: 0.7),
              ),
              const SizedBox(width: Gap.xxs),
              Text(
                'Saving to ${controller.destination}',
                style: context.text.bodySmall!.copyWith(
                  color: ink.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.transfers, required this.controller});

  final List<Transfer> transfers;
  final UploadsController controller;

  @override
  Widget build(BuildContext context) {
    return NimbusCard(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Column(
        children: [
          for (final t in transfers)
            NimbusTransferRow(
              name: t.name,
              state: t.state,
              progress: t.progress,
              icon: t.type.icon,
              accent: context.tokens.accentForType(t.type.wire),
              detail: _detail(t),
              onCancel: () => controller.cancel(t),
              onRetry: () => controller.retry(t),
              onTap: () => _showDetails(context, t),
            ),
        ],
      ),
    );
  }

  static String _detail(Transfer t) {
    if (t.state == TransferState.failed) {
      final wait = t.retryAfter ?? 0;
      return wait > 0
          ? '${t.error} — retry in ${wait}s'
          : '${t.error} — ready to retry';
    }
    if (t.state == TransferState.done) {
      return '${formatBytes(t.totalBytes)} · ${t.route.label}';
    }
    if (t.state == TransferState.queued) return 'Waiting for capacity';

    final moved = '${formatBytes(t.sentBytes)} / ${formatBytes(t.totalBytes)}';
    return t.route == TransferRoute.chunked
        ? '$moved · chunk ${t.chunkIndex ?? 1} of ${t.chunkCount}'
        : moved;
  }

  static void _showDetails(BuildContext context, Transfer t) {
    NimbusFeedback.sheet<void>(
      context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NimbusSheetHeader(title: t.name),
          _Fact(label: 'Size', value: formatBytes(t.totalBytes)),
          _Fact(label: 'Route', value: t.route.label),
          if (t.route == TransferRoute.chunked)
            _Fact(
              label: 'Chunks',
              value: '${t.chunkIndex ?? 0} of ${t.chunkCount} · 19 MB each',
            ),
          _Fact(label: 'Transferred', value: formatBytes(t.sentBytes)),
          if (t.error != null) _Fact(label: 'Last error', value: t.error!),
          const SizedBox(height: Gap.xs),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: context.text.bodyMedium!.copyWith(
                color: context.tokens.textTertiary,
              ),
            ),
          ),
          Expanded(child: Text(value, style: context.text.bodyMedium)),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: Gap.xxl),
      child: NimbusEmptyState(
        icon: Icons.inbox_rounded,
        title: 'Nothing in the queue',
        message: 'Uploads you start will appear here with their progress.',
      ),
    );
  }
}
