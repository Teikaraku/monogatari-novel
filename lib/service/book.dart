import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/theme.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/current_reading_state.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/iap_page.dart';
import 'package:anx_reader/providers/ai_chat.dart';
import 'package:anx_reader/providers/chapter_content_bridge.dart';
import 'package:anx_reader/providers/current_reading.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/providers/iap.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/toc_search.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/bookstore/store_library.dart';
import 'package:anx_reader/service/convert_to_epub/txt/convert_from_txt.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/utils/webView/anx_headless_webview.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:file_picker/file_picker.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/utils/import_book.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/utils/webView/gererate_url.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

import 'book_player/book_player_server.dart';

AnxHeadlessWebView? headlessInAppWebView;
final allowBookExtensions = ["epub", "mobi", "azw3", "fb2", "txt", "pdf"];

/// Copies a file into the temp directory for [importBookList], which consumes it.
Future<File> stageImportFile(String sourcePath, String fileName) async {
  final target = File(path.join((await getAnxTempDir()).path, fileName));
  if (await target.exists()) await target.delete();
  return File(sourcePath).copy(target.path);
}

/// Picks book files and imports them. Android hands out temporary copies already; other
/// platforms return the originals, which are copied so the import can consume them.
Future<void> pickAndImportBooks(BuildContext context, WidgetRef ref) async {
  FilePickerResult? result;
  try {
    result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: true);
  } catch (e) {
    if (context.mounted) AnxToast.show(L10n.of(context).filePickerFailed(e.toString()));
    return;
  }
  if (result == null || !context.mounted) return;
  AnxLog.info('importBook files: ${result.files}');
  final picked = result.files.where((file) => file.path != null).toList();
  final files = AnxPlatform.isAndroid
      ? picked.map((file) => File(file.path!)).toList()
      : await Future.wait(picked.map((file) => stageImportFile(file.path!, file.name)));
  if (!context.mounted || files.isEmpty) return;
  importBookList(files, context, ref);
}

/// Imports staged files (they are deleted afterwards) in a progress sheet: duplicates are
/// found by MD5 first; without any the import starts at once and the sheet closes itself.
void importBookList(List<File> fileList, BuildContext context, WidgetRef ref) {
  AnxLog.info('importBook fileList: $fileList');
  showModalBottomSheet(
    context: navigatorKey.currentContext!,
    isScrollControlled: true,
    useSafeArea: true,
    isDismissible: false,
    enableDrag: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => _ImportSheet(files: fileList, ref: ref),
  );
}

enum _ImportStatus { pending, duplicate, unsupported, working, done, failed }

class _ImportEntry {
  _ImportEntry(this.file, this.status);

  final File file;
  _ImportStatus status;
  String? duplicateOf;
  String? error;

  String get name => path.basename(file.path);
}

enum _ImportPhase { checking, ready, importing, finished }

