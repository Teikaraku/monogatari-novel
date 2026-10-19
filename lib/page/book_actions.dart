import 'dart:io';
import 'dart:math';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/enums/hint_key.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/page/book_detail.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/providers/sync_status.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/convert_to_epub/txt/convert_from_txt.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/share_file.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/common/tag_editor_sheet.dart';
import 'package:file_picker/file_picker.dart';
import 'package:anx_reader/page/bookstore/store_detail_page.dart';
import 'package:anx_reader/service/bookstore/store_library.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

/// Actions on imported books. Bookstore volumes never reach these: they are read-only.

String formatFileSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
  final i = min((log(bytes) / log(1024)).floor(), suffixes.length - 1);
  final value = bytes / pow(1024, i);
  return '${value.toStringAsFixed(i == 0 ? 0 : 1)} ${suffixes[i]}';
}

Future<void> shareLocalBook(Book book) => shareFile(
      title: '${book.title}.${book.filePath.split('.').last}',
      filePath: book.fileFullPath,
    );

/// Asks for confirmation in a sheet; true when the user confirmed.
Future<bool> confirmMgAction(
  BuildContext context, {
  required String title,
  String? message,
  Widget? body,
  required String confirm,
}) async {
  final l10n = L10n.of(context);
  final result = await showMgSheet<bool>(
    context: context,
    title: title,
    builder: (context) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: body ??
          Text(message ?? '', style: TextStyle(fontSize: 15, height: 1.5, color: MgPalette.of(context).secondaryLabel)),
    ),
    footer: (context) => MgSheetButtons(
      secondary: l10n.commonCancel,
      onSecondary: () => Navigator.of(context).pop(false),
      primary: confirm,
      onPrimary: () => Navigator.of(context).pop(true),
    ),
  );
  return result == true;
}

/// Confirms, then removes the book from the shelf and deletes its files. Notes stay in the database.
Future<bool> deleteLocalBook(BuildContext context, WidgetRef ref, Book book) async {
  final l10n = L10n.of(context);
  final confirmed = await confirmMgAction(
    context,
    title: l10n.bookDeleteTitle(book.title),
    message: l10n.bookDeleteMessage,
    confirm: l10n.commonDelete,
  );
  if (!confirmed) return false;
  await bookDao.updateBook(book.copyWith(isDeleted: true, updateTime: DateTime.now()));
  ref.read(bookListProvider.notifier).refresh();
  for (final path in [book.fileFullPath, book.coverFullPath]) {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
  return true;
}

/// Replaces the book file with another one, keeping progress, notes and metadata.
Future<bool> replaceLocalBookFile(BuildContext context, WidgetRef ref, Book book) async {
  final l10n = L10n.of(context);
  FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
  } catch (e) {
    if (context.mounted) AnxToast.show(l10n.filePickerFailed(e.toString()));
    return false;
  }
  if (result == null || result.files.single.path == null) return false;
  final picked = result.files.single;
  final extension = p.extension(picked.name).replaceAll('.', '').toLowerCase();
  if (!allowBookExtensions.contains(extension)) {
    AnxToast.show(l10n.bookBottomSheetUnsupportedFileFormat(extension));
    return false;
  }
  final source = File(picked.path!);
  final newSize = await source.length();
  final oldFile = File(book.fileFullPath);
  final oldSize = await oldFile.exists() ? await oldFile.length() : 0;
  if (!context.mounted) return false;

  final palette = MgPalette.of(context);
  final confirmed = await confirmMgAction(
    context,
    title: l10n.bookBottomSheetReplaceFile,
    confirm: l10n.commonConfirm,
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.bookBottomSheetOriginalFileSize(formatFileSize(oldSize)),
            style: TextStyle(fontSize: 15, color: palette.secondaryLabel)),
        const SizedBox(height: 2),
        Text(l10n.bookBottomSheetNewFileSize(formatFileSize(newSize)),
            style: TextStyle(fontSize: 15, color: palette.secondaryLabel)),
        const SizedBox(height: 10),
        Text(l10n.bookBottomSheetReplaceWarning,
            style: TextStyle(fontSize: 14, height: 1.5, color: Theme.of(context).colorScheme.error)),
      ],
    ),
  );
  if (!confirmed) return false;

  try {
    var newExtension = p.extension(picked.name);
    var file = source;
    if (newExtension.toLowerCase() == '.txt') {
      file = await convertFromTxt(source);
      newExtension = '.epub';
    }
    final title = book.title;
    final name = '${title.length > 20 ? title.substring(0, 20) : title}-${DateTime.now().millisecondsSinceEpoch}'
        .replaceAll(RegExp(r'[<>:"/\\|?*\r\n]'), '_')
        .trim();
    final relative = 'file/$name$newExtension';
    final destination = getBasePath(relative);
    await file.copy(destination);
    final md5 = await MD5Service.calculateFileMd5(destination);
    await bookDao.updateBook(book.copyWith(filePath: relative, md5: md5, updateTime: DateTime.now()));
    if (book.fileFullPath != destination && await oldFile.exists()) await oldFile.delete();
    if (file != source && await file.exists()) await file.delete();
    book.filePath = relative;
    book.md5 = md5;
    ref.read(bookListProvider.notifier).refresh();
    if (Prefs().webdavStatus) {
      ref.read(syncProvider.notifier).syncData(SyncDirection.upload, ref);
    }
    return true;
  } catch (e) {
    AnxToast.show(l10n.bookBottomSheetReplaceFailed(e.toString()));
    return false;
  }
}

