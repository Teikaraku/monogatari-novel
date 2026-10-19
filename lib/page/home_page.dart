import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/home_page/bookshelf_page.dart';
import 'package:anx_reader/page/home_page/bookstore_page.dart';
import 'package:anx_reader/page/home_page/history_page.dart';
import 'package:anx_reader/page/home_page/settings_page.dart';
import 'package:anx_reader/page/search/search_page.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/service/initialization_check.dart';
import 'package:anx_reader/service/receive_file/receive_share.dart';
import 'package:anx_reader/service/vibration_service.dart';
import 'package:anx_reader/utils/check_update.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:anx_reader/utils/load_default_font.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

WebViewEnvironment? webViewEnvironment;

/// The selected root tab, so pages can switch tabs (e.g. the empty shelf opening the bookstore).
final homeTabProvider = StateProvider<int>((ref) => 0);

/// The five root tabs, matching the 物语 manga app: shelf, bookstore, history, search and settings.
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<ConsumerStatefulWidget> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  /// Tabs are built on first visit and then kept alive, so launch only pays for the shelf.
  final _built = <int>{0};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initAfterFirstFrame());
  }

  Future<void> _initAfterFirstFrame() async {
    AnxToast.init(context);
    unawaited(checkUpdate(false));
    InitializationCheck.check();
    loadDefaultFont();
    if (AnxPlatform.isWindows) {
      await _checkWindowsWebview();
    }
    if (AnxPlatform.isAndroid || AnxPlatform.isIOS || AnxPlatform.isOhos) {
      receiveShareIntent(ref);
    }
    if (DBHelper.updatedDB) {
      _showDbUpdatedDialog();
    }
    if (Prefs().webdavStatus) {
      await Sync().init();
      await Sync().syncData(SyncDirection.both, ref, trigger: SyncTrigger.auto);
    }
  }

  Future<void> _checkWindowsWebview() async {
    final availableVersion = await WebViewEnvironment.getAvailableVersion();
    AnxLog.info('WebView2 version: $availableVersion');
    if (availableVersion == null) {
      SmartDialog.show(
        builder: (context) => AlertDialog(
          title: Text(L10n.of(context).commonAttention),
          content: Text(L10n.of(context).webview2NotInstalled),
          actions: [
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://developer.microsoft.com/en-us/microsoft-edge/webview2'),
                mode: LaunchMode.externalApplication,
              ),
              child: Text(L10n.of(context).webview2Install),
            ),
          ],
        ),
      );
    } else {
      webViewEnvironment = await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(userDataFolder: (await getAnxTempDir()).path),
      );
    }
  }

  void _showDbUpdatedDialog() {
    SmartDialog.show(
      clickMaskDismiss: false,
      builder: (context) => AlertDialog(
        title: Text(L10n.of(context).commonAttention),
        content: Text(L10n.of(context).dbUpdatedTip),
        actions: [
          TextButton(
            onPressed: () => SmartDialog.dismiss(),
            child: Text(L10n.of(context).commonOk),
          ),
        ],
      ),
    );
  }

  void _select(int index) {
    if (index == ref.read(homeTabProvider)) return;
    VibrationService.light();
    ref.read(homeTabProvider.notifier).state = index;
  }

  Widget _page(int index) => switch (index) {
        0 => const BookshelfPage(),
        1 => const BookstorePage(),
        2 => const HistoryPage(),
        3 => const SearchPage(),
        _ => const SettingsPage(),
      };

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final tab = ref.watch(homeTabProvider);
    _built.add(tab);
    final items = [
      MgTabItem(
          icon: Icons.library_books_outlined,
          activeIcon: Icons.library_books,
          label: l10n.navBarBookshelf),
      MgTabItem(
          icon: Icons.auto_stories_outlined,
          activeIcon: Icons.auto_stories,
          label: l10n.navBarBookstore),
      MgTabItem(icon: Icons.history, activeIcon: Icons.history, label: l10n.navBarHistory),
      MgTabItem(icon: Icons.search, activeIcon: Icons.search, label: l10n.navBarSearch),
      MgTabItem(
          icon: Icons.settings_outlined,
          activeIcon: Icons.settings,
          label: l10n.navBarSettings),
    ];
    return Scaffold(
      backgroundColor: MgPalette.of(context).page,
      body: Stack(
        fit: StackFit.expand,
        children: [
          for (var i = 0; i < items.length; i++)
            if (_built.contains(i))
              Offstage(
                offstage: i != tab,
                child: TickerMode(enabled: i == tab, child: _page(i)),
              ),
        ],
      ),
      bottomNavigationBar: MgTabBar(
        items: items,
        currentIndex: tab,
        onTap: _select,
      ),
    );
  }
}
