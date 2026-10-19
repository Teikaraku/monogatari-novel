import 'dart:math';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:flutter/material.dart';

enum _Length { all, short, medium, long }

/// Finished series to binge: pick a length, then browse cards that lead with the total size.
class StoreCompletedPage extends StatefulWidget {
  const StoreCompletedPage({super.key});

  @override
  State<StoreCompletedPage> createState() => _StoreCompletedPageState();
}

class _StoreCompletedPageState extends State<StoreCompletedPage> {
  _Length _length = _Length.all;
  StoreSort _sort = StoreSort.updated;
  final int _seed = Random().nextInt(1 << 31);
  late StorePager _pager = _make();

  (int?, int?) get _range => switch (_length) {
        _Length.all => (null, null),
        _Length.short => (1, 3),
        _Length.medium => (4, 9),
        _Length.long => (10, null),
      };

  StorePager _make() {
    final (min, max) = _range;
    return StorePager(
      (offset, limit) => BookstoreApi.instance.books(
        status: StoreStatus.completed,
        sort: _sort,
        seed: _seed,
        minVolumes: min,
        maxVolumes: max,
        withDescription: true,
        offset: offset,
        limit: limit,
      ),
    )..more();
  }

  void _apply(VoidCallback change) {
    setState(() {
      change();
      _pager.dispose();
      _pager = _make();
    });
  }

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final lengths = [
      (_Length.all, l10n.storeAll, l10n.storeLengthAll, Icons.all_inclusive),
      (_Length.short, l10n.storeLengthShort, l10n.storeLengthShortRange, Icons.bolt),
      (_Length.medium, l10n.storeLengthMedium, l10n.storeLengthMediumRange, Icons.menu_book_outlined),
      (_Length.long, l10n.storeLengthLong, l10n.storeLengthLongRange, Icons.auto_stories),
    ];
    final metrics = MgShelfMetrics.of(context);
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: metrics.inset),
          child: Row(
            children: [
              for (final (index, (value, title, range, icon)) in lengths.indexed) ...[
                if (index > 0) const SizedBox(width: 8),
                Expanded(
                  child: _LengthCard(
                    title: title,
                    range: range,
                    icon: icon,
                    selected: value == _length,
                    onTap: () => _apply(() => _length = value),
                  ),
                ),
              ],
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(metrics.inset, 10, metrics.inset, 8),
          child: Row(children: [
            for (final (sort, label) in [
              (StoreSort.updated, l10n.storeSortUpdated),
              (StoreSort.words, l10n.storeSortWords),
              (StoreSort.random, l10n.storeSortRandom),
            ]) ...[
              MgChip(
                label: label,
                selected: sort == _sort,
                checkmark: false,
                onTap: () => _apply(() => _sort = sort),
              ),
              const SizedBox(width: 8),
            ],
          ]),
        ),
      ],
    );
    return MgPage(
      title: l10n.storeCompleted,
      header: header,
      body: RefreshIndicator(
        onRefresh: _pager.reset,
        child: CustomScrollView(
          key: ValueKey('$_length-$_sort'),
          slivers: [
            StorePagedSliver(
              pager: _pager,
              itemBuilder: (context, book, _) => _BingeCard(book: book),
            ),
          ],
        ),
      ),
    );
  }
}

class _LengthCard extends StatelessWidget {
  const _LengthCard({
    required this.title,
    required this.range,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final String range;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final palette = MgPalette.of(context);
    final foreground = selected ? Colors.white : Theme.of(context).colorScheme.onSurface;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 80,
      decoration: BoxDecoration(
        color: selected ? accent : mgSheetGroupColor(context),
        borderRadius: BorderRadius.circular(14),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon, size: 18, color: selected ? Colors.white : accent),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, height: 1.25, fontWeight: FontWeight.w700, color: foreground)),
                  Text(range,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          height: 1.25,
                          color: selected ? Colors.white.withValues(alpha: .85) : palette.secondaryLabel)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A finished series led by its total length, with a short synopsis.
class _BingeCard extends StatelessWidget {
  const _BingeCard({required this.book});

  final StoreBook book;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final total = l10n.storeTotalVolumes(book.volumes);
    final words = storeWords(context, book.words);
    return InkWell(
      onTap: () => openStoreBook(context, book),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 80, child: StoreCover(url: book.coverLarge ?? book.cover, width: 80)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, height: 1.3, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    [total, if (words.isNotEmpty) words].join(' · '),
                    style: TextStyle(fontSize: 13, color: accent, fontWeight: FontWeight.w600),
                  ),
                  if ((book.description ?? '').isNotEmpty) ...[
                    const SizedBox(height: 5),
                    Text(book.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, height: 1.45, color: palette.secondaryLabel)),
                  ],
                  const SizedBox(height: 6),
                  Text(
                    [book.author, ...book.tags.take(3)].where((s) => s.isNotEmpty).join(' · '),
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
    );
  }
}
