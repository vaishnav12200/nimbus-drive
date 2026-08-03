import 'package:flutter/material.dart';

import '../core/widgets/nimbus_nav_bar.dart';
import '../features/files/data/file_repository.dart';
import '../features/files/data/in_memory_file_repository.dart';
import '../features/files/files_controller.dart';
import '../features/files/files_screen.dart';
import '../features/files/models/drive_item.dart';
import '../features/home/home_controller.dart';
import '../features/home/home_screen.dart';
import '../features/settings/settings_controller.dart';
import '../features/settings/settings_screen.dart';
import '../features/shared/data/share_repository.dart';
import '../features/shared/shared_screen.dart';
import '../features/shared/shares_controller.dart';
import '../features/uploads/data/fake_transfer_repository.dart';
import '../features/uploads/uploads_controller.dart';
import '../features/uploads/uploads_screen.dart';

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
/// Every controller here is constructed with an in-memory repository. Those
/// four lines are the entire surface that changes when the API client lands.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  NimbusTab _tab = NimbusTab.home;

  /// Nullable and lazily built rather than `late final`: a `late final` that
  /// `dispose` touches gets *initialised* by the disposal, constructing a
  /// controller at teardown and leaving its work running after the tree is
  /// gone.
  /// Home and Files read the same drive, so they share one repository —
  /// otherwise a rename on Files would leave Home quoting the old name.
  late final FileRepository _fileRepository = InMemoryFileRepository();

  HomeController? _home;
  FilesController? _files;
  UploadsController? _uploads;
  SharesController? _shares;
  SettingsController? _settings;

  HomeController get home => _home ??= HomeController(_fileRepository);

  FilesController get files => _files ??= FilesController(_fileRepository);

  UploadsController get uploads =>
      _uploads ??= UploadsController(FakeTransferRepository());

  SharesController get shares =>
      _shares ??= SharesController(InMemoryShareRepository());

  SettingsController get settings => _settings ??= SettingsController(
    InMemorySettingsRepository(_fileRepository),
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
      onOpenFiles: _openFiles,
      onOpenUpload: () => _select(NimbusTab.upload),
      onOpenSettings: () => _select(NimbusTab.settings),
    ),
    NimbusTab.files => FilesScreen(
      controller: files,
      onOpenUpload: () => _select(NimbusTab.upload),
    ),
    NimbusTab.upload => UploadsScreen(controller: uploads),
    NimbusTab.shared => SharedScreen(controller: shares),
    NimbusTab.settings => SettingsScreen(controller: settings),
  };

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
