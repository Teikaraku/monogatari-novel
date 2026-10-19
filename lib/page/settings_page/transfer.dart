import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/home_page/notes_page.dart';
import 'package:anx_reader/page/settings_page/settings_page.dart';
import 'package:anx_reader/page/settings_page/sync.dart';
import 'package:anx_reader/service/backup.dart';
import 'package:anx_reader/page/settings_page/wifi_transfer_page.dart';
import 'package:anx_reader/service/notes/export_all_notes.dart';
import 'package:anx_reader/utils/save_file_to_download.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/show_loading.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as p;
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/widgets/settings/settings_section.dart';
import 'package:anx_reader/widgets/settings/settings_tile.dart';
import 'package:anx_reader/widgets/settings/settings_title.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// One place for moving data in and out: book files, notes, full backups and cloud sync.
class TransferSettings extends ConsumerStatefulWidget {
  const TransferSettings({super.key});

  @override
  ConsumerState<TransferSettings> createState() => _TransferSettingsState();
}

class _TransferSettingsState extends ConsumerState<TransferSettings> {
  Future<void> _exportAllNotes() async {
    final l10n = L10n.of(context);
    final format = await showMgSheet<AllNotesFormat>(
      context: context,
      title: l10n.transferExportAll,
      builder: (sheet) => MgSheetGroup(children: [
        MgSheetOption(
          title: 'Markdown',
          selected: false,
          onTap: () => Navigator.of(sheet).pop(AllNotesFormat.markdown),
        ),
        MgSheetOption(
          title: l10n.notesPlainText,
          selected: false,
          onTap: () => Navigator.of(sheet).pop(AllNotesFormat.txt),
        ),
      ]),
    );
    if (format == null) return;
    showLoading();
    try {
      final zip = await exportAllNotesZip(format: format);
      SmartDialog.dismiss();
      final saved = await saveFileToDownload(
        sourceFilePath: zip.path,
        fileName: p.basename(zip.path),
        mimeType: 'application/zip',
      );
      if (await zip.exists()) await zip.delete();
      AnxToast.show(saved == null ? l10n.commonCanceled : l10n.exportTo(saved));
    } on StateError {
      SmartDialog.dismiss();
      AnxToast.show(l10n.notesEmptyTitle);
    } catch (e) {
      SmartDialog.dismiss();
      AnxToast.show(l10n.importFailed(e.toString()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return settingsSections(sections: [
      SettingsSection(
        title: Text(l10n.transferBooks),
        tiles: [
          SettingsTile.navigation(
            leading: const Icon(Icons.file_open_outlined),
            title: Text(l10n.transferImportBooks),
            value: const Text('EPUB · MOBI · AZW3 · FB2 · TXT · PDF'),
            onPressed: (context) => pickAndImportBooks(context, ref),
          ),
          SettingsTile.navigation(
            leading: const Icon(Icons.wifi),
            title: Text(l10n.transferWifi),
            onPressed: (context) => Navigator.of(context).push(CupertinoPageRoute(
              builder: (_) => const WifiTransferPage(),
            )),
          ),
        ],
      ),
      SettingsSection(
        title: Text(l10n.notes),
        tiles: [
          SettingsTile.navigation(
            leading: const Icon(Icons.folder_zip_outlined),
            title: Text(l10n.transferExportAll),
            onPressed: (_) => _exportAllNotes(),
          ),
          SettingsTile.navigation(
            leading: const Icon(Icons.sticky_note_2_outlined),
            title: Text(l10n.transferExportByBook),
            onPressed: (context) => Navigator.of(context).push(CupertinoPageRoute(
              builder: (_) => MgSubPage(title: l10n.navBarNotes, grouped: false, body: const NotesPage()),
            )),
          ),
        ],
      ),
      SettingsSection(
        title: Text(l10n.transferBackup),
        tiles: [
          SettingsTile.navigation(
            leading: const Icon(Icons.archive_outlined),
            title: Text(l10n.transferCreateBackup),
            onPressed: (_) => exportBackup(),
          ),
          SettingsTile.navigation(
            leading: const Icon(Icons.settings_backup_restore),
            title: Text(l10n.transferRestoreBackup),
            onPressed: (_) => importBackup(),
          ),
        ],
      ),
      SettingsSection(
        title: Text(l10n.transferCloudSync),
        tiles: [
          SettingsTile.navigation(
            leading: const Icon(Icons.cloud_sync_outlined),
            title: Text(l10n.settingsSyncWebdav),
            value: Text(Prefs().webdavStatus ? l10n.transferOn : l10n.transferOff),
            onPressed: (context) async {
              await Navigator.of(context).push(CupertinoPageRoute(
                builder: (_) => SettingsPageBody(title: l10n.settingsSync, isMobile: true, sections: const SyncSetting()),
              ));
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    ]);
  }
}
