import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/bookshelf_folder_style.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/tb_group.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/bookshelf/book_item.dart';
import 'package:anx_reader/widgets/bookshelf/book_opened_folder.dart';
import 'package:anx_reader/widgets/common/container/outlined_container.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:provider/provider.dart';

class BookFolder extends ConsumerStatefulWidget {
  const BookFolder({
    super.key,
    required this.books,
  });

  final List<Book> books;

  @override
  ConsumerState<BookFolder> createState() => _BookFolderState();
}

class _BookFolderState extends ConsumerState<BookFolder> {
  bool willAcceptBook = false;

  @override
  Widget build(BuildContext context) {
    final folderStyle = context.watch<Prefs>().bookshelfFolderStyle;

    void onAcceptBook(DragTargetDetails<Book> details) {
      int targetGroupId;
      if (widget.books.first.groupId == 0) {
        ref.read(bookListProvider.notifier).updateBook(
            widget.books.first.copyWith(groupId: widget.books.first.id));
        targetGroupId = widget.books.first.id;
      } else {
        targetGroupId = widget.books.first.groupId;
      }
      ref.read(bookListProvider.notifier).moveBook(details.data, targetGroupId);
    }

    Widget scaleTransition(Widget child) {
      return willAcceptBook
          ? ScaleTransition(
              scale: Tween<double>(begin: 1.0, end: 1.1).animate(
                CurvedAnimation(
                    parent: const AlwaysStoppedAnimation(0.5),
                    curve: Curves.easeInOut),
              ),
              child: child,
            )
          : child;
    }

    bool onWillAcceptBook(DragTargetDetails<Book>? details) {
      if (details?.data.id == widget.books.first.id) {
        return false;
      }
      willAcceptBook = details?.data != null;
      return details?.data != null;
    }

    void onLeaveBook(Book? book) {
      willAcceptBook = false;
    }

    void openFolder(String groupName) => showBookFolder(context, books: widget.books, groupName: groupName);

    String groupName = ref.watch(groupDaoProvider).whenOrNull(
              data: (groups) => groups
                  .firstWhere((group) => group.id == widget.books.first.groupId,
                      orElse: () => TbGroup(id: -1, name: "..."))
                  .name,
            ) ??
        '???';

    final singleBookTarget = DragTarget<Book>(
      onAcceptWithDetails: (book) => onAcceptBook(book),
      onWillAcceptWithDetails: (data) => onWillAcceptBook(data),
      onLeave: (data) => onLeaveBook(data),
      builder: (context, candidateData, rejectedData) {
        return scaleTransition(
          BookItem(book: widget.books[0]),
        );
      },
    );

    final groupTarget = DragTarget<Book>(
      onAcceptWithDetails: (book) => onAcceptBook(book),
      onWillAcceptWithDetails: (data) => onWillAcceptBook(data),
      onLeave: (data) => onLeaveBook(data),
      builder: (context, candidateData, rejectedData) {
        int count = -1;

        Widget buildStackedPreview() {
          return Stack(
            children: [
              ...(widget.books.take(4).toList()).map((book) {
                count++;
                return Positioned.fill(
                  right: 0,
                  top: 30 - count * Prefs().bookCoverWidth * 0.12,
                  child: Transform.scale(
                    scale: 1 - (count * 0.08),
                    child: BookCover(book: book),
                  ),
                );
              }),
            ].reversed.toList(),
          );
        }

        Widget buildGridPreview() {
          final previewBooks = widget.books.take(4).toList();
          return OutlinedContainer(
            color: MgPalette.of(context).fill,
            outlineColor: Colors.transparent,
            padding: const EdgeInsets.all(6),
            radius: 8,
            child: GridView.builder(
              physics: const NeverScrollableScrollPhysics(),
              shrinkWrap: true,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 1 / 1.6,
                mainAxisSpacing: 16,
                crossAxisSpacing: 6,
              ),
              itemCount: 4,
              itemBuilder: (context, index) {
                if (index >= previewBooks.length) {
                  return SizedBox.shrink();
                }
                final book = previewBooks[index];
                return BookCover(book: book);
              },
            ),
          );
        }

        Widget folderPreview;
        switch (folderStyle) {
          case BookshelfFolderStyle.grid2x2:
            folderPreview = buildGridPreview();
            break;
          case BookshelfFolderStyle.stacked:
            folderPreview = buildStackedPreview();
        }

        return scaleTransition(
          Column(
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => openFolder(groupName),
                  child: folderPreview,
                ),
              ),
              const SizedBox(height: 7),
              SizedBox(
                height: 52,
                width: double.infinity,
                child: Text(
                  '$groupName · ${widget.books.length}',
                  style: const TextStyle(fontSize: 14, height: 1.3, fontWeight: FontWeight.w500),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        );
      },
    );

    return RepaintBoundary(
      child: widget.books.length == 1 ? singleBookTarget : groupTarget,
    );
  }
}
