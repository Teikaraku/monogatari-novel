import 'dart:async';
import 'dart:io';

import 'dart:math';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/dao/store_book_tag.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/monogatari/theme.dart';
import 'package:anx_reader/page/home_page/history_page.dart';
import 'package:anx_reader/providers/shelf_order.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

/// A bookstore series the user opened or added to the shelf (row of tb_store_books).
class StoreRecord {
  const StoreRecord({
    required this.storeId,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.volumes,
    required this.inShelf,
    required this.shelfTime,
    required this.lastVolume,
    required this.lastReadTime,
    this.lastPercent = 0,
  });

  final String storeId;
  final String title;
  final String author;
  final String? coverUrl;
  final int volumes;
  final bool inShelf;
  final DateTime? shelfTime;
  final int? lastVolume;
  final DateTime? lastReadTime;

  /// How far into [lastVolume] the reader got.
  final double lastPercent;

  bool get opened => lastVolume != null;

  /// Caught up: the newest volume read to its end.
  bool get finished => lastVolume != null && lastVolume! >= volumes && lastPercent >= shelfFinishedAt;

  /// Share of the whole series read: finished volumes plus the current one's progress.
  double get progress =>
      lastVolume == null || volumes <= 0 ? 0 : ((lastVolume! - 1 + lastPercent) / volumes).clamp(0.0, 1.0);

  ShelfSortKey get sortKey {
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return ShelfSortKey(
      title: title,
      author: author,
      lastRead: lastReadTime ?? shelfTime ?? epoch,
      progress: progress,
      added: shelfTime ?? epoch,
    );
  }

  StoreRecord withPercent(double percent) => StoreRecord(
        storeId: storeId,
        title: title,
        author: author,
        coverUrl: coverUrl,
        volumes: volumes,
        inShelf: inShelf,
        shelfTime: shelfTime,
        lastVolume: lastVolume,
        lastReadTime: lastReadTime,
        lastPercent: percent,
      );

  factory StoreRecord.fromDb(Map<String, Object?> row) => StoreRecord(
        storeId: row['store_id'] as String,
        title: row['title'] as String? ?? '',
        author: row['author'] as String? ?? '',
        coverUrl: StoreConfig.configured ? row['cover_url'] as String? : null,
        volumes: row['volumes'] as int? ?? 0,
        inShelf: (row['in_shelf'] as int? ?? 0) == 1,
        shelfTime: DateTime.tryParse(row['shelf_time'] as String? ?? ''),
        lastVolume: row['last_volume'] as int?,
        lastReadTime: DateTime.tryParse(row['last_read_time'] as String? ?? ''),
      );

  StoreBook toBook() => StoreBook(
        id: storeId,
        title: title,
        author: author,
        status: StoreStatus.unknown,
        tags: const [],
        volumes: volumes,
        words: 0,
        updated: '',
        cover: StoreConfig.configured ? coverUrl : null,
        coverLarge: StoreConfig.configured ? coverUrl : null,
      );
}

/// Where the reader left a series: the volume and how far into it.
class StoreProgress {
  const StoreProgress(this.volume, this.percent);

  final int volume;
  final double percent;
}

/// Bookstore ids the user put on the shelf.
final storeShelfProvider = StateNotifierProvider<StoreShelfNotifier, Set<String>>(
  (ref) => StoreShelfNotifier()..load(),
);

class StoreShelfNotifier extends StateNotifier<Set<String>> {
  StoreShelfNotifier() : super(const {});

  Future<void> load() async {
    final db = await DBHelper().database;
    final rows = await db.query('tb_store_books', columns: ['store_id'], where: 'in_shelf = 1');
    state = {for (final row in rows) row['store_id'] as String};
  }
}

final storeProgressProvider = FutureProvider.autoDispose.family<StoreProgress?, String>((ref, id) async {
  final db = await DBHelper().database;
  final rows =
      await db.query('tb_store_books', columns: ['last_volume'], where: 'store_id = ?', whereArgs: [id], limit: 1);
  final volume = rows.isEmpty ? null : rows.first['last_volume'] as int?;
  if (volume == null) return null;
  final book = await bookDao.selectStoreVolume('$id/$volume');
  return StoreProgress(volume, book?.readingPercentage ?? 0);
});

