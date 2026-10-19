import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/models/book_notes_state.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/providers/book_notes.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/widgets/book_notes/book_note_tile.dart';
import 'package:anx_reader/widgets/book_share/excerpt_share_service.dart';
import 'package:anx_reader/widgets/delete_confirm.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:iconsx_plus/iconsx_plus.dart';
import 'package:sticky_headers/sticky_headers.dart';

/// A book's notes under a sticky toolbar: count, sort and filter, or the selection actions
/// while notes are selected. Used on the notes page and inside the reader.
class BookNotesList extends ConsumerWidget {
  const BookNotesList({
    super.key,
    required this.book,
    required this.reading,
    this.exportNotes,
    this.onNavigate,
  });

  final Book book;
  final bool reading;

  /// Called after jumping to a note inside the reader.
  final VoidCallback? onNavigate;
  final void Function(BuildContext context, Book book, {List<BookNote>? notes})? exportNotes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(bookNotesControllerProvider(book));
    return notesAsync.when(
      data: (state) => _buildContent(context, ref, state),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (error, stack) => Padding(
        padding: const EdgeInsets.all(16),
        child: Text('$error'),
      ),
    );
  }

  Widget _buildContent(BuildContext context, WidgetRef ref, BookNotesState state) {
    return StickyHeader(
      header: _header(context, ref, state),
      content: state.visibleNotes.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: MgEmptyState(icon: Icons.sticky_note_2_outlined, title: L10n.of(context).notesEmptyTitle),
            )
          : Column(
              children: [
                for (final note in state.visibleNotes)
                  _slidableNote(context, ref, note, _bookNoteItem(context, ref, state, note)),
              ],
            ),
    );
  }

  Widget _header(BuildContext context, WidgetRef ref, BookNotesState state) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final notifier = ref.read(bookNotesControllerProvider(book).notifier);
    final accent = Theme.of(context).colorScheme.primary;
    final background = reading ? Colors.transparent : palette.page;

    if (state.isSelecting) {
      final allSelected = state.selectedNoteIds.length == state.visibleNotes.length && state.visibleNotes.isNotEmpty;
      return Container(
        color: background,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            IconButton(
              onPressed: allSelected ? notifier.clearSelection : notifier.selectAllVisible,
              icon: Icon(allSelected ? EvaIcons.checkmark_circle : Icons.circle_outlined, color: accent),
            ),
            Text('${state.selectedNoteIds.length} / ${state.visibleNotes.length}',
                style: TextStyle(fontSize: 14, color: palette.secondaryLabel)),
            const Spacer(),
            DeleteConfirm(
              delete: () async {
                final notesToDelete = List<BookNote>.from(state.selectedNotes);
                await notifier.deleteNotes(notesToDelete);
                if (reading) {
                  final player = epubPlayerKey.currentState;
                  if (player != null) {
                    for (final note in notesToDelete) {
                      if (note.cfi.isNotEmpty) player.removeAnnotation(note.cfi);
                    }
                  }
                }
              },
              deleteIcon: Icon(EvaIcons.trash_2, color: accent),
              confirmIcon: Icon(EvaIcons.close_circle, color: Theme.of(context).colorScheme.error),
            ),
            if (!reading && exportNotes != null)
              IconButton(
                onPressed: () => exportNotes!.call(context, book, notes: notifier.notesForExport(selectedOnly: true)),
                icon: Icon(Icons.ios_share, color: accent),
              ),
            IconButton(
              onPressed: notifier.clearSelection,
              icon: Icon(Icons.close, color: palette.secondaryLabel),
            ),
          ],
        ),
      );
    }

    return Container(
      color: background,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(l10n.notesNotes(state.visibleNotes.length),
                style: TextStyle(fontSize: 14, color: palette.secondaryLabel)),
          ),
          _SortChip(
            label: l10n.notesPageSortTime,
            field: NotesSortField.createdTime,
            mode: state.viewSortMode,
            onTap: () => notifier.toggleViewSort(NotesSortField.createdTime),
          ),
          const SizedBox(width: 8),
          _SortChip(
            label: l10n.notesPageSortChapter,
            field: NotesSortField.cfi,
            mode: state.viewSortMode,
            onTap: () => notifier.toggleViewSort(NotesSortField.cfi),
          ),
          IconButton(
            tooltip: l10n.notesFilter,
            onPressed: () => _showFilterSheet(context),
            icon: Icon(state.showAllNotes ? EvaIcons.funnel_outline : EvaIcons.funnel,
                color: state.showAllNotes ? palette.secondaryLabel : accent),
          ),
        ],
      ),
    );
  }

  void _showFilterSheet(BuildContext context) {
    final l10n = L10n.of(context);
    showMgSheet(
      context: context,
      title: l10n.notesFilter,
      builder: (context) => Consumer(builder: (context, ref, _) {
        final state = ref.watch(bookNotesControllerProvider(book)).valueOrNull;
        if (state == null) return const SizedBox(height: 120);
        final notifier = ref.read(bookNotesControllerProvider(book).notifier);
        return Padding(
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              MgSheetGroup(children: [
                MgSwitchRow(
                  title: l10n.noteListShowBookmark,
                  icon: Icons.bookmark_outline,
                  value: state.showBookmarks,
                  onChanged: (_) => notifier.toggleShowBookmarks(),
                ),
              ]),
              _SheetLabel(l10n.notesTypesColors),
              MgSheetGroup(children: [
                for (final type in notesType)
                  _TypeColorRow(
                    type: type,
                    enabled: state.enabledTypeColors,
                    onType: () => notifier.toggleTypeColors(type.type),
                    onColor: (color) => notifier.toggleTypeColor(type.type, color),
                  ),
              ]),
            ],
          ),
        );
      }),
      footer: (context) => Consumer(builder: (context, ref, _) {
        final count = ref.watch(bookNotesControllerProvider(book)).valueOrNull?.visibleNotes.length ?? 0;
        return MgSheetButtons(
          secondary: l10n.notesPageFilterReset,
          onSecondary: () => ref.read(bookNotesControllerProvider(book).notifier).resetFilters(),
          primary: l10n.notesPageViewAllNNotes(count),
          onPrimary: () => Navigator.of(context).pop(),
        );
      }),
    );
  }

  Widget _bookNoteItem(BuildContext context, WidgetRef ref, BookNotesState state, BookNote bookNote) {
    final notifier = ref.read(bookNotesControllerProvider(book).notifier);
    final selected = state.selectedNoteIds.contains(bookNote.id);
    return BookNoteTile(
      note: bookNote,
      onTap: () {
        if (state.isSelecting) {
          notifier.toggleSelection(bookNote);
        } else if (reading) {
          epubPlayerKey.currentState?.goToCfi(bookNote.cfi);
          onNavigate?.call();
        } else {
          pushToReadingPage(ref, context, book, cfi: bookNote.cfi);
        }
      },
      onLongPress: () => notifier.toggleSelection(bookNote),
      trailing: state.isSelecting
          ? Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Icon(
                selected ? EvaIcons.checkmark_circle_2 : Icons.circle_outlined,
                color: selected ? Theme.of(context).colorScheme.primary : MgPalette.of(context).separator,
              ),
            )
          : null,
    );
  }

  Widget _slidableNote(BuildContext context, WidgetRef ref, BookNote bookNote, Widget child) {
    return Slidable(
      key: ValueKey(bookNote.id),
      endActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: .42,
        children: [
          SlidableAction(
            onPressed: (context) => ExcerptShareService.showShareExcerpt(
              context: context,
              bookTitle: book.title,
              author: book.author,
              excerpt: bookNote.content,
              chapter: bookNote.chapter,
            ),
            icon: Icons.ios_share,
            label: L10n.of(context).readingPageShareShare,
            foregroundColor: Theme.of(context).colorScheme.primary,
            backgroundColor: Colors.transparent,
          ),
          SlidableAction(
            onPressed: (context) => _editBookNote(context, ref, bookNote),
            icon: Icons.edit_outlined,
            label: L10n.of(context).commonEdit,
            foregroundColor: Theme.of(context).colorScheme.primary,
            backgroundColor: Colors.transparent,
          ),
        ],
      ),
      child: child,
    );
  }

  void _editBookNote(BuildContext context, WidgetRef ref, BookNote bookNote) {
    final l10n = L10n.of(context);
    var currentType = bookNote.type;
    var currentColor = bookNote.color;
    final noteController = TextEditingController(text: bookNote.readerNote);
    final contentController = TextEditingController(text: bookNote.content);

    showMgSheet(
      context: context,
      title: l10n.notesEditTitle,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SheetField(label: l10n.notesExcerpt, controller: contentController, maxLines: 6),
              const SizedBox(height: 14),
              Row(
                children: [
                  for (final type in notesType)
                    _RoundToggle(
                      selected: currentType == type.type,
                      onTap: () => setState(() => currentType = type.type),
                      child: Icon(type.icon, size: 18),
                    ),
                  const Spacer(),
                  for (final color in notesColors)
                    _ColorDot(
                      color: color,
                      selected: currentColor == color,
                      onTap: () => setState(() => currentColor = color),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _SheetField(label: l10n.notesComment, controller: noteController, maxLines: 4),
            ],
          ),
        ),
      ),
      footer: (context) => MgSheetButtons(
        secondary: l10n.commonCancel,
        onSecondary: () => Navigator.of(context).pop(),
        primary: l10n.commonSave,
        onPrimary: () async {
          final updated = BookNote(
            id: bookNote.id,
            bookId: bookNote.bookId,
            content: contentController.text.trim(),
            cfi: bookNote.cfi,
            chapter: bookNote.chapter,
            type: currentType,
            color: currentColor,
            readerNote: noteController.text.trim(),
            createTime: bookNote.createTime,
            updateTime: DateTime.now(),
          );
          Navigator.of(context).pop();
          await ref.read(bookNotesControllerProvider(book).notifier).updateNote(updated);
        },
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({required this.label, required this.field, required this.mode, required this.onTap});

  final String label;
  final NotesSortField field;
  final NotesSortMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final active = mode.field == field;
    return MgChip(
      label: label,
      selected: active,
      checkmark: false,
      trailingIcon: active ? (mode.direction == SortDirection.asc ? Icons.arrow_upward : Icons.arrow_downward) : null,
      onTap: onTap,
    );
  }
}

