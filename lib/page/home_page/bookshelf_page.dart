import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/sort_field.dart';
import 'package:anx_reader/enums/sort_order.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/tag.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_detail_page.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/providers/book_filters.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/shelf_order.dart';
import 'package:anx_reader/providers/tags.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/bookstore/store_library.dart';
import 'package:anx_reader/utils/color/hash_color.dart';
import 'package:anx_reader/page/book_actions.dart';
import 'package:anx_reader/widgets/bookshelf/book_folder.dart';
import 'package:anx_reader/widgets/bookshelf/sync_button.dart';
import 'package:anx_reader/widgets/common/tag_chip.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_reorderable_grid_view/widgets/custom_draggable.dart';
import 'package:flutter_reorderable_grid_view/widgets/reorderable_builder.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The shelf: imported books and folders, plus bookstore series the user added, in one cover grid.
class BookshelfPage extends ConsumerStatefulWidget {
  const BookshelfPage({super.key});

  @override
  ConsumerState<BookshelfPage> createState() => BookshelfPageState();
}

class BookshelfPageState extends ConsumerState<BookshelfPage> with AutomaticKeepAliveClientMixin {
  final _scrollController = ScrollController();
  final _gridViewKey = GlobalKey();
  Timer? _searchDebounce;
  String _query = '';
  bool _dragging = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _importBook() => pickAndImportBooks(context, ref);

