import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/page/book_actions.dart';
import 'package:anx_reader/utils/get_path/databases_path.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/utils/save_file_to_download.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/show_loading.dart';
import 'package:archive/archive_io.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:path/path.dart' as path;

/// Full local backups: books, covers, fonts, backgrounds, the database and preferences in one
/// zip. Bookstore downloads are a cache and are not included.

const String _prefsBackupFileName = 'anx_shared_prefs.json';

L10n get _l10n => L10n.of(navigatorKey.currentContext!);

String _backupDate() {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}

/// Zips everything and lets the user save the archive.
Future<void> exportBackup() async {
  AnxLog.info('exportBackup: start');
  showLoading();
  try {
    final prefsBackupFile = await _createPrefsBackupFile();
    final token = RootIsolateToken.instance!;
    final zipPath = await compute(createZipFile, {
      'token': token,
      'prefsBackupFilePath': prefsBackupFile.path,
    });
    SmartDialog.dismiss();
    final file = File(zipPath);
    if (!await file.exists()) return;
    final saved = await saveFileToDownload(
      sourceFilePath: file.path,
      fileName: 'Monogatari-Backup-${_backupDate()}.zip',
      mimeType: 'application/zip',
    );
    await file.delete();
    if (saved != null) {
      AnxLog.info('exportBackup: saved to $saved');
      AnxToast.show(_l10n.exportTo(saved));
    } else {
      AnxToast.show(_l10n.commonCanceled);
    }
  } catch (e) {
    SmartDialog.dismiss();
    AnxLog.severe('exportBackup: $e');
    AnxToast.show(_l10n.importFailed(e.toString()));
  }
}

/// Picks a backup zip, confirms, and replaces the library, notes and settings with it.
Future<void> importBackup() async {
  AnxLog.info('importBackup: start');
  final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['zip']);
  final filePath = result?.files.single.path;
  if (result == null) return;
  if (filePath == null || !await File(filePath).exists()) {
    AnxToast.show(_l10n.importCannotGetFilePath);
    return;
  }
  final context = navigatorKey.currentContext!;
  if (!context.mounted) return;
  final confirmed = await confirmMgAction(
    context,
    title: _l10n.transferRestoreTitle,
    message: _l10n.transferRestoreMessage,
    confirm: _l10n.transferRestore,
  );
  if (!confirmed) return;

  showLoading();
  final separator = Platform.pathSeparator;
  final extractPath = '${(await getAnxTempDir()).path}${separator}anx_reader_import';
  try {
    await Directory(extractPath).create(recursive: true);
    await compute(extractZipFile, {'zipFilePath': filePath, 'destinationPath': extractPath});

    final docPath = await getAnxDocumentsPath();
    _copyDirectorySync(Directory('$extractPath${separator}file'), getFileDir(path: docPath));
    _copyDirectorySync(Directory('$extractPath${separator}cover'), getCoverDir(path: docPath));
    _copyDirectorySync(Directory('$extractPath${separator}font'), getFontDir(path: docPath));
    _copyDirectorySync(Directory('$extractPath${separator}bgimg'), getBgimgDir(path: docPath));

    DBHelper.close();
    _copyDirectorySync(Directory('$extractPath${separator}databases'), await getAnxDataBasesDir());
    DBHelper().initDB();

    await _restorePrefsFromBackup(extractPath);
    AnxLog.info('importBackup: success');
    AnxToast.show(_l10n.importSuccessRestartApp);
  } catch (e) {
    AnxLog.info('importBackup: failed: $e');
    AnxToast.show(_l10n.importFailed(e.toString()));
  } finally {
    SmartDialog.dismiss();
    final dir = Directory(extractPath);
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

void _copyDirectorySync(Directory source, Directory destination) {
  if (!source.existsSync()) return;
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  destination.createSync(recursive: true);
  for (final entity in source.listSync(recursive: false)) {
    final newPath = destination.path + Platform.pathSeparator + path.basename(entity.path);
    if (entity is File) {
      entity.copySync(newPath);
    } else if (entity is Directory) {
      _copyDirectorySync(entity, Directory(newPath));
    }
  }
}

Future<String> createZipFile(Map<String, dynamic> params) async {
  final RootIsolateToken token = params['token'];
  final prefsBackupFile = File(params['prefsBackupFilePath'] as String);
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  final zipPath = '${(await getAnxTempDir()).path}/Monogatari-Backup-${_backupDate()}.zip';
  final docPath = await getAnxDocumentsPath();
  final directoryList = [
    getFileDir(path: docPath),
    getCoverDir(path: docPath),
    getFontDir(path: docPath),
    getBgimgDir(path: docPath),
    if (!AnxPlatform.isOhos) await getAnxDataBasesDir(),
    prefsBackupFile,
  ];
  AnxLog.info('exportBackup: directoryList: $directoryList');

  final encoder = ZipFileEncoder();
  encoder.create(zipPath);
  if (AnxPlatform.isOhos) {
    final dbFile = File('${(await getAnxDataBasesDir()).path}/app_database.db');
    if (await dbFile.exists()) await encoder.addFile(dbFile, 'databases/app_database.db');
  } else {
    await encoder.addDirectory(await getAnxDataBasesDir());
  }
  for (final entry in directoryList) {
    if (entry is Directory) {
      await encoder.addDirectory(entry);
    } else if (entry is File) {
      await encoder.addFile(entry);
    }
  }
  encoder.close();
  if (await prefsBackupFile.exists()) await prefsBackupFile.delete();
  return zipPath;
}

Future<void> extractZipFile(Map<String, String> params) async {
  final input = InputFileStream(params['zipFilePath']!);
  try {
    final archive = ZipDecoder().decodeBuffer(input);
    extractArchiveToDiskSync(archive, params['destinationPath']!);
    archive.clearSync();
  } finally {
    await input.close();
  }
}

Future<File> _createPrefsBackupFile() async {
  final backupFile = File('${(await getAnxTempDir()).path}/$_prefsBackupFileName');
  await backupFile.writeAsString(jsonEncode(await Prefs().buildPrefsBackupMap()));
  return backupFile;
}

Future<bool> _restorePrefsFromBackup(String extractPath) async {
  final backupFile = File('$extractPath/$_prefsBackupFileName');
  if (!await backupFile.exists()) return false;
  try {
    final decoded = jsonDecode(await backupFile.readAsString());
    if (decoded is Map<String, dynamic>) {
      await Prefs().applyPrefsBackupMap(decoded);
      return true;
    }
    AnxLog.info('importBackup: prefs backup has unexpected format');
  } catch (e) {
    AnxLog.info('importBackup: failed to restore prefs: $e');
  }
  return false;
}
