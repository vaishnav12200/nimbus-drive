import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_empty_state.dart';
import '../encryption/encryption_controller.dart';
import '../encryption/encryption_screen.dart';
import 'data/download_service.dart';
import 'models/drive_item.dart';

/// Fetches a file and shows what it can.
///
/// Images render inline. Everything else reports that it arrived and how big it
/// was — opening a PDF or playing a video needs a platform viewer, which is a
/// separate piece of work. Getting the bytes back, decrypted, is the part that
/// proves the round trip.
class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({
    super.key,
    required this.file,
    required this.downloads,
    required this.encryption,
    this.botToken,
  });

  final DriveFile file;
  final DownloadService downloads;
  final EncryptionController encryption;

  /// Lets a small file come straight from Telegram. Without it everything is
  /// proxied, which still works but costs the server the bandwidth.
  final String? botToken;

  @override
  State<FilePreviewScreen> createState() => _FilePreviewScreenState();
}

class _FilePreviewScreenState extends State<FilePreviewScreen> {
  Uint8List? _bytes;
  String? _error;
  bool _locked = false;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _locked = false;
      _progress = null;
    });

    try {
      final bytes = await widget.downloads.fetch(
        widget.file,
        botToken: widget.botToken,
        onProgress: (received, total) {
          if (total > 0 && mounted) {
            setState(() => _progress = received / total);
          }
        },
      );
      if (mounted) setState(() => _bytes = bytes);
    } on VaultLockedException {
      // Recoverable, and worth distinguishing: the file is fine, the key is
      // simply not in memory yet.
      if (mounted) setState(() => _locked = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _unlockAndRetry() async {
    if (await promptUnlock(context, widget.encryption) && mounted) {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.file;

    return Scaffold(
      appBar: AppBar(
        title: Text(file.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (file.isEncrypted)
            const Padding(
              padding: EdgeInsets.only(right: Gap.sm),
              child: Icon(
                Icons.lock_rounded,
                size: 18,
                color: AppColors.success,
              ),
            ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_locked) {
      return NimbusEmptyState(
        icon: Icons.lock_rounded,
        title: 'This file is encrypted',
        message:
            'Unlock your drive to read it. The key never leaves the device.',
        actionLabel: 'Unlock',
        accent: AppColors.warning,
        onAction: _unlockAndRetry,
      );
    }

    if (_error != null) {
      return NimbusEmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not open this file',
        message: _error,
        actionLabel: 'Try again',
        accent: AppColors.danger,
        onAction: _load,
      );
    }

    if (_bytes == null) return _Loading(progress: _progress);

    return widget.file.type == FileType.image
        ? _ImageView(bytes: _bytes!)
        : _Fetched(file: widget.file, bytes: _bytes!);
  }
}

class _Loading extends StatelessWidget {
  const _Loading({this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 160,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(Radii.pill),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 6,
                backgroundColor: context.tokens.raisedHigh,
                valueColor: const AlwaysStoppedAnimation(AppColors.primary),
              ),
            ),
          ),
          const SizedBox(height: Gap.md),
          Text(
            progress == null ? 'Fetching…' : '${(progress! * 100).round()}%',
            style: context.text.bodyMedium!.copyWith(
              color: context.tokens.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _ImageView extends StatelessWidget {
  const _ImageView({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      maxScale: 6,
      child: Center(
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          // A file that decrypted cleanly can still fail to be an image — a
          // renamed extension, say. Better a message than a red error box.
          errorBuilder: (context, _, _) => NimbusEmptyState(
            icon: Icons.broken_image_rounded,
            title: 'Not a readable image',
            message: 'The bytes came back, but nothing here can display them.',
          ),
        ),
      ),
    );
  }
}

/// The non-image case: confirm the bytes arrived, and say what they are.
class _Fetched extends StatelessWidget {
  const _Fetched({required this.file, required this.bytes});

  final DriveFile file;
  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: tokens
                    .accentForType(file.type.wire)
                    .withValues(alpha: 0.16),
                shape: BoxShape.circle,
              ),
              child: Icon(
                file.type.icon,
                size: 32,
                color: tokens.accentForType(file.type.wire),
              ),
            ),
            const SizedBox(height: Gap.lg),
            Text(
              file.isEncrypted ? 'Decrypted' : 'Downloaded',
              style: context.text.titleLarge,
            ),
            const SizedBox(height: Gap.xs),
            Text(
              '${formatBytes(bytes.length)} of readable data'
              '${file.isEncrypted ? ', decrypted on this device' : ''}.',
              textAlign: TextAlign.center,
              style: context.text.bodyMedium!.copyWith(
                color: tokens.textSecondary,
              ),
            ),
            const SizedBox(height: Gap.lg),
            Text(
              'Opening this type needs a platform viewer, which is not built '
              'yet.',
              textAlign: TextAlign.center,
              style: context.text.bodySmall!.copyWith(
                color: tokens.textTertiary,
              ),
            ),
            const SizedBox(height: Gap.lg),
            NimbusButton(
              label: 'Done',
              variant: NimbusButtonVariant.secondary,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}