  void _onSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () {
      setState(() => _query = value.trim());
      ref.read(bookListProvider.notifier).search(_query);
    });
  }

  void _setStatus(ReadingStatusFilter? status) {
    final notifier = ref.read(readingStatusFilterNotifierProvider.notifier);
    if (status == null) {
      notifier.clear();
    } else {
      notifier.toggle(status);
    }
    ref.read(bookListProvider.notifier).refresh();
  }

  Future<void> _editTag(Tag tag) async {
    final selected = ref.read(tagSelectionProvider);
    await TagChip.showEditDialog(
      context: context,
      initialName: tag.name,
      initialColor: tag.color ?? hashColor(tag.name),
      onRename: (name) async {
        await ref.read(tagListProvider.notifier).updateTag(tag.id, newName: name);
        ref.read(bookListProvider.notifier).refresh();
      },
      onColorChange: (color) async {
        await ref.read(tagListProvider.notifier).updateTag(tag.id, color: color);
        ref.read(bookListProvider.notifier).refresh();
      },
      onDelete: () async {
        await ref.read(tagListProvider.notifier).deleteTag(tag.id);
        if (selected.contains(tag.id)) ref.read(tagSelectionProvider.notifier).toggle(tag.id);
        ref.read(bookListProvider.notifier).refresh();
      },
    );
  }

  void _pickTags() {
    final l10n = L10n.of(context);
    showMgSheet(
      context: context,
      title: l10n.tagsSectionTitle,
      builder: (context) => Consumer(builder: (context, ref, _) {
        final tags = ref.watch(tagListProvider).valueOrNull ?? const <Tag>[];
        final selected = ref.watch(tagSelectionProvider);
        void toggle(int id) {
          ref.read(tagSelectionProvider.notifier).toggle(id);
          ref.read(bookListProvider.notifier).refresh();
        }

        if (tags.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(l10n.tagsEmptyHint,
                  style: TextStyle(color: MgPalette.of(context).secondaryLabel)),
            ),
          );
        }
        return MgSheetChips(children: [
          MgChip(
            label: l10n.noTagFilter,
            selected: selected.contains(kNoTagFilterId),
            onTap: () {
              for (final id in selected.where((id) => id != kNoTagFilterId).toList()) {
                ref.read(tagSelectionProvider.notifier).toggle(id);
              }
              toggle(kNoTagFilterId);
            },
          ),
          for (final tag in tags)
            GestureDetector(
              onLongPress: () {
                Navigator.of(context).pop();
                Future.microtask(() => _editTag(tag));
              },
              child: MgChip(
                label: tag.name,
                selected: selected.contains(tag.id),
                onTap: () {
                  if (selected.contains(kNoTagFilterId)) {
                    ref.read(tagSelectionProvider.notifier).toggle(kNoTagFilterId);
                  }
                  toggle(tag.id);
                },
              ),
            ),
        ]);
      }),
    );
  }

  List<List<MgMenuEntry>> _menu() {
    final l10n = L10n.of(context);
    void sortBy(SortFieldEnum field) {
      Prefs().sortField = field;
      ref.read(bookListProvider.notifier).refresh();
      ref.invalidate(storeShelfRecordsProvider);
    }

    void orderBy(SortOrderEnum order) {
      Prefs().sortOrder = order;
      ref.read(bookListProvider.notifier).refresh();
      ref.invalidate(storeShelfRecordsProvider);
    }

    return [
      [
        MgMenuAction(title: l10n.shelfImport, icon: Icons.file_download_outlined, onTap: _importBook),
        MgMenuAction(title: l10n.tagsSectionTitle, icon: Icons.sell_outlined, onTap: _pickTags),
      ],
      [
        MgMenuSubmenu(
          title: l10n.bookshelfSort,
          value: Prefs().sortField.getL10n(context),
          icon: Icons.swap_vert,
          sections: [
            [
              for (final field in SortFieldEnum.values)
                MgMenuAction(
                  title: field.getL10n(context),
                  checked: field == Prefs().sortField,
                  onTap: () => sortBy(field),
                ),
            ],
            [
              for (final order in SortOrderEnum.values)
                MgMenuAction(
                  title: order.getL10n(context),
                  checked: order == Prefs().sortOrder,
                  onTap: () => orderBy(order),
                ),
            ],
          ],
        ),
      ],
    ];
  }

  /// The long-press book sheet hangs on the home scaffold, so it is closed when the tab changes.
  PersistentBottomSheetController? _bookSheet;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    ref.listen(homeTabProvider, (_, tab) {
      if (tab != 0) {
        _bookSheet?.close();
        _bookSheet = null;
      }
    });
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final status = ref.watch(readingStatusFilterNotifierProvider);
    final selectedTags = ref.watch(tagSelectionProvider);
    final books = ref.watch(bookListProvider);
    final storeRecords = ref.watch(storeShelfRecordsProvider).valueOrNull ?? const <StoreRecord>[];
    final storeTags = selectedTags.isEmpty
        ? const <String, List<int>>{}
        : ref.watch(storeTagMapProvider).valueOrNull ?? const <String, List<int>>{};
    bool tagsMatch(StoreRecord record) {
      if (selectedTags.isEmpty) return true;
      final tags = storeTags[record.storeId] ?? const <int>[];
      if (selectedTags.contains(kNoTagFilterId)) return tags.isEmpty;
      return selectedTags.every(tags.contains);
    }

    final query = _query.toLowerCase();
    final filtering = status != ReadingStatusFilter.none || selectedTags.isNotEmpty;
    final store = storeRecords
        .where((r) =>
            tagsMatch(r) &&
            matchesShelfStatus(status, opened: r.opened, finished: r.finished) &&
            (query.isEmpty || r.title.toLowerCase().contains(query) || r.author.toLowerCase().contains(query)))
        .toList();

    final filters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Row(
        children: [
          for (final (value, label) in [
            (null, l10n.storeAll),
            (ReadingStatusFilter.reading, l10n.bookshelfFilterReading),
            (ReadingStatusFilter.finished, l10n.bookshelfFilterFinished),
            (ReadingStatusFilter.notStarted, l10n.bookshelfFilterNotStarted),
          ]) ...[
            MgChip(
              label: label,
              checkmark: false,
              selected: value == null ? status == ReadingStatusFilter.none : status == value,
              onTap: () => _setStatus(value),
            ),
            const SizedBox(width: 8),
          ],
          MgChip(
            label: selectedTags.isEmpty ? l10n.tagsSectionTitle : '${l10n.tagsSectionTitle} · ${selectedTags.length}',
            selected: selectedTags.isNotEmpty,
            checkmark: false,
            trailingIcon: Icons.expand_more,
            onTap: _pickTags,
          ),
        ],
      ),
    );

    final grid = books.when(
      skipLoadingOnReload: true,
      loading: () => const SizedBox.shrink(),
      error: (error, _) => MgEmptyState(icon: Icons.error_outline, title: error.toString()),
      data: (groups) {
        if (groups.isEmpty && store.isEmpty) {
          return MgEmptyState(
            icon: filtering || query.isNotEmpty ? Icons.filter_alt_off_outlined : Icons.library_books_outlined,
            title: filtering || query.isNotEmpty ? l10n.storeNoResults : l10n.mgLibraryEmpty,
            action: filtering || query.isNotEmpty ? null : l10n.storeGoBookstore,
            onAction: () => ref.read(homeTabProvider.notifier).state = 1,
          );
        }
        // Bookstore series and local books interleave in the one shelf order (both lists arrive sorted).
        final entries = <Object>[];
        for (var i = 0, j = 0; i < store.length || j < groups.length;) {
          final takeStore = j >= groups.length ||
              (i < store.length &&
                  compareShelfKeys(store[i].sortKey, ShelfSortKey.book(groups[j].first)) <= 0);
          entries.add(takeStore ? store[i++] : groups[j++]);
        }
        final locked = <int>[
          for (var i = 0; i < entries.length; i++)
            if (entries[i] is! List<Book> || (entries[i] as List<Book>).length != 1) i,
        ];
        return ReorderableBuilder(
          lockedIndices: locked,
          enableDraggable: true,
          longPressDelay: const Duration(milliseconds: 300),
          onReorder: (_) {},
          scrollController: _scrollController,
          onDragStarted: (index) {
            final entry = entries[index];
            if (entry is List<Book> && entry.length == 1) {
              _bookSheet?.close();
              _bookSheet = showBottomSheet(
                context: context,
                showDragHandle: false,
                constraints: const BoxConstraints(maxWidth: 640),
                builder: (context) => BookBottomSheet(book: entry.first),
              );
            }
          },
          onDragEnd: (_) => setState(() {}),
          children: [
            for (final entry in entries)
              if (entry is StoreRecord)
                _StoreShelfTile(key: ValueKey('store:${entry.storeId}'), record: entry)
              else if ((entry as List<Book>).length == 1)
                CustomDraggable(
                  key: ValueKey<String>(entry.first.id.toString()),
                  data: entry.first,
                  child: BookFolder(books: entry),
                )
              else
                BookFolder(key: ValueKey<String>(entry.first.id.toString()), books: entry),
          ],
          builder: (children) => LayoutBuilder(builder: (context, constraints) {
            final columns = (constraints.maxWidth / Prefs().bookCoverWidth).floor().clamp(2, 12);
            final cellWidth = (constraints.maxWidth - 32 - (columns - 1) * 14) / columns;
            return GridView(
              key: _gridViewKey,
              controller: _scrollController,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: cellWidth / (cellWidth * 1.5 + 59),
                mainAxisSpacing: 18,
                crossAxisSpacing: 14,
              ),
              children: children,
            );
          }),
        );
      },
    );

    return Scaffold(
      backgroundColor: palette.page,
      body: Column(
        children: [
          MgPageTitle(
            title: l10n.navBarBookshelf,
            actions: [
              if (Prefs().webdavStatus) const SyncButton(),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: l10n.shelfImport,
                onPressed: _importBook,
              ),
              MgMenuButton(sections: _menu),
            ],
          ),
          MgSearchField(placeholder: l10n.shelfFind, onChanged: _onSearch),
          filters,
          Expanded(
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dragging = true),
              onDragExited: (_) => setState(() => _dragging = false),
              onDragDone: (detail) async {
                final files = [
                  for (final file in detail.files)
                    await stageImportFile(file.path, file.name),
                ];
                if (!context.mounted) return;
                importBookList(files, context, ref);
                setState(() => _dragging = false);
              },
              child: Stack(
                children: [
                  Positioned.fill(child: grid),
                  if (_dragging)
                    Positioned.fill(
                      child: ColoredBox(
                        color: palette.page.withValues(alpha: .85),
                        child: MgEmptyState(
                          icon: Icons.file_download_outlined,
                          title: l10n.bookshelfDragging,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A bookstore series on the shelf; opens its store page, long press shows its actions.
class _StoreShelfTile extends ConsumerWidget {
  const _StoreShelfTile({super.key, required this.record});

  final StoreRecord record;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MgPalette.of(context);
    final l10n = L10n.of(context);
    return Builder(
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => Navigator.of(context).push(CupertinoPageRoute(
          builder: (_) => StoreDetailPage(id: record.storeId, preview: record.toBook()),
        )),
        onLongPress: () => showStoreBookActions(context, record),
        onSecondaryTap: () => showStoreBookActions(context, record),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: StoreCover(url: record.coverUrl, radius: 0),
                    ),
                  ),
                  if (record.lastVolume != null)
                    Positioned(
                      left: 6,
                      top: 6,
                      child: StoreBadge(text: l10n.storeVolumeN(record.lastVolume!)),
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
                  Text(record.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14, height: 1.3, fontWeight: FontWeight.w500)),
                  if (record.author.isNotEmpty)
                    Text(record.author,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, height: 1.35, color: palette.secondaryLabel)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