/// Bookstore series on the shelf with how far into their last volume the reader got, in shelf order.
final storeShelfRecordsProvider = FutureProvider<List<StoreRecord>>((ref) async {
  ref.watch(storeShelfProvider);
  ref.watch(storeHistoryProvider);
  final db = await DBHelper().database;
  final rows = await db.rawQuery('''
    SELECT s.*, (SELECT b.reading_percentage FROM tb_books b
                 WHERE b.store_key = s.store_id || '/' || s.last_volume AND b.is_deleted = 0
                 LIMIT 1) AS last_percent
    FROM tb_store_books s
    WHERE s.in_shelf = 1
  ''');
  final records = [
    for (final row in rows) StoreRecord.fromDb(row).withPercent((row['last_percent'] as num?)?.toDouble() ?? 0),
  ];
  final keys = {for (final record in records) record.storeId: record.sortKey};
  return records..sort((a, b) => compareShelfKeys(keys[a.storeId]!, keys[b.storeId]!));
});

/// User tags on bookstore series, for the shelf's tag filter.
final storeTagMapProvider = FutureProvider<Map<String, List<int>>>((ref) => storeBookTagDao.storeIdToTagIds());

/// Series opened from the bookstore, most recent first, for the history tab.
final storeHistoryProvider = FutureProvider.autoDispose<List<StoreRecord>>((ref) async {
  final db = await DBHelper().database;
  final rows =
      await db.query('tb_store_books', where: 'last_read_time IS NOT NULL', orderBy: 'last_read_time DESC', limit: 300);
  return rows.map(StoreRecord.fromDb).toList();
});

/// Opens bookstore volumes without touching the shelf. Each opened volume is a hidden book row
/// (tagged with its store key) so progress, notes and reading time work as for any book; its EPUB
/// lives under `store/` as a cache that is never synced and is trimmed to [cacheLimit].
class StoreLibrary {
  StoreLibrary({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(minutes: 3),
            ));

  static final instance = StoreLibrary();

  static const cacheLimit = 2 * 1024 * 1024 * 1024;

  final Dio _dio;
  final _downloads = <String, Future<void>>{};

  String _volumePath(String storeId, int n, int mtime) => 'store/$storeId/$n-$mtime.epub';

  Future<void> _recordOpened(StoreBook book, int volumes, int n) async {
    final db = await DBHelper().database;
    final now = DateTime.now().toIso8601String();
    await db.rawInsert('''
      INSERT INTO tb_store_books (store_id, title, author, cover_url, volumes, in_shelf, last_volume, last_read_time)
      VALUES (?, ?, ?, ?, ?, 0, ?, ?)
      ON CONFLICT(store_id) DO UPDATE SET
        title = excluded.title, author = excluded.author, cover_url = excluded.cover_url,
        volumes = excluded.volumes, last_volume = excluded.last_volume,
        last_read_time = excluded.last_read_time
    ''', [book.id, book.title, book.author, book.coverLarge ?? book.cover, volumes, n, now]);
  }

  Future<void> toggleShelf(WidgetRef ref, StoreBook book) async {
    final db = await DBHelper().database;
    final inShelf = ref.read(storeShelfProvider).contains(book.id);
    final now = DateTime.now().toIso8601String();
    await db.rawInsert('''
      INSERT INTO tb_store_books (store_id, title, author, cover_url, volumes, in_shelf, shelf_time)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(store_id) DO UPDATE SET
        title = excluded.title, author = excluded.author, cover_url = excluded.cover_url,
        volumes = excluded.volumes, in_shelf = excluded.in_shelf, shelf_time = excluded.shelf_time
    ''', [
      book.id,
      book.title,
      book.author,
      book.coverLarge ?? book.cover,
      book.volumes,
      inShelf ? 0 : 1,
      inShelf ? null : now
    ]);
    await ref.read(storeShelfProvider.notifier).load();
    if (StoreConfig.configured) {
      unawaited(BookstoreApi.instance.reportShelf(book.id, added: !inShelf, install: _installId()));
    }
  }

