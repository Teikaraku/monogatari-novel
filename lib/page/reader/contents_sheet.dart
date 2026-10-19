import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/reader/reader_kit.dart';
import 'package:anx_reader/page/reader/reader_theme.dart';
import 'package:anx_reader/providers/book_notes.dart';
import 'package:anx_reader/providers/bookmark.dart';
import 'package:anx_reader/widgets/book_notes/book_notes_list.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/reading_page/widgets/book_toc.dart';
import 'package:anx_reader/widgets/reading_page/widgets/bookmark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ContentsTab { toc, bookmarks, notes }

/// Contents, bookmarks and notes in one tall sheet under the book's header.
Future<void> showContentsSheet(
  BuildContext context, {
  required Book book,
  required GlobalKey<EpubPlayerState> epubPlayerKey,
  required void Function(bool show) setChrome,
  ContentsTab initial = ContentsTab.toc,
}) {
  final theme = readerChromeTheme(context, Prefs().readTheme);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: theme.extension<MgPalette>()!.page,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheetContext) => Theme(
      data: theme,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .9,
          child: _ContentsSheet(
            book: book,
            epubPlayerKey: epubPlayerKey,
            initial: initial,
            onNavigate: () {
              setChrome(false);
              Navigator.of(sheetContext).pop();
            },
          ),
        ),
      ),
    ),
  );
}

class _ContentsSheet extends ConsumerStatefulWidget {
  const _ContentsSheet({
    required this.book,
    required this.epubPlayerKey,
    required this.initial,
    required this.onNavigate,
  });

  final Book book;
  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final ContentsTab initial;
  final VoidCallback onNavigate;

  @override
  ConsumerState<_ContentsSheet> createState() => _ContentsSheetState();
}

class _ContentsSheetState extends ConsumerState<_ContentsSheet> {
  late ContentsTab _tab = widget.initial;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final player = widget.epubPlayerKey.currentState;
    final percent = player?.percentage ?? widget.book.readingPercentage;
    final bookmarks = ref.watch(BookmarkProvider(widget.book.id)).valueOrNull?.length;
    final notes = ref.watch(bookNotesControllerProvider(widget.book)).valueOrNull?.allNotes.length;

    String label(String text, int? count) => count == null || count == 0 ? text : '$text $count';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 10, bottom: 8),
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: palette.separator, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 12, 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BookCover(book: widget.book, width: 46, height: 66, radius: 6),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, height: 1.3, fontWeight: FontWeight.w700)),
                    if (widget.book.author.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(widget.book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
                      ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: SizedBox(
                              height: 3,
                              child: Stack(
                                children: [
                                  Positioned.fill(child: ColoredBox(color: palette.separator)),
                                  FractionallySizedBox(
                                    widthFactor: percent.clamp(0.0, 1.0),
                                    child: ColoredBox(color: scheme.primary),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(l10n.readerReadPercent('${(percent * 100).toStringAsFixed(1)}%'),
                            style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                      ],
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.keyboard_arrow_down, color: palette.secondaryLabel),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: ReaderChoiceRow<ContentsTab>(
            selected: _tab,
            onSelected: (tab) => setState(() => _tab = tab),
            options: [
              (ContentsTab.toc, Text(l10n.readerToc)),
              (ContentsTab.bookmarks, Text(label(l10n.readerBookmarks, bookmarks))),
              (ContentsTab.notes, Text(label(l10n.notes, notes))),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: IndexedStack(
              index: _tab.index,
              children: [
                BookToc(
                  epubPlayerKey: widget.epubPlayerKey,
                  hideAppBarAndBottomBar: (bool show) {},
                  closeDrawer: widget.onNavigate,
                ),
                BookmarkWidget(epubPlayerKey: widget.epubPlayerKey, onNavigate: widget.onNavigate),
                ListView(
                  padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom + 24),
                  children: [BookNotesList(book: widget.book, reading: true, onNavigate: widget.onNavigate)],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