class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.files, required this.ref});

  final List<File> files;
  final WidgetRef ref;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  late final List<_ImportEntry> _entries = [
    for (final file in widget.files)
      _ImportEntry(
        file,
        allowBookExtensions.contains(file.path.split('.').last.toLowerCase())
            ? _ImportStatus.pending
            : _ImportStatus.unsupported,
      ),
  ];
  _ImportPhase _phase = _ImportPhase.checking;
  bool _skipDuplicates = true;
  int _imported = 0;
  int _processed = 0;
  int _total = 0;

  Iterable<_ImportEntry> get _duplicates => _entries.where((e) => e.duplicateOf != null);

  List<_ImportEntry> get _queue => [
        for (final entry in _entries)
          if (entry.status == _ImportStatus.pending || (entry.status == _ImportStatus.duplicate && !_skipDuplicates))
            entry,
      ];

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    for (final entry in _entries.where((e) => e.status == _ImportStatus.unsupported)) {
      _deleteQuietly(entry.file);
    }
    final candidates = _entries.where((e) => e.status == _ImportStatus.pending).toList();
    try {
      final results = await MD5Service.checkImportFiles(candidates.map((e) => e.file.path).toList());
      for (var i = 0; i < candidates.length; i++) {
        if (results[i].isDuplicate && results[i].duplicateBook != null) {
          candidates[i]
            ..status = _ImportStatus.duplicate
            ..duplicateOf = results[i].duplicateBook!.title;
        }
      }
    } catch (e) {
      AnxLog.severe('MD5 check failed: $e');
    }
    if (!mounted) return;
    setState(() => _phase = _ImportPhase.ready);
    if (_duplicates.isEmpty && _queue.isNotEmpty) _import();
  }

  Future<void> _import() async {
    final queue = _queue;
    setState(() {
      _phase = _ImportPhase.importing;
      _total = queue.length;
    });
    for (final entry in queue) {
      setState(() => entry.status = _ImportStatus.working);
      try {
        await importBook(entry.file, widget.ref);
        _imported++;
        entry.status = _ImportStatus.done;
      } catch (e, stack) {
        AnxLog.severe('Failed to import ${entry.file.path}: $e\n$stack');
        entry
          ..status = _ImportStatus.failed
          ..error = e.toString();
      }
      _processed++;
      if (mounted) setState(() {});
    }
    if (_skipDuplicates) {
      for (final entry in _entries.where((e) => e.status == _ImportStatus.duplicate)) {
        _deleteQuietly(entry.file);
      }
    }
    widget.ref.read(syncProvider.notifier).syncData(SyncDirection.upload, widget.ref, trigger: SyncTrigger.auto);
    if (!mounted) return;
    setState(() => _phase = _ImportPhase.finished);
    if (_entries.every((e) => e.status != _ImportStatus.failed && e.status != _ImportStatus.unsupported)) {
      await Future.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;
      AnxToast.show(L10n.of(context).importDone(_imported));
      Navigator.of(context).pop();
    }
  }

  void _cancel() {
    for (final entry in _entries) {
      if (entry.status == _ImportStatus.pending || entry.status == _ImportStatus.duplicate) {
        _deleteQuietly(entry.file);
      }
    }
    Navigator.of(context).pop();
  }

  void _deleteQuietly(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  Widget _footer(L10n l10n) {
    return switch (_phase) {
      _ImportPhase.checking => MgSheetButtons(primary: l10n.importChecking, onPrimary: null),
      _ImportPhase.ready => MgSheetButtons(
          secondary: l10n.commonCancel,
          onSecondary: _cancel,
          primary: l10n.importImportNBooks(_queue.length),
          onPrimary: _queue.isEmpty ? null : _import,
        ),
      _ImportPhase.importing =>
        MgSheetButtons(primary: l10n.importProgress(min(_processed + 1, _total), _total), onPrimary: null),
      _ImportPhase.finished => MgSheetButtons(primary: l10n.importFinish, onPrimary: () => Navigator.of(context).pop()),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;

    Widget statusIcon(_ImportStatus status) => switch (status) {
          _ImportStatus.working =>
            const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          _ImportStatus.done => Icon(Icons.check_circle, size: 20, color: scheme.primary),
          _ImportStatus.failed || _ImportStatus.unsupported => Icon(Icons.error_outline, size: 20, color: scheme.error),
          _ImportStatus.duplicate => Icon(Icons.copy_all_outlined, size: 20, color: palette.secondaryLabel),
          _ImportStatus.pending => Icon(Icons.radio_button_unchecked, size: 20, color: palette.separator),
        };

    String? subtitle(_ImportEntry entry) => switch (entry.status) {
          _ImportStatus.unsupported => l10n.importUnsupported,
          _ImportStatus.failed => l10n.importFailedShort,
          _ when entry.duplicateOf != null => l10n.duplicateOf(entry.duplicateOf!),
          _ => null,
        };

    return MgSheet(
      title: l10n.importSheetTitle(widget.files.length),
      footer: _footer(l10n),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_duplicates.isNotEmpty && _phase == _ImportPhase.ready) ...[
            MgSheetGroup(children: [
              MgSwitchRow(
                title: l10n.skipDuplicateFiles,
                value: _skipDuplicates,
                onChanged: (value) => setState(() => _skipDuplicates = value),
              ),
            ]),
            const SizedBox(height: 12),
          ],
          MgSheetGroup(children: [
            for (final entry in _entries)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    SizedBox(width: 22, child: Center(child: statusIcon(entry.status))),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
                          if (subtitle(entry) case final text?)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                text,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: entry.status == _ImportStatus.failed || entry.status == _ImportStatus.unsupported
                                      ? scheme.error
                                      : palette.secondaryLabel,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ]),
        ],
      ),
    );
  }
}