  /// Counts this install as a reader of [storeId] today: once per book per day, so reopening a
  /// downloaded volume counts as reading too. Marked locally only after the event was sent.
  Future<void> reportRead(String storeId) async {
    if (!StoreConfig.configured) return;
    const key = 'mg.readReported';
    final today = DateTime.now().toIso8601String().substring(0, 10);
    bool reported(List<String>? saved) => saved != null && saved.isNotEmpty && saved.first == today && saved.contains(storeId);
    if (reported(Prefs().prefs.getStringList(key))) return;
    if (!await BookstoreApi.instance.reportRead(storeId, install: _installId())) return;
    final saved = Prefs().prefs.getStringList(key);
    final books = saved != null && saved.isNotEmpty && saved.first == today ? saved.skip(1).toSet() : <String>{};
    await Prefs().prefs.setStringList(key, [today, ...books..add(storeId)]);
  }

  /// A random per-install id for anonymous chart events; it identifies nothing else.
  String _installId() {
    const key = 'mg.installId';
    final existing = Prefs().prefs.getString(key);
    if (existing != null) return existing;
    final random = Random.secure();
    final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    Prefs().prefs.setString(key, id);
    return id;
  }

  /// Downloads [url] to [relative] (under the app's base path) with a progress sheet; returns
  /// false when cancelled or failed.
  Future<bool> _download(BuildContext context, String url, String relative, String title) async {
    if (!StoreConfig.configured) return false;
    final target = File(getBasePath(relative));
    if (await target.exists()) return true;
    final key = relative;
    final existing = _downloads[key];
    if (existing != null) {
      await existing;
      return target.exists();
    }
    final progress = ValueNotifier<double?>(null);
    final cancel = CancelToken();
    final completer = Completer<void>();
    _downloads[key] = completer.future;
    SmartDialog.show(
      tag: key,
      clickMaskDismiss: false,
      builder: (dialogContext) => _DownloadCard(
        title: title,
        progress: progress,
        onCancel: () => cancel.cancel(),
      ),
    );
    final part = File('${target.path}.part');
    try {
      await target.parent.create(recursive: true);
      await _dio.download(url, part.path, cancelToken: cancel, onReceiveProgress: (received, total) {
        if (total > 0) progress.value = received / total;
      });
      await part.rename(target.path);
      return true;
    } catch (e) {
      final cancelled = e is DioException && CancelToken.isCancel(e);
      if (!cancelled) {
        AnxLog.warning('Bookstore download failed: $url $e');
        if (context.mounted) AnxToast.show(L10n.of(context).storeOffline);
      }
      if (await part.exists()) await part.delete();
      return false;
    } finally {
      SmartDialog.dismiss(tag: key);
      progress.dispose();
      _downloads.remove(key);
      completer.complete();
    }
  }

  Future<String> _cover(StoreBook book) async {
    if (!StoreConfig.configured) return '';
    final relative = 'store/${book.id}/cover.webp';
    final file = File(getBasePath(relative));
    if (await file.exists()) return relative;
    final url = book.coverLarge ?? book.cover;
    if (url == null) return '';
    try {
      await file.parent.create(recursive: true);
      await _dio.download(url, file.path);
      return relative;
    } catch (_) {
      return '';
    }
  }

