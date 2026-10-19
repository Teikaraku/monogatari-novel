import 'dart:math';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Browse the whole library with up to three tags, a status and a sort order.
class StoreCatalogPage extends ConsumerStatefulWidget {
  const StoreCatalogPage({
    super.key,
    this.tags = const [],
    this.status,
    this.sort = StoreSort.updated,
    this.openTags = false,
  });

  final List<String> tags;
  final StoreStatus? status;
  final StoreSort sort;

  /// Opens the tag picker right away (the 分类 shortcut).
  final bool openTags;

  @override
  ConsumerState<StoreCatalogPage> createState() => _StoreCatalogPageState();
}

class _StoreCatalogPageState extends ConsumerState<StoreCatalogPage> {
  late List<String> _tags = [...widget.tags];
  late StoreStatus? _status = widget.status;
  late StoreSort _sort = widget.sort;
  final int _seed = Random().nextInt(1 << 31);
  late StorePager _pager = _makePager();

  StorePager _makePager() => StorePager((offset, limit) => BookstoreApi.instance.books(
        tags: _tags,
        status: _status,
        sort: _sort,
        seed: _seed,
        offset: offset,
        limit: limit,
      ))
        ..more();

  @override
  void initState() {
    super.initState();
    if (widget.openTags) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickTags());
    }
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _apply(VoidCallback change) {
    setState(() {
      change();
      _pager.dispose();
      _pager = _makePager();
    });
  }

  String _sortLabel(L10n l10n, StoreSort sort) => switch (sort) {
        StoreSort.updated => l10n.storeSortUpdated,
        StoreSort.title => l10n.storeSortTitle,
        StoreSort.words => l10n.storeSortWords,
        StoreSort.volumes => l10n.storeSortVolumes,
        StoreSort.random => l10n.storeSortRandom,
      };

  String _statusLabel(L10n l10n, StoreStatus? status) => switch (status) {
        StoreStatus.completed => l10n.storeStatusCompleted,
        StoreStatus.ongoing => l10n.storeStatusOngoing,
        _ => l10n.storeAll,
      };

  Future<void> _pickTags() async {
    final l10n = L10n.of(context);
    final selected = <String>{..._tags};
    final result = await showMgSheet<List<String>>(
      context: context,
      title: l10n.storeCategories,
      builder: (context) => Consumer(builder: (context, ref, _) {
        final tags = ref.watch(storeTagsProvider);
        return StatefulBuilder(builder: (context, setSheet) {
          return tags.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            error: (_, __) => Padding(
              padding: const EdgeInsets.all(24),
              child: Center(child: Text(l10n.storeOffline)),
            ),
            data: (tags) => MgSheetChips(children: [
              MgChip(
                label: l10n.storeAll,
                selected: selected.isEmpty,
                onTap: () => setSheet(selected.clear),
              ),
              for (final tag in tags)
                MgChip(
                  label: '${tag.name} ${tag.count}',
                  selected: selected.contains(tag.name),
                  onTap: () => setSheet(() {
                    if (!selected.remove(tag.name) && selected.length < 3) selected.add(tag.name);
                  }),
                ),
            ]),
          );
        });
      }),
      footer: (context) => MgSheetButtons(
        primary: MaterialLocalizations.of(context).okButtonLabel,
        onPrimary: () => Navigator.of(context).pop(selected.toList()),
      ),
    );
    if (result != null) _apply(() => _tags = result);
  }

  Future<void> _pickSort() async {
    final l10n = L10n.of(context);
    final result = await showMgSheet<StoreSort>(
      context: context,
      title: l10n.storeSort,
      builder: (context) => MgSheetGroup(children: [
        for (final sort in StoreSort.values)
          MgSheetOption(
            title: _sortLabel(l10n, sort),
            selected: sort == _sort,
            onTap: () => Navigator.of(context).pop(sort),
          ),
      ]),
    );
    if (result != null && result != _sort) _apply(() => _sort = result);
  }

  Future<void> _pickStatus() async {
    final l10n = L10n.of(context);
    final result = await showMgSheet<(StoreStatus?,)>(
      context: context,
      title: l10n.storeStatus,
      builder: (context) => MgSheetGroup(children: [
        for (final status in [null, StoreStatus.ongoing, StoreStatus.completed])
          MgSheetOption(
            title: _statusLabel(l10n, status),
            selected: status == _status,
            onTap: () => Navigator.of(context).pop((status,)),
          ),
      ]),
    );
    if (result != null && result.$1 != _status) _apply(() => _status = result.$1);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final title = _tags.length == 1
        ? _tags.first
        : _status == StoreStatus.completed && _tags.isEmpty
            ? l10n.storeCompleted
            : l10n.storeDiscover;
    final filters = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(MgShelfMetrics.of(context).inset, 2, 16, 10),
      child: Row(
        children: [
          MgChip(
            label: _tags.isEmpty ? l10n.storeCategories : _tags.join(' · '),
            selected: _tags.isNotEmpty,
            checkmark: false,
            trailingIcon: Icons.expand_more,
            onTap: _pickTags,
          ),
          const SizedBox(width: 8),
          MgChip(
            label: _status == null ? l10n.storeStatus : _statusLabel(l10n, _status),
            selected: _status != null,
            checkmark: false,
            trailingIcon: Icons.expand_more,
            onTap: _pickStatus,
          ),
          const SizedBox(width: 8),
          MgChip(
            label: _sortLabel(l10n, _sort),
            selected: _sort != StoreSort.updated,
            checkmark: false,
            trailingIcon: Icons.expand_more,
            onTap: _pickSort,
          ),
        ],
      ),
    );
    return MgPage(
      title: title,
      header: filters,
      body: RefreshIndicator(
        onRefresh: _pager.reset,
        child: CustomScrollView(
          slivers: [
            StorePagedSliver(
              pager: _pager,
              grid: true,
              itemBuilder: (context, book, _) => StoreBookCard(book: book),
            ),
          ],
        ),
      ),
    );
  }
}
