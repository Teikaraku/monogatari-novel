import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/models/book_notes_state.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_detail.dart';
import 'package:anx_reader/providers/book_notes.dart';
import 'package:anx_reader/service/notes/export_notes.dart';
import 'package:anx_reader/service/notes/import_notes.dart';
import 'package:anx_reader/widgets/book_notes/book_notes_list.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:iconsx_plus/iconsx_plus.dart';

/// One book's notes: a compact book header, then the sortable, filterable list.
class BookNotesPage extends ConsumerStatefulWidget {
  const BookNotesPage({
    super.key,
    required this.book,
    required this.numberOfNotes,
    required this.isMobile,
  });

  final Book book;
  final int numberOfNotes;
  final bool isMobile;

  @override
  ConsumerState<BookNotesPage> createState() => _BookNotesPageState();
}

class _BookNotesPageState extends ConsumerState<BookNotesPage> {
  Book get book => widget.book;

  Future<void> _import() async {
    final imported = await importNotesJsonForBook(context, book);
    if (imported != null && imported > 0 && mounted) {
      await ref.read(bookNotesControllerProvider(book).notifier).refresh();
    }
  }

  void handleExportNotes(BuildContext context, Book book, {List<BookNote>? notes}) {
    final l10n = L10n.of(context);
    var mergeChapters = Prefs().notesExportMergeChapters;
    showMgSheet(
      context: context,
      title: l10n.notesPageExport,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) => Consumer(builder: (context, ref, _) {
          final state = ref.watch(bookNotesControllerProvider(book)).valueOrNull;
          if (state == null) return const SizedBox(height: 120);
          final notifier = ref.read(bookNotesControllerProvider(book).notifier);
          final byChapter = state.exportSortMode.field == NotesSortField.cfi;

          void sort(NotesSortField field) {
            if (state.exportSortMode.field == field) {
              notifier.toggleExportSortDirection();
            } else {
              notifier.setExportSortField(field);
            }
          }

          void export(ExportType type) {
            final sorted = notifier.notesForExport(selectedOnly: false, custom: notes);
            Navigator.of(context).pop();
            exportNotes(
              book,
              sorted,
              type,
              mergeChapterHeadings: byChapter && mergeChapters && type != ExportType.csv && type != ExportType.json,
            );
          }

          IconData? arrow(NotesSortField field) => state.exportSortMode.field != field
              ? null
              : state.exportSortMode.direction == SortDirection.asc
                  ? Icons.arrow_upward
                  : Icons.arrow_downward;

          return Padding(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _label(context, l10n.notesSort),
                Row(
                  children: [
                    const SizedBox(width: 16),
                    MgChip(
                      label: l10n.notesPageSortTime,
                      selected: !byChapter,
                      checkmark: false,
                      trailingIcon: arrow(NotesSortField.createdTime),
                      onTap: () => sort(NotesSortField.createdTime),
                    ),
                    const SizedBox(width: 8),
                    MgChip(
                      label: l10n.notesPageSortChapter,
                      selected: byChapter,
                      checkmark: false,
                      trailingIcon: arrow(NotesSortField.cfi),
                      onTap: () => sort(NotesSortField.cfi),
                    ),
                  ],
                ),
                if (byChapter) ...[
                  const SizedBox(height: 12),
                  MgSheetGroup(children: [
                    MgSwitchRow(
                      title: l10n.notesExportMergeChapters,
                      value: mergeChapters,
                      onChanged: (value) {
                        setSheet(() => mergeChapters = value);
                        Prefs().notesExportMergeChapters = value;
                      },
                    ),
                  ]),
                ],
                _label(context, l10n.notesFormat),
                GridView.count(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  crossAxisCount: 5,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: .9,
                  children: [
                    _FormatTile(icon: Icons.copy, label: l10n.notesCopy, onTap: () => export(ExportType.copy)),
                    _FormatTile(icon: IonIcons.logo_markdown, label: 'Markdown', onTap: () => export(ExportType.md)),
                    _FormatTile(
                        icon: Icons.text_snippet_outlined,
                        label: l10n.notesPlainText,
                        onTap: () => export(ExportType.txt)),
                    _FormatTile(icon: Icons.table_chart_outlined, label: 'CSV', onTap: () => export(ExportType.csv)),
                    _FormatTile(icon: Icons.data_object, label: 'JSON', onTap: () => export(ExportType.json)),
                  ],
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _label(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
        child: Text(text, style: TextStyle(fontSize: 13, color: MgPalette.of(context).secondaryLabel)),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final count = ref.watch(bookNotesControllerProvider(book)).valueOrNull?.allNotes.length ?? widget.numberOfNotes;
    final inset = 16 + (widget.isMobile ? mgCenteredInset(context, mgReadableWidth) : 0.0);
    final percent = (book.readingPercentage * 100).round();

    return Scaffold(
      backgroundColor: palette.page,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    if (widget.isMobile)
                      IconButton(
                        icon: Icon(Icons.arrow_back, color: accent),
                        tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(Icons.ios_share, color: accent),
                      tooltip: l10n.notesPageExport,
                      onPressed: () => handleExportNotes(context, book),
                    ),
                    MgMenuButton(
                      sections: () => [
                        [
                          MgMenuAction(
                            title: l10n.bookInfoOpen,
                            icon: Icons.info_outline,
                            onTap: () => openBookDetail(context, book),
                          ),
                          MgMenuAction(
                            title: l10n.notesJsonImportTitle,
                            icon: Icons.file_download_outlined,
                            onTap: _import,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.fromLTRB(inset, 4, inset, 32 + MediaQuery.paddingOf(context).bottom),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Hero(
                        tag: book.coverFullPath,
                        child: BookCover(book: book, width: 72, height: 104, radius: 6),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(book.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 20, height: 1.3, fontWeight: FontWeight.bold)),
                            if (book.author.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(book.author, style: TextStyle(fontSize: 14, color: accent)),
                              ),
                            Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(
                                '${l10n.notesNotes(count)} · ${l10n.notesReadPercentage('$percent%')}',
                                style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  BookNotesList(book: book, reading: false, exportNotes: handleExportNotes),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FormatTile extends StatelessWidget {
  const _FormatTile({required this.icon, required this.label, required this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: mgSheetGroupColor(context),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: accent, size: 24),
            const SizedBox(height: 6),
            Text(label,
                maxLines: 1, overflow: TextOverflow.fade, softWrap: false, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
