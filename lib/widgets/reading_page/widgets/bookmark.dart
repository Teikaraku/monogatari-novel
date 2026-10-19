import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/bookmark.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/providers/bookmark.dart';
import 'package:anx_reader/utils/error_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The book's bookmarks; tap to jump, swipe left to delete.
class BookmarkWidget extends ConsumerStatefulWidget {
  const BookmarkWidget({
    super.key,
    required this.epubPlayerKey,
    required this.onNavigate,
  });

  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final VoidCallback onNavigate;

  @override
  ConsumerState<BookmarkWidget> createState() => _BookmarkWidgetState();
}

class _BookmarkWidgetState extends ConsumerState<BookmarkWidget> {
  @override
  Widget build(BuildContext context) {
    final bookId = widget.epubPlayerKey.currentState!.book.id;
    final bookmarkList = ref.watch(BookmarkProvider(bookId));
    return bookmarkList.when(
      data: (bookmarks) {
        if (bookmarks.isEmpty) {
          return MgEmptyState(icon: Icons.bookmark_border, title: L10n.of(context).readerNoBookmarks);
        }
        return ListView.builder(
          padding: EdgeInsets.only(top: 4, bottom: MediaQuery.paddingOf(context).bottom + 24),
          itemCount: bookmarks.length,
          itemBuilder: (context, index) {
            final bookmark = bookmarks[index];
            return BookmarkItem(
              bookmark: bookmark,
              onTap: (cfi) {
                widget.epubPlayerKey.currentState?.goToCfi(cfi);
                widget.onNavigate();
              },
              onDelete: (id) => ref.read(BookmarkProvider(bookId).notifier).removeBookmark(id: id),
            );
          },
        );
      },
      error: (error, stackTrace) => errorHandler(error, stack: stackTrace),
      loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
    );
  }
}

class BookmarkItem extends StatelessWidget {
  const BookmarkItem({
    super.key,
    required this.bookmark,
    required this.onTap,
    required this.onDelete,
  });

  final BookmarkModel bookmark;
  final Function(String) onTap;
  final Function(int) onDelete;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Dismissible(
        key: ValueKey('bookmark-${bookmark.id}'),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => onDelete(bookmark.id!),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(color: scheme.error, borderRadius: BorderRadius.circular(12)),
          child: const Icon(Icons.delete_outline, color: Colors.white),
        ),
        child: Material(
          color: palette.fill,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => onTap(bookmark.cfi),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2, right: 10),
                    child: Icon(Icons.bookmark, size: 18, color: scheme.primary),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          bookmark.content.trim(),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 15, height: 1.5),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (bookmark.chapter.trim().isNotEmpty) bookmark.chapter.trim(),
                            '${(bookmark.percentage * 100).toStringAsFixed(1)}%',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: palette.secondaryLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