/// Uploads the book to WebDAV and deletes the local copy; it downloads again on open.
Future<void> releaseLocalBookSpace(BuildContext context, WidgetRef ref, Book book) async {
  Future<void> release() async {
    await ref.read(syncProvider.notifier).releaseBook(book);
    ref.read(syncStatusProvider.notifier).refresh();
  }

  if (!Prefs().shouldShowHint(HintKey.releaseLocalSpace)) {
    await release();
    return;
  }
  final l10n = L10n.of(context);
  final confirmed = await confirmMgAction(
    context,
    title: l10n.bookSyncStatusReleaseSpaceDialogTitle,
    message: l10n.bookSyncStatusReleaseSpaceDialogContent,
    confirm: l10n.bookSyncStatusReleaseSpace,
  );
  if (!confirmed) return;
  Prefs().setShowHint(HintKey.releaseLocalSpace, false);
  await release();
}

/// The long-press sheet of an imported book on the shelf.
class BookBottomSheet extends ConsumerWidget {
  const BookBottomSheet({super.key, required this.book});

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    final percent = (book.readingPercentage * 100).round();
    final subtitle = [
      if (book.author.isNotEmpty) book.author,
      percent > 0 ? '$percent%' : l10n.bookInfoNotStarted,
    ].join(' · ');
    final navigator = Navigator.of(context);

    // Each action closes the sheet first and runs against the page underneath.
    void run(Future<void> Function(BuildContext page) action) {
      final page = navigator.context;
      navigator.pop();
      action(page);
    }

