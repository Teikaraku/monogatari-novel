import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_notes_page.dart';
import 'package:anx_reader/providers/notes_page_current_book.dart';
import 'package:anx_reader/providers/notes_statistics.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Every book with notes, newest-annotated first, under a count of notes and books.
/// Wide layouts show the selected book's notes beside the list.
class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key, this.controller});

  final ScrollController? controller;

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  late final ScrollController _scrollController = widget.controller ?? ScrollController();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth > 720) {
          return Row(
            children: [
              SizedBox(width: 360, child: _list(wide: true)),
              VerticalDivider(width: .5, thickness: .5, color: MgPalette.of(context).separator),
              const Expanded(child: NotesDetail()),
            ],
          );
        }
        return _list(wide: false);
      },
    );
  }

  Widget _list({required bool wide}) {
    final l10n = L10n.of(context);
    final stats = ref.watch(notesStatisticsProvider).valueOrNull;
    final books = ref.watch(bookIdAndNotesProvider);
    final selected = wide ? ref.watch(notesPageCurrentBookProvider).valueOrNull?.book.id : null;
    final items = books.valueOrNull;
    if (items != null && items.isEmpty) {
      return MgEmptyState(icon: Icons.sticky_note_2_outlined, title: l10n.notesEmptyTitle);
    }
    final inset = wide ? 16.0 : 16 + mgCenteredInset(context, mgReadableWidth);
    return ListView(
      controller: _scrollController,
      padding: EdgeInsets.fromLTRB(inset, 8, inset, 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        _Summary(notes: stats?['numberOfNotes'] ?? 0, books: stats?['numberOfBooks'] ?? 0),
        const SizedBox(height: 8),
        if (items == null)
          const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else
          for (final item in items)
            _NotesBookRow(
              book: item['book'] as Book,
              notes: item['numberOfNotes'] as int,
              seconds: item['readingTime'] as int,
              selected: (item['book'] as Book).id == selected,
              onTap: () {
                final book = item['book'] as Book;
                final count = item['numberOfNotes'] as int;
                if (wide) {
                  ref.read(notesPageCurrentBookProvider.notifier).setData(book, count);
                } else {
                  Navigator.of(context).push(CupertinoPageRoute(
                    builder: (_) => BookNotesPage(book: book, numberOfNotes: count, isMobile: true),
                  ));
                }
              },
            ),
      ],
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.notes, required this.books});

  final int notes;
  final int books;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    Widget cell(String figure, String label) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
              const SizedBox(height: 4),
              MgFigure(figure, size: 22),
            ],
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(color: mgSheetGroupColor(context), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          cell(l10n.mgNoteCount(notes), l10n.notesSummaryNotes),
          cell(l10n.mgBookCount(books), l10n.notesSummaryBooks),
        ],
      ),
    );
  }
}

class _NotesBookRow extends StatelessWidget {
  const _NotesBookRow({
    required this.book,
    required this.notes,
    required this.seconds,
    required this.selected,
    required this.onTap,
  });

  final Book book;
  final int notes;
  final int seconds;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final meta = [
      l10n.notesNotes(notes),
      if (seconds > 0) mgDuration(l10n, seconds),
      '${(book.readingPercentage * 100).round()}%',
    ].join(' · ');
    return Material(
      color: selected ? accent.withValues(alpha: .08) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: palette.separator, width: .5)),
          ),
          child: Row(
            children: [
              Hero(
                tag: selected ? '${book.coverFullPath}notes' : book.coverFullPath,
                child: BookCover(book: book, width: 52, height: 74, radius: 6),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600, color: selected ? accent : null),
                    ),
                    if (book.author.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(meta, style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: palette.secondaryLabel.withValues(alpha: .7)),
            ],
          ),
        ),
      ),
    );
  }
}

class NotesDetail extends ConsumerWidget {
  const NotesDetail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref.watch(notesPageCurrentBookProvider).when(
          data: (current) => BookNotesPage(
            isMobile: false,
            book: current.book,
            numberOfNotes: current.numberOfNotes,
          ),
          loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          error: (error, stack) => MgEmptyState(
            icon: Icons.sticky_note_2_outlined,
            title: L10n.of(context).notesEmptyTitle,
          ),
        );
  }
}