  /// Opens [volume] of [detail] in the reader, downloading it first when it is not cached.
  /// Downloads (when needed) and opens a volume, at [href] when a chapter was picked.
  Future<void> open(BuildContext context, WidgetRef ref, StoreBookDetail detail, StoreVolume volume,
      {String? href}) async {
    if (!StoreConfig.configured) return;
    // The page that asked may close when the reader replaces an open one; refresh through the container.
    final container = ProviderScope.containerOf(context, listen: false);
    final book = detail.book;
    final key = '${book.id}/${volume.n}';
    final relative = _volumePath(book.id, volume.n, volume.mtime);
    final title = '${book.title} ${volume.label}';
    if (!await _download(context, volume.url, relative, title)) return;

    var row = await bookDao.selectStoreVolume(key);
    final now = DateTime.now();
    if (row == null) {
      row = Book(
        id: -1,
        title: title,
        coverPath: await _cover(book),
        filePath: relative,
        lastReadPosition: '',
        readingPercentage: 0,
        author: book.author,
        isDeleted: false,
        description: detail.description,
        rating: 0,
        storeKey: key,
        createTime: now,
        updateTime: now,
      );
      row.id = await bookDao.insertBook(row);
    } else if (row.filePath != relative || row.coverPath.isEmpty) {
      // The server replaced the volume (new mtime) or the cover was missing: point at the new copy.
      final stale = row.filePath;
      row = row.copyWith(filePath: relative, coverPath: row.coverPath.isEmpty ? await _cover(book) : null);
      await bookDao.updateBook(row);
      if (stale != relative) unawaited(_deleteQuietly(stale));
    }
    await _recordOpened(book, detail.volumeList.length, volume.n);
    ref.invalidate(storeProgressProvider(book.id));
    ref.invalidate(storeHistoryProvider);
    unawaited(_trimCache(keep: relative));
    if (!context.mounted) return;
    await pushToReadingPage(ref, context, row, href: href);
    container.invalidate(storeProgressProvider(book.id));
    container.invalidate(storeHistoryProvider);
    container.invalidate(readingHistoryProvider);
  }

  /// Fetches a cached volume again after it was trimmed or never synced to this device.
  Future<void> reopen(WidgetRef ref, BuildContext context, Book row) async {
    if (!StoreConfig.configured) return;
    final container = ProviderScope.containerOf(context, listen: false);
    final key = row.storeKey!;
    final url = StoreConfig.absolute('/files/$key.epub');
    if (!await _download(context, url, row.filePath, row.title)) return;
    if (!context.mounted) return;
    await pushToReadingPage(ref, context, row);
    container.invalidate(storeHistoryProvider);
  }

  /// Deletes this series' downloaded volumes; they download again when opened.
  Future<void> clearDownloads(String storeId) async {
    final dir = Directory(getBasePath('store/$storeId'));
    if (!await dir.exists()) return;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.epub')) await entity.delete();
    }
  }

  Future<void> _deleteQuietly(String relative) async {
    try {
      final file = File(getBasePath(relative));
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// Keeps the volume cache under [cacheLimit], dropping the volumes read longest ago.
  Future<void> _trimCache({required String keep}) async {
    try {
      final rows = await bookDao.selectBooks(includeStore: true);
      final cached = <(Book, File, int)>[];
      var total = 0;
      for (final row in rows.where((b) => b.storeKey != null)) {
        final file = File(row.fileFullPath);
        if (!await file.exists()) continue;
        final size = await file.length();
        total += size;
        cached.add((row, file, size));
      }
      if (total <= cacheLimit) return;
      cached.sort((a, b) => a.$1.updateTime.compareTo(b.$1.updateTime));
      for (final (row, file, size) in cached) {
        if (total <= cacheLimit) break;
        if (row.filePath == keep) continue;
        await file.delete();
        total -= size;
      }
    } catch (e) {
      AnxLog.warning('Bookstore cache trim failed: $e');
    }
  }
}

class _DownloadCard extends StatelessWidget {
  const _DownloadCard({required this.title, required this.progress, required this.onCancel});

  final String title;
  final ValueNotifier<double?> progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return Container(
      width: 300,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      decoration: BoxDecoration(color: palette.menu, borderRadius: BorderRadius.circular(14)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 16),
          ValueListenableBuilder<double?>(
            valueListenable: progress,
            builder: (context, value, _) => ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: value, minHeight: 4),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onCancel,
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
          ),
        ],
      ),
    );
  }
}