Future<void> importBook(File file, WidgetRef ref) async {
  String? md5 = await MD5Service.calculateFileMd5(file.path);

  if (file.path.split('.').last == 'txt') {
    final tempFile = await convertFromTxt(file);
    file.deleteSync();
    file = tempFile;
  }

  await getBookMetadata(file, md5: md5, ref: ref);
  ref.read(bookListProvider.notifier).refresh();
}

const readingRouteName = '/reading';

/// Only one reader exists at a time (its keys are global). Opening a book from a page above the
/// reader, such as another volume from its details page, first closes it; the same book with no
/// target just returns to it. Returns true when the open reader was kept.
Future<bool> _settleOpenReader(Book book, {required bool hasTarget}) async {
  final open = readingPageKey.currentState;
  if (open == null) return false;
  final navigator = navigatorKey.currentState!;
  navigator.popUntil((route) => route.settings.name == readingRouteName || route.isFirst);
  if (open.widget.book.id == book.id && !hasTarget) return true;
  if (readingPageKey.currentState == null) return false;
  navigator.pop();
  // The reader stays in the tree through its exit transition; wait until it is gone.
  for (var i = 0; i < 40 && readingPageKey.currentState != null; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return false;
}

bool? _hasWebView;

/// The reader is a WebView. Some Android phones have the system WebView disabled or missing, and
/// opening the reader there would leave a blank page, so this is checked once before the first book.
Future<bool> _webViewAvailable() async {
  if (!Platform.isAndroid) return true;
  if (_hasWebView == true) return true;
  try {
    _hasWebView = await InAppWebViewController.getCurrentWebViewPackage() != null;
  } catch (e) {
    AnxLog.warning('Reader: could not check the system WebView: $e');
    return true;
  }
  return _hasWebView!;
}

Future<void> pushToReadingPage(
  WidgetRef ref,
  BuildContext context,
  Book book, {
  String? cfi,
  String? href,
  String? heroTag,
}) async {
  final container = ProviderScope.containerOf(context, listen: false);
  if (book.isDeleted) {
    AnxToast.show(L10n.of(context).bookDeleted);
    return;
  }

  if (!File(book.fileFullPath).existsSync()) {
    if (book.storeKey != null) {
      await StoreLibrary.instance.reopen(ref, context, book);
      return;
    }
    ref.read(syncProvider.notifier).downloadBook(book);
    return;
  }

  if (EnvVar.enableInAppPurchase) {
    final iapAsync = ref.read(iapProvider);
    final isFeatureAvailable = iapAsync.maybeWhen(
      data: (state) => state.isFeatureAvailable,
      orElse: () => ref.read(iapProvider.notifier).cachedFeatureAvailable(),
    );

    if (!isFeatureAvailable) {
      Navigator.of(context).push(
        CupertinoPageRoute(
          builder: (context) => const IAPPage(),
        ),
      );
      return;
    }
  }
  if (!await _webViewAvailable()) {
    if (context.mounted) AnxToast.show(L10n.of(context).mgWebViewMissing);
    return;
  }
  if (await _settleOpenReader(book, hasTarget: cfi != null || href != null)) return;
  final storeKey = book.storeKey;
  if (storeKey != null) unawaited(StoreLibrary.instance.reportRead(storeKey.split('/').first));
  container.read(aiChatProvider.notifier).clear();
  final initialThemes = await themeDao.selectThemes();
  container.read(currentReadingProvider.notifier).start(
        CurrentReadingState(
          book: book,
          cfi: cfi,
        ),
      );

  final currentReading = container.read(currentReadingProvider.notifier);
  final chapterContentBridge = container.read(chapterContentBridgeProvider.notifier);
  final tocSearch = container.read(tocSearchProvider.notifier);

  await Navigator.push(
    navigatorKey.currentContext!,
    CupertinoPageRoute(
      settings: const RouteSettings(name: readingRouteName),
      builder: (c) => ReadingPage(
        key: readingPageKey,
        book: book,
        cfi: cfi,
        href: href,
        initialThemes: initialThemes,
        heroTag: heroTag,
      ),
    ),
  ).then((_) {
    AnxLog.info('ReadingPage: poped: ${book.title}');
    currentReading.finish();
    chapterContentBridge.state = null;
    tocSearch.clear();
    refreshStoreHomeIfStale(container.read(storeHomeRefreshProvider.notifier));
    AnxLog.info('Pop successfully ReadingPage: ${book.title}');
  });
}

void updateBookRating(Book book, double rating) {
  book.rating = rating;
  bookDao.updateBook(book);
}

Future<void> resetBookCover(Book book) async {
  File file = File(book.fileFullPath);
  getBookMetadata(file);
}

Future<void> saveBook(
  File file,
  String title,
  String author,
  String description,
  String? md5,
  String cover, {
  Book? provideBook,
}) async {
  // Extract original filename (without extension)
  final fileNameWithoutExt = path.basenameWithoutExtension(file.path);

  // Use original filename if title is invalid
  final effectiveTitle =
      (title == 'Unknown' || title.trim().isEmpty) ? fileNameWithoutExt : title;

  final newBookName =
      '${effectiveTitle.length > 20 ? effectiveTitle.substring(0, 20) : effectiveTitle}-${DateTime.now().millisecondsSinceEpoch}'
          // Strip characters that some WebDAV servers (e.g. Jianguoyun) reject (#989)
          .replaceAll(RegExp(r'[<>:"/\\|?*#%&@$^+=\[\]{}`~;!]'), '_')
          .replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '')
          .trim();

  final extension = file.path.split('.').last;

  final dbFilePath = 'file/$newBookName.$extension';
  final filePath = getBasePath(dbFilePath);
  String? dbCoverPath = 'cover/$newBookName';
  // final coverPath = getBasePath(dbCoverPath);

  await file.copy(filePath);
  // remove cached file
  file.delete();

  dbCoverPath = await saveImageToLocal(cover, dbCoverPath);
  if (md5 != null) {
    provideBook ??= await bookDao.getBookByMd5(md5);
  }

  Book book = Book(
      id: provideBook != null ? provideBook.id : -1,
      title: provideBook?.title ?? effectiveTitle,
      coverPath: dbCoverPath,
      filePath: dbFilePath,
      lastReadPosition: provideBook?.lastReadPosition ?? '',
      readingPercentage: provideBook?.readingPercentage ?? 0,
      author: provideBook?.author ?? author,
      isDeleted: false,
      rating: provideBook?.rating ?? 0.0,
      md5: md5,
      createTime: provideBook?.createTime ?? DateTime.now(),
      updateTime: DateTime.now());

  book.id = await bookDao.insertBook(book);
  AnxToast.show(L10n.of(navigatorKey.currentContext!).serviceImportSuccess);
  await headlessInAppWebView?.dispose();
  headlessInAppWebView = null;
  return;
}