    return MgSheet(
      title: book.title,
      subtitle: subtitle,
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            MgSheetGroup(children: [
              MgSheetAction(
                title: percent > 0 ? l10n.storeContinueReading : l10n.storeStartReading,
                icon: Icons.menu_book_outlined,
                onTap: () => run((page) => pushToReadingPage(ref, page, book)),
              ),
              MgSheetAction(
                title: l10n.bookInfoOpen,
                icon: Icons.info_outline,
                onTap: () => run((page) => openBookDetail(page, book)),
              ),
            ]),
            const SizedBox(height: 12),
            MgSheetGroup(children: [
              MgSheetAction(
                title: l10n.shareFile,
                icon: Icons.ios_share,
                onTap: () => run((_) => shareLocalBook(book)),
              ),
              MgSheetAction(
                title: l10n.bookBottomSheetReplaceFile,
                icon: Icons.swap_horiz,
                onTap: () => run((page) => replaceLocalBookFile(page, ref, book)),
              ),
              if (Prefs().webdavStatus)
                MgSheetAction(
                  title: l10n.bookSyncStatusReleaseSpace,
                  icon: Icons.cloud_upload_outlined,
                  onTap: () => run((page) => releaseLocalBookSpace(page, ref, book)),
                ),
            ]),
            const SizedBox(height: 12),
            MgSheetGroup(children: [
              MgSheetAction(
                title: l10n.commonDelete,
                icon: Icons.delete_outline,
                destructive: true,
                onTap: () => run((page) => deleteLocalBook(page, ref, book)),
              ),
            ]),
          ],
        ),
      ),
    );
  }
}

Future<void> showBookActions(BuildContext context, Book book) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => BookBottomSheet(book: book),
    );

/// The long-press sheet of a bookstore series on the shelf. Store books are read-only, so it
/// offers reading, the store page, clearing downloads and removing from the shelf.
Future<void> showStoreBookActions(BuildContext context, StoreRecord record) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => _StoreBookSheet(record: record),
    );

class _StoreBookSheet extends ConsumerWidget {
  const _StoreBookSheet({required this.record});

  final StoreRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    final navigator = Navigator.of(context);
    final subtitle = [
      if (record.author.isNotEmpty) record.author,
      if (record.lastVolume != null) l10n.storeVolumeN(record.lastVolume!) else l10n.bookInfoNotStarted,
      if (record.volumes > 0) l10n.storeTotalVolumes(record.volumes),
    ].join(' · ');

    void run(Future<void> Function(BuildContext page) action) {
      final page = navigator.context;
      navigator.pop();
      action(page);
    }

    Future<void> openDetail(BuildContext page) => Navigator.of(page).push(CupertinoPageRoute(
          builder: (_) => StoreDetailPage(id: record.storeId, preview: record.toBook()),
        ));

    return MgSheet(
      title: record.title,
      subtitle: subtitle,
      child: Column(
        children: [
          MgSheetGroup(children: [
            MgSheetAction(
              title: record.lastVolume != null ? l10n.storeContinueReading : l10n.storeStartReading,
              icon: Icons.menu_book_outlined,
              onTap: () => run((page) async {
                final last = record.lastVolume;
                final row = last == null ? null : await bookDao.selectStoreVolume('${record.storeId}/$last');
                if (!page.mounted) return;
                if (row == null) {
                  await openDetail(page);
                } else {
                  await pushToReadingPage(ref, page, row);
                }
              }),
            ),
            MgSheetAction(title: l10n.bookInfoOpen, icon: Icons.info_outline, onTap: () => run(openDetail)),
            MgSheetAction(
              title: l10n.tagsSectionTitle,
              icon: Icons.sell_outlined,
              onTap: () => run((page) => showTagEditorSheet(
                    page,
                    binding: StoreTagBinding(record.storeId),
                    onChanged: () => ref.invalidate(storeTagMapProvider),
                  )),
            ),
          ]),
          const SizedBox(height: 12),
          MgSheetGroup(children: [
            MgSheetAction(
              title: l10n.storeClearDownloads,
              icon: Icons.cleaning_services_outlined,
              onTap: () => run((_) async {
                await StoreLibrary.instance.clearDownloads(record.storeId);
                AnxToast.show(l10n.storeCleared);
              }),
            ),
          ]),
          const SizedBox(height: 12),
          MgSheetGroup(children: [
            MgSheetAction(
              title: l10n.storeRemoveFromShelf,
              icon: Icons.bookmark_remove_outlined,
              destructive: true,
              onTap: () => run((_) => StoreLibrary.instance.toggleShelf(ref, record.toBook())),
            ),
          ]),
        ],
      ),
    );
  }
}
