import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/book_sync_status.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/sync_status.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/page/book_actions.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/bookshelf/book_sync_status_icon.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A shelf tile: 2:3 cover with a progress badge, the title and the author below.
class BookItem extends ConsumerWidget {
  const BookItem({
    super.key,
    required this.book,
  });

  final Book book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MgPalette.of(context);

    void showActions() => showBookActions(context, book);

    final syncStatus = !Prefs().webdavStatus
        ? null
        : ref.watch(syncStatusProvider).whenOrNull(data: (data) {
              if (data.downloading.contains(book.id)) return BookSyncStatusEnum.downloading;
              if (data.uploading.contains(book.id)) return BookSyncStatusEnum.uploading;
              if (data.localOnly.contains(book.id)) return BookSyncStatusEnum.localOnly;
              if (data.remoteOnly.contains(book.id)) return BookSyncStatusEnum.remoteOnly;
              if (data.both.contains(book.id)) return BookSyncStatusEnum.both;
              if (data.nonExistent.contains(book.id)) return BookSyncStatusEnum.nonExistent;
              return BookSyncStatusEnum.checking;
            }) ??
            BookSyncStatusEnum.checking;

    final percent = (book.readingPercentage * 100).clamp(0, 100).round();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => pushToReadingPage(ref, context, book),
      onLongPress: showActions,
      onSecondaryTap: showActions,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Hero(tag: book.coverFullPath, child: BookCover(book: book)),
                ),
                if (percent > 0)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: percent >= 100 ? MgColors.green : MgColors.pink,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        percent >= 100 ? '✓' : '$percent%',
                        style: const TextStyle(
                            fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                if (syncStatus != null)
                  Positioned(
                    right: 4,
                    top: 4,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: BookSyncStatusIcon(syncStatus: syncStatus),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 52,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, height: 1.3, fontWeight: FontWeight.w500),
                ),
                if (book.author.isNotEmpty)
                  Text(
                    book.author,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, height: 1.35, color: palette.secondaryLabel),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
