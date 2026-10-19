import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/search_repository.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/search_result_data.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_catalog_page.dart';
import 'package:anx_reader/page/bookstore/store_detail_page.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/store_library.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum _Scope { all, store, shelf, notes }

const _historyKey = 'mg.searchHistory';
const _historyLimit = 12;

/// One search over the bookstore, the shelf and the user's notes. Empty, it offers recent queries,
/// popular tags and the weekly chart.
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';
  _Scope _scope = _Scope.all;
  StorePager? _store;
  SearchResultData _local = SearchResultData.empty;
  int _localGeneration = 0;
  List<String> _history = Prefs().prefs.getStringList(_historyKey) ?? const [];

  @override
  void dispose() {
    _debounce?.cancel();
    _store?.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _remember(String query) {
    if (query.isEmpty) return;
    final next = [query, ..._history.where((q) => q != query)].take(_historyLimit).toList();
    Prefs().prefs.setStringList(_historyKey, next);
    setState(() => _history = next);
  }

  void _clearHistory() {
    Prefs().prefs.remove(_historyKey);
    setState(() => _history = const []);
  }

  void _run(String raw) {
    final query = raw.trim();
    if (query == _query) return;
    _store?.dispose();
    setState(() {
      _query = query;
      _scope = _Scope.all;
      _local = SearchResultData.empty;
      _store = query.isEmpty
          ? null
          : (StorePager((offset, limit) => BookstoreApi.instance.search(query, offset: offset, limit: limit))..more());
    });
    if (query.isEmpty) return;
    final generation = ++_localGeneration;
    const SearchRepository().search(query).then((result) {
      if (mounted && generation == _localGeneration) setState(() => _local = result);
    });
  }

  void _search(String value) {
    _controller.value = TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length));
    _remember(value.trim());
    _run(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return MgPage(
      title: l10n.navBarSearch,
      showBack: false,
      header: MgReadable(
        maxWidth: mgDetailWidth,
        child: MgSearchField(
          controller: _controller,
          placeholder: l10n.mgSearchHint,
          onChanged: (value) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 260), () => _run(value));
          },
          onSubmitted: (value) => _search(value),
        ),
      ),
      body: _query.isEmpty ? _idle(context) : _results(context),
    );
  }

  Widget _idle(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final home = ref.watch(storeHomeProvider).valueOrNull;
    final tags = home?.tags.take(14).toList() ?? const [];
    final chart = home?.section('rank') ?? const [];
    final inset = 16 + mgCenteredInset(context, mgDetailWidth);
    Widget heading(String title, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.only(top: 18, bottom: 10),
          child: Row(children: [
            Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            if (trailing != null) trailing,
          ]),
        );
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
      children: [
        if (_history.isNotEmpty) ...[
          heading(l10n.mgSearchHistory,
              trailing: IconButton(
                icon: Icon(Icons.delete_outline, color: palette.secondaryLabel),
                tooltip: l10n.mgClear,
                onPressed: _clearHistory,
              )),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final query in _history)
              MgChip(label: query, selected: false, checkmark: false, onTap: () => _search(query)),
          ]),
        ],
        if (tags.isNotEmpty) ...[
          heading(l10n.storeTags),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final tag in tags)
              MgChip(
                label: tag.name,
                selected: false,
                checkmark: false,
                onTap: () => Navigator.of(context).push(CupertinoPageRoute(
                  builder: (_) => StoreCatalogPage(tags: [tag.name]),
                )),
              ),
          ]),
        ],
        if (chart.isNotEmpty) ...[
          heading(l10n.mgTrending),
          for (final (index, book) in chart.indexed)
            InkWell(
              onTap: () => openStoreBook(context, book),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9),
                child: Row(children: [
                  StoreRankNumber(rank: index + 1),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(book.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15)),
                  ),
                  const SizedBox(width: 10),
                  Text(book.author,
                      maxLines: 1,
                      style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                ]),
              ),
            ),
        ],
      ],
    );
  }

  Widget _results(BuildContext context) {
    final l10n = L10n.of(context);
    final store = _store!;
    final inset = 16 + mgCenteredInset(context, mgDetailWidth);
    final notes = _local.noteGroups.fold<int>(0, (sum, group) => sum + group.notes.length);
    final needle = _query.toLowerCase();
    final series = [
      for (final record in ref.watch(storeShelfRecordsProvider).valueOrNull ?? const <StoreRecord>[])
        if (record.title.toLowerCase().contains(needle) || record.author.toLowerCase().contains(needle)) record,
    ];
    final shelf = series.length + _local.books.length;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final scopes = [
          (_Scope.all, l10n.storeAll),
          (_Scope.store, '${l10n.navBarBookstore} ${store.total ?? ''}'.trim()),
          (_Scope.shelf, '${l10n.navBarBookshelf} $shelf'),
          (_Scope.notes, '${l10n.navBarNotes} $notes'),
        ];
        final chips = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(inset, 2, inset, 6),
          child: Row(children: [
            for (final (scope, label) in scopes) ...[
              MgChip(
                label: label,
                selected: scope == _scope,
                checkmark: false,
                onTap: () => setState(() => _scope = scope),
              ),
              const SizedBox(width: 8),
            ],
          ]),
        );
        final slivers = <Widget>[SliverToBoxAdapter(child: chips)];
        Widget section(String title, int count, _Scope scope) => Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 4),
              child: Row(children: [
                Expanded(child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                if (count > 3)
                  TextButton(
                    onPressed: () => setState(() => _scope = scope),
                    child: Text('${l10n.storeMore} $count'),
                  ),
              ]),
            );
        final storeItems = store.items;
        final showStore = _scope == _Scope.all || _scope == _Scope.store;
        final showShelf = _scope == _Scope.all || _scope == _Scope.shelf;
        final showNotes = _scope == _Scope.all || _scope == _Scope.notes;
        final rows = <Widget>[];
        if (showShelf && shelf > 0) {
          if (_scope == _Scope.all) rows.add(section(l10n.navBarBookshelf, shelf, _Scope.shelf));
          final limit = _scope == _Scope.all ? 3 : shelf;
          for (final record in series.take(limit)) {
            rows.add(_SeriesRow(record: record, query: _query));
          }
          for (final book in _local.books.take(limit - series.length.clamp(0, limit))) {
            rows.add(_ShelfRow(book: book, query: _query));
          }
        }
        if (showNotes && _local.noteGroups.isNotEmpty) {
          if (_scope == _Scope.all) rows.add(section(l10n.navBarNotes, notes, _Scope.notes));
          for (final group in _scope == _Scope.all ? _local.noteGroups.take(2) : _local.noteGroups) {
            for (final note in _scope == _Scope.all ? group.notes.take(2) : group.notes) {
              rows.add(_NoteRow(book: group.book, text: note.content, chapter: note.chapter, cfi: note.cfi, query: _query));
            }
          }
        }
        if (showStore && storeItems.isNotEmpty) {
          if (_scope == _Scope.all) rows.add(section(l10n.navBarBookstore, store.total ?? storeItems.length, _Scope.store));
          final visible = _scope == _Scope.all ? storeItems.take(5) : storeItems;
          for (final (index, book) in visible.indexed) {
            if (_scope == _Scope.store && index >= storeItems.length - 8 && !store.done && !store.loading) {
              WidgetsBinding.instance.addPostFrameCallback((_) => store.more());
            }
            rows.add(StoreBookTile(book: book));
          }
        }
        final searching = store.loading && storeItems.isEmpty;
        if (rows.isEmpty) {
          slivers.add(SliverFillRemaining(
            hasScrollBody: false,
            child: searching
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : MgEmptyState(icon: Icons.search_off, title: l10n.storeNoResults),
          ));
        } else {
          slivers.add(SliverPadding(
            padding: EdgeInsets.fromLTRB(inset, 0, inset, 32),
            sliver: SliverList(delegate: SliverChildListDelegate(rows)),
          ));
        }
        return CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: slivers,
        );
      },
    );
  }
}

