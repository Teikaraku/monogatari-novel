import 'dart:math';
import 'dart:ui';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Browsing for its own sake: a daily pick, a shuffle of six, rotating theme shelves and an endless
/// random wall at the bottom.
class StoreDiscoverPage extends ConsumerStatefulWidget {
  const StoreDiscoverPage({super.key});

  @override
  ConsumerState<StoreDiscoverPage> createState() => _StoreDiscoverPageState();
}

class _StoreDiscoverPageState extends ConsumerState<StoreDiscoverPage> {
  final _random = Random();
  late int _shuffleSeed = _random.nextInt(1 << 31);
  late final int _wallSeed = _random.nextInt(1 << 31);
  late Future<StorePage> _shuffle = _loadShuffle();
  late final StorePager _wall = StorePager(
    (offset, limit) => BookstoreApi.instance.books(sort: StoreSort.random, seed: _wallSeed, offset: offset, limit: limit),
  )..more();

  Future<StorePage> _loadShuffle() =>
      BookstoreApi.instance.books(sort: StoreSort.random, seed: _shuffleSeed, limit: 6);

  void _reshuffle() => setState(() {
        _shuffleSeed = _random.nextInt(1 << 31);
        _shuffle = _loadShuffle();
      });

  @override
  void dispose() {
    _wall.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final discover = ref.watch(storeDiscoverProvider);
    final metrics = MgShelfMetrics.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final data = discover.valueOrNull;
    return MgPage(
      title: l10n.storeDiscover,
      body: CustomScrollView(
        slivers: [
          if (data?.pick != null) SliverToBoxAdapter(child: _PickCard(book: data!.pick!)),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(left: metrics.inset, right: metrics.inset - 8, top: 18, bottom: 6),
              child: Row(
                children: [
                  Container(
                    width: 4,
                    height: 19,
                    decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(l10n.storeShuffle, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                  ),
                  TextButton.icon(
                    onPressed: _reshuffle,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: Text(l10n.storeRefresh),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: FutureBuilder<StorePage>(
              future: _shuffle,
              builder: (context, snapshot) => AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: snapshot.hasData
                    ? StoreBookGrid(key: ValueKey(_shuffleSeed), books: snapshot.data!.items)
                    : SizedBox(key: const ValueKey('loading'), height: metrics.span(3) / storeCoverRatio * 2 + 140),
              ),
            ),
          ),
          for (final (index, theme) in (data?.themes ?? const <StoreTheme>[]).indexed) ...[
            SliverToBoxAdapter(
              child: MgShelfHeader(
                title: theme.title,
                moreLabel: '${l10n.storeMore} ${theme.total}',
                onMore: () => Navigator.of(context).push(CupertinoPageRoute(
                  builder: (_) => StoreThemePage(theme: theme),
                )),
              ),
            ),
            SliverToBoxAdapter(
              child: index.isEven ? StoreBookRow(books: theme.items) : _ThemeCards(books: theme.items),
            ),
          ],
          SliverToBoxAdapter(child: MgShelfHeader(title: l10n.storeBrowse)),
          StorePagedSliver(
            pager: _wall,
            grid: true,
            itemBuilder: (context, book, _) => StoreBookCard(book: book),
          ),
        ],
      ),
    );
  }
}

/// The daily pick on its own blurred cover.
class _PickCard extends StatelessWidget {
  const _PickCard({required this.book});

  final StoreBook book;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final metrics = MgShelfMetrics.of(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cover = book.coverLarge ?? book.cover;
    return Padding(
      padding: EdgeInsets.fromLTRB(metrics.inset, 4, metrics.inset, 6),
      child: GestureDetector(
        onTap: () => openStoreBook(context, book),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              if (cover != null)
                Positioned.fill(
                  child: ImageFiltered(
                    imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: CachedNetworkImage(imageUrl: cover, fit: BoxFit.cover, memCacheWidth: (120 * dpr).round()),
                  ),
                ),
              Positioned.fill(child: Container(color: Colors.black.withValues(alpha: .45))),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 108, child: StoreCover(url: cover, width: 108)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l10n.storeTodayPick,
                              style: TextStyle(
                                  color: Colors.white.withValues(alpha: .8),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 1)),
                          const SizedBox(height: 6),
                          Text(book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 21, height: 1.25, fontWeight: FontWeight.w800)),
                          const SizedBox(height: 4),
                          Text(book.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.white.withValues(alpha: .85), fontSize: 13)),
                          const SizedBox(height: 8),
                          Text(book.description ?? '',
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: Colors.white.withValues(alpha: .85), fontSize: 13, height: 1.5)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Two-up cards: a cover beside title, author and tags.
class _ThemeCards extends StatelessWidget {
  const _ThemeCards({required this.books});

  final List<StoreBook> books;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final palette = MgPalette.of(context);
    final width = metrics.wide ? metrics.span(3) : metrics.content * .74;
    const coverWidth = 70.0;
    return SizedBox(
      height: coverWidth / storeCoverRatio + 20,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: metrics.inset),
        itemCount: books.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final book = books[index];
          return SizedBox(
            width: width,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => openStoreBook(context, book),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: coverWidth, child: StoreCover(url: book.cover, width: coverWidth, radius: 6)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, height: 1.3, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 3),
                          Text(book.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                          const Spacer(),
                          Text(storeMetaLine(context, book),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Every book of one theme, shuffled.
class StoreThemePage extends StatefulWidget {
  const StoreThemePage({super.key, required this.theme});

  final StoreTheme theme;

  @override
  State<StoreThemePage> createState() => _StoreThemePageState();
}

class _StoreThemePageState extends State<StoreThemePage> {
  final int _seed = Random().nextInt(1 << 31);
  late final StorePager _pager = StorePager(
    (offset, limit) => BookstoreApi.instance.theme(widget.theme.key, seed: _seed, offset: offset, limit: limit),
  )..more();

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    return MgPage(
      title: widget.theme.title,
      header: Padding(
        padding: EdgeInsets.fromLTRB(metrics.inset, 0, metrics.inset, 10),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final tag in widget.theme.tags)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: .1),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(tag,
                    style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.primary)),
              ),
          ],
        ),
      ),
      body: CustomScrollView(
        slivers: [
          StorePagedSliver(pager: _pager, grid: true, itemBuilder: (context, book, _) => StoreBookCard(book: book)),
        ],
      ),
    );
  }
}
