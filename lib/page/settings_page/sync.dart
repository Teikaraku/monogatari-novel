

import 'package:anx_reader/enums/sync_protocol.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/service/sync/sync_client_factory.dart';
import 'package:anx_reader/utils/sync_test_helper.dart';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/utils/webdav/test_webdav.dart';
import 'package:anx_reader/widgets/settings/settings_title.dart';
import 'package:anx_reader/widgets/settings/webdav_switch.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:anx_reader/widgets/settings/settings_section.dart';
import 'package:anx_reader/widgets/settings/settings_tile.dart';


class SyncSetting extends ConsumerStatefulWidget {
  const SyncSetting({super.key});

  @override
  ConsumerState<SyncSetting> createState() => _SyncSettingState();
}

class _SyncSettingState extends ConsumerState<SyncSetting> {
  @override
  Widget build(BuildContext context) {
    return settingsSections(
      sections: [
        SettingsSection(
          title: Text(L10n.of(context).settingsSyncWebdav),
          tiles: [
            webdavSwitch(context, setState, ref),
            SettingsTile.navigation(
                title: Text(L10n.of(context).settingsSyncWebdav),
                leading: const Icon(Icons.cloud),
                value: Text(Prefs().getSyncInfo(SyncProtocol.webdav)['url'] ??
                    'Not set'),
                // enabled: Prefs().webdavStatus,
                onPressed: (context) async {
                  showWebdavDialog(context);
                }),
            SettingsTile.navigation(
                title: Text(L10n.of(context).settingsSyncWebdavSyncNow),
                leading: const Icon(Icons.sync_alt),
                // value: Text(Prefs().syncDirection),
                enabled: Prefs().webdavStatus,
                onPressed: (context) {
                  chooseDirection(ref);
                }),
            SettingsTile.switchTile(
                title: Text(L10n.of(context).webdavOnlyWifi),
                leading: const Icon(Icons.wifi),
                initialValue: Prefs().onlySyncWhenWifi,
                onToggle: (bool value) {
                  setState(() {
                    Prefs().onlySyncWhenWifi = value;
                  });
                }),
            SettingsTile.switchTile(
                title: Text(L10n.of(context).settingsSyncCompletedToast),
                leading: const Icon(Icons.notifications),
                initialValue: Prefs().syncCompletedToast,
                onToggle: (bool value) {
                  setState(() {
                    Prefs().syncCompletedToast = value;
                  });
                }),
            SettingsTile.switchTile(
                title: Text(L10n.of(context).settingsSyncAutoSync),
                leading: const Icon(Icons.sync),
                initialValue: Prefs().autoSync,
                enabled: Prefs().webdavStatus,
                onToggle: (bool value) {
                  setState(() {
                    Prefs().autoSync = value;
                  });
                }),
            SettingsTile.navigation(
                title: Text(L10n.of(context).restoreBackup),
                leading: const Icon(Icons.restore),
                onPressed: (context) {
                  ref.read(syncProvider.notifier).showBackupManagementDialog();
                })
          ],
        ),
      ],
    );
  }

}

void showWebdavDialog(BuildContext context) {
  final l10n = L10n.of(context);
  final webdavInfo = Prefs().getSyncInfo(SyncProtocol.webdav);
  final url = TextEditingController(text: webdavInfo['url']);
  final username = TextEditingController(text: webdavInfo['username']);
  final password = TextEditingController(text: webdavInfo['password']);

  Widget field(BuildContext context, String label, TextEditingController controller,
      {String? hint, bool obscure = false, TextInputType? keyboard}) {
    final palette = MgPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(label, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
          ),
          TextField(
            controller: controller,
            obscureText: obscure,
            keyboardType: keyboard,
            autocorrect: false,
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              hintText: hint,
              isDense: true,
              filled: true,
              fillColor: mgSheetGroupColor(context),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
            ),
          ),
        ],
      ),
    );
  }

  showMgSheet(
    context: context,
    title: l10n.settingsSyncWebdav,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field(context, l10n.settingsSyncWebdavUrl, url,
              hint: 'https://dav.example.com/dav/', keyboard: TextInputType.url),
          field(context, l10n.settingsSyncWebdavUsername, username),
          field(context, l10n.settingsSyncWebdavPassword, password, obscure: true),
        ],
      ),
    ),
    footer: (context) => MgSheetButtons(
      secondary: l10n.settingsSyncWebdavTestConnection,
      onSecondary: () => SyncTestHelper.handleFullTestConnection(
        context,
        protocol: SyncProtocol.webdav,
        config: {'url': url.text.trim(), 'username': username.text, 'password': password.text},
      ),
      primary: l10n.commonSave,
      onPrimary: () {
        webdavInfo['url'] = url.text.trim();
        webdavInfo['username'] = username.text;
        webdavInfo['password'] = password.text;
        Prefs().setSyncInfo(SyncProtocol.webdav, webdavInfo);
        SyncClientFactory.initializeCurrentClient();
        Navigator.pop(context);
      },
    ),
  );
}