class _SheetLabel extends StatelessWidget {
  const _SheetLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 7),
        child: Text(text, style: TextStyle(fontSize: 13, color: MgPalette.of(context).secondaryLabel)),
      );
}

/// One note type: its icon toggles every colour, the dots toggle single colours.
class _TypeColorRow extends StatelessWidget {
  const _TypeColorRow({required this.type, required this.enabled, required this.onType, required this.onColor});

  final NoteTypeOption type;
  final Set<String> enabled;
  final VoidCallback onType;
  final ValueChanged<String> onColor;

  @override
  Widget build(BuildContext context) {
    final any = notesColors.any((color) => enabled.contains('${type.type}#$color'));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _RoundToggle(selected: any, onTap: onType, child: Icon(type.icon, size: 18)),
          const Spacer(),
          for (final color in notesColors)
            _ColorDot(
              color: color,
              selected: enabled.contains('${type.type}#$color'),
              onTap: () => onColor(color),
            ),
        ],
      ),
    );
  }
}

class _RoundToggle extends StatelessWidget {
  const _RoundToggle({required this.selected, required this.onTap, required this.child});

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final palette = MgPalette.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? accent.withValues(alpha: .12) : palette.fill,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: IconTheme.merge(
              data: IconThemeData(color: selected ? accent : palette.secondaryLabel),
              child: Center(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({required this.color, required this.selected, required this.onTap});

  final String color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final value = Color(int.parse('0xff$color'));
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: value.withValues(alpha: selected ? 1 : .35),
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? Theme.of(context).colorScheme.onSurface.withValues(alpha: .7) : Colors.transparent,
              width: 2,
            ),
          ),
          child: selected ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
        ),
      ),
    );
  }
}

class _SheetField extends StatelessWidget {
  const _SheetField({required this.label, required this.controller, this.maxLines = 3});

  final String label;
  final TextEditingController controller;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(label, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
        ),
        TextField(
          controller: controller,
          minLines: 1,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 15, height: 1.5),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: mgSheetGroupColor(context),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }
}
