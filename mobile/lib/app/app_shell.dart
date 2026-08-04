import 'package:flutter/material.dart';

import '../core/widgets/nimbus_nav_bar.dart';
import '../features/files/files_controller.dart';
import '../features/files/files_screen.dart';
import '../features/files/models/drive_item.dart';
import '../features/home/home_controller.dart';
import '../features/home/home_screen.dart';
import '../features/settings/data/api_settings_repository.dart';
import '../features/settings/settings_controller.dart';
import '../features/settings/settings_screen.dart';
import '../features/shared/shared_screen.dart';
import '../features/shared/shares_controller.dart';
import '../features/telegram/telegram_binding_controller.dart';
import '../features/telegram/telegram_binding_screen.dart';
import '../features/uploads/uploads_controller.dart';
import '../features/uploads/uploads_screen.dart';
import 'dependencies.dart';

/// The five destinations, behind one persistent nav bar.
enum NimbusTab {
  home(Icons.home_rounded, 'Home'),
  files(Icons.folder_rounded, 'Files'),
  upload(Icons.arrow_upward_rounded, 'Upload'),
  shared(Icons.link_rounded, 'Shared'),
  settings(Icons.settings_rounded, 'Settings');

  const NimbusTab(this.icon, this.label);

  final IconData icon;
  final String label;
}

/// Root scaffold.
///
/// Owns one controller per tab so browsing state — the folder you were in, the
/// sort you chose, the upload queue — survives switching tabs. Each is built on
/// first visit rather than up front, so an unopened tab costs nothing.
///
/// Repositories arrive from [Dependencies], so the shell neither knows nor
/// cares whether it is talking to the backend or to the in-memory fakes.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.dependencies});

  final Dependencies dependencies;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  NimbusTab _tab = NimbusTab.home;

  Dependencies get _deps => widget.dependencies;

  /// Nullable and lazily built rather than `late final`: a `late final` that
  /// `dispose` touches gets *initialised* by the disposal, constructing a
  /// controller at teardown and leaving its work running after the tree is
  /// gone.
  HomeController? _home;
  FilesController? _files;
  UploadsController? _uploads;
  SharesController? _shares;
  SettingsController? _settings;

  // Home and Files share one repository instance, or a rename on Files would
  // leave Home quoting the old name.
  HomeController get home => _home ??= HomeController(_deps.files);

  FilesController get files => _files ??= FilesController(_deps.files);

  UploadsController get uploads =>
      _uploads ??= UploadsController(_deps.transfers);

  SharesController get shares => _shares ??= SharesController(_deps.shares);

  SettingsController get settings => _settings ??= SettingsController(
    ApiSettingsRepository(_deps.api, _deps.files, _deps.auth),
  );

  @override
  void dispose() {
    _home?.dispose();
    _files?.dispose();
    _uploads?.dispose();
    _shares?.dispose();
    _settings?.dispose();
    super.dispose();
  }

  Widget _pageFor(NimbusTab tab) => switch (tab) {
    NimbusTab.home => HomeScreen(
      controller: home,
      userName: _deps.auth.user?.name ?? 'Nimbus',
      onOpenFiles: _openFiles,
      onOpenUpload: () => _select(NimbusTab.upload),
      onOpenSettings: () => _select(NimbusTab.settings),
    ),
    NimbusTab.files => FilesScreen(
      controller: files,
      onOpenUpload: () => _select(NimbusTab.upload),
      downloads: _deps.downloads,
      encryption: _deps.encryption,
      botTokens: _deps.botTokens,
    ),
    NimbusTab.upload => UploadsScreen(controller: uploads),
    NimbusTab.shared => SharedScreen(controller: shares),
    NimbusTab.settings => SettingsScreen(
      controller: settings,
      onManageChannel: _openBinding,
      onDisconnectChannel: () =>
          unbindTelegram(_deps.telegram, _deps.botTokens),
      encryption: _deps.encryption,
    ),
  };

  /// Runs the guided Telegram binding. Resolves true when the binding changed.
  ///
  /// The controller is built per visit — it holds a half-entered token and a
  /// step position, neither of which should survive being cancelled.
  Future<bool> _openBinding() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => TelegramBindingScreen(
          controller: TelegramBindingController(
            _deps.telegram,
            _deps.botTokens,
          ),
        ),
      ),
    );
    return changed ?? false;
  }

  /// Switches to Files, optionally narrowed to one category.
  ///
  /// The filter is applied before the tab changes so the list is already
  /// correct on the first frame rather than flashing the previous folder.
  void _openFiles({FileType? type}) {
    files.showOnly(type);
    _select(NimbusTab.files);
  }

  void _select(NimbusTab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            // IndexedStack rather than a switch: it keeps each visited tab's
            // element tree alive, so scroll position and any in-flight sheet
            // survive a round trip through another tab.
            child: IndexedStack(
              index: _tab.index,
              children: [
                for (final tab in NimbusTab.values)
                  // Tabs are built only once visited, then kept.
                  if (tab == _tab || _isBuilt(tab))
                    _pageFor(tab)
                  else
                    const SizedBox.shrink(),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NimbusNavBar(
              items: [
                for (final tab in NimbusTab.values)
                  NimbusNavItem(icon: tab.icon, label: tab.label),
              ],
              currentIndex: _tab.index,
              onChanged: (i) => _select(NimbusTab.values[i]),
            ),
          ),
        ],
      ),
    );
  }

  bool _isBuilt(NimbusTab tab) => switch (tab) {
    NimbusTab.home => _home != null,
    NimbusTab.files => _files != null,
    NimbusTab.upload => _uploads != null,
    NimbusTab.shared => _shares != null,
    NimbusTab.settings => _settings != null,
  };
}