/// [text] with every case-insensitive occurrence of [query] in the accent color.
class _Highlighted extends StatelessWidget {
  const _Highlighted(this.text, this.query, {required this.style, this.maxLines = 1});

  final String text;
  final String query;
  final TextStyle style;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final spans = <TextSpan>[];
    final lower = text.toLowerCase();
    final needle = query.toLowerCase();
    var start = 0;
    while (needle.isNotEmpty) {
      final index = lower.indexOf(needle, start);
      if (index < 0) break;
      if (index > start) spans.add(TextSpan(text: text.substring(start, index)));
      spans.add(TextSpan(
        text: text.substring(index, index + needle.length),
        style: TextStyle(color: accent, fontWeight: FontWeight.w600),
      ));
      start = index + needle.length;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return Text.rich(TextSpan(style: style, children: spans), maxLines: maxLines, overflow: TextOverflow.ellipsis);
  }
}

/// A bookstore series on the shelf: where the reader is in it; opens its store page.
class _SeriesRow extends StatelessWidget {
  const _SeriesRow({required this.record, required this.query});

  final StoreRecord record;
  final String query;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final where = record.lastVolume == null
        ? l10n.bookshelfFilterNotStarted
        : '${l10n.storeVolumeN(record.lastVolume!)} · ${(record.lastPercent * 100).round()}%';
    return InkWell(
      onTap: () => Navigator.of(context).push(CupertinoPageRoute(
        builder: (_) => StoreDetailPage(id: record.storeId, preview: record.toBook()),
      )),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          SizedBox(width: 52, height: 78, child: StoreCover(url: record.coverUrl, width: 52, radius: 6)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Highlighted(record.title, query,
                  maxLines: 2,
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 3),
              _Highlighted(record.author, query, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
              const SizedBox(height: 3),
              Text(where, style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _ShelfRow extends ConsumerWidget {
  const _ShelfRow({required this.book, required this.query});

  final Book book;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MgPalette.of(context);
    return InkWell(
      onTap: () => pushToReadingPage(ref, context, book),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          BookCover(book: book, width: 52, height: 78, radius: 6),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Highlighted(book.title, query,
                  maxLines: 2, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 3),
              _Highlighted(book.author, query, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
              const SizedBox(height: 3),
              Text('${(book.readingPercentage * 100).round()}%',
                  style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _NoteRow extends ConsumerWidget {
  const _NoteRow({
    required this.book,
    required this.text,
    required this.chapter,
    required this.cfi,
    required this.query,
  });

  final Book book;
  final String text;
  final String chapter;
  final String cfi;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => pushToReadingPage(ref, context, book, cfi: cfi),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 3, height: 44, margin: const EdgeInsets.only(top: 2), color: accent.withValues(alpha: .5)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _Highlighted(text, query,
                  maxLines: 3,
                  style: TextStyle(fontSize: 15, height: 1.5, color: Theme.of(context).colorScheme.onSurface)),
              const SizedBox(height: 4),
              Text([book.title, chapter].where((s) => s.isNotEmpty).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
            ]),
          ),
        ]),
      ),
    );
  }
}