Future<void> getBookMetadata(
  File file, {
  Book? book,
  String? md5,
  WidgetRef? ref,
}) async {
  String serverFileName = Server().setTempFile(file);

  String cfi = '';

  String bookUrl = "http://127.0.0.1:${Server().port}/$serverFileName";
  AnxLog.info("import start: book url: $bookUrl");

  final importUrl = generateUrl(
    bookUrl,
    cfi,
    importing: true,
  );

  AnxHeadlessWebView webview = AnxHeadlessWebView(
    webViewEnvironment: webViewEnvironment,
    initialUrl: importUrl,
    onLoadStop: (controller, url) async {
      controller.addJavaScriptHandler(
          handlerName: 'onMetadata',
          callback: (args) async {
            Map<String, dynamic> metadata = args[0];
            String title = metadata['title'] ?? 'Unknown';
            dynamic authorData = metadata['author'];
            String author = authorData is String
                ? authorData
                : authorData
                        ?.map((author) =>
                            author is String ? author : author['name'])
                        ?.join(', ') ??
                    'Unknown';

            // base64 cover
            String cover = metadata['cover'] ?? '';
            String description = metadata['description'] ?? '';
            saveBook(
              file,
              title,
              author,
              description,
              md5,
              cover,
              provideBook: book,
            );
            ref?.read(bookListProvider.notifier).refresh();
          });
    },
    onConsoleMessage: (controller, message, {required isError}) {
      if (isError) {
        headlessInAppWebView?.dispose();
        headlessInAppWebView = null;
        throw Exception('Webview: $message');
      }
      AnxLog.info('Webview: $message');
    },
  );

  await webview.run();
  headlessInAppWebView = webview;
  // max 30s
  int count = 0;
  while (count < 300) {
    if (headlessInAppWebView == null) {
      return;
    }
    await Future.delayed(const Duration(milliseconds: 100));
    count++;
  }
  await headlessInAppWebView?.dispose();
  headlessInAppWebView = null;
  throw Exception('Import: Get book metadata timeout');
}
