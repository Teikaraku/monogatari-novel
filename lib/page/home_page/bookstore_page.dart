import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_catalog_page.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/bookstore/store_category_page.dart';
import 'package:anx_reader/page/bookstore/store_completed_page.dart';
import 'package:anx_reader/page/bookstore/store_discover_page.dart';
import 'package:anx_reader/page/bookstore/store_rank_page.dart';
import 'package:anx_reader/page/bookstore/store_search_page.dart';
import 'package:anx_reader/page/bookstore/store_tv_page.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The online light-novel library: curated banners, shortcuts and shelves, like the manga app's bookstore.
class BookstorePage extends ConsumerWidget {
  const BookstorePage({super.key});

  void _push(BuildContext context, Widget page) =>
      Navigator.of(context).push(CupertinoPageRoute(builder: (_) => page));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    ref.listen(homeTabProvider, (_, tab) {
      if (tab == 1) refreshStoreHomeIfStale(ref.read(storeHomeRefreshProvider.notifier));
    });
    final home = ref.watch(storeHomeProvider);
    final accent = Theme.of(context).colorScheme.primary;
    final header = SafeArea(
      bottom: false,
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: const EdgeInsets.only(left: 20, right: 8),
          child: Row(
            children: [
              Text(l10n.navBarBookstore,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.search, color: accent),
                tooltip: l10n.navBarSearch,
                onPressed: () => _push(context, const StoreSearchPage()),
              ),
            ],
          ),
        ),
      ),
    );

    Widget body;
    if (home.hasValue) {
      body = RefreshIndicator(
        onRefresh: () async {
          ref.read(storeHomeRefreshProvider.notifier).state++;
          shuffleStoreRandomPicks(ref);
          await ref.read(storeHomeProvider.future).catchError((_) => home.value!);
        },
        child: _HomeContent(home: home.value!, push: (page) => _push(context, page)),
      );
    } else if (home.hasError) {
      body = MgEmptyState(
        icon: Icons.wifi_off,
        title: l10n.storeOffline,
        action: l10n.storeRetry,
        onAction: () => ref.read(storeHomeRefreshProvider.notifier).state++,
      );
    } else {
      body = const _HomeSkeleton();
    }

    return Scaffold(
      backgroundColor: MgPalette.of(context).page,
      body: Column(children: [header, Expanded(child: body)]),
    );
  }
}

class _HomeContent extends StatelessWidget {
  const _HomeContent({required this.home, required this.push});

  final StoreHome home;
  final void Function(Widget page) push;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final metrics = MgShelfMetrics.of(context);
    final featured = home.section('featured');
    final picks = home.section('picks');
    final rank = home.section('rank');
    final recent = home.section('recent');
    final tv = home.section('tv');
    final completed = home.section('completed');
    final long = home.section('long');

    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      slivers: [
        if (home.banners.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: StoreBannerPager(banners: home.banners),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(metrics.inset - 8, 14, metrics.inset - 8, 4),
            child: Row(
              children: [
                Expanded(
                    child: MgShortcut(
                        title: l10n.storeDiscover,
                        icon: Icons.explore_outlined,
                        onTap: () => push(const StoreDiscoverPage()))),
                Expanded(
                    child: MgShortcut(
                        title: l10n.storeCategories,
                        icon: Icons.grid_view_rounded,
                        onTap: () => push(const StoreCategoryPage()))),
                Expanded(
                    child: MgShortcut(
                        title: l10n.storeRankings,
                        icon: Icons.bar_chart_rounded,
                        onTap: () => push(const StoreRankPage()))),
                Expanded(
                    child: MgShortcut(
                        title: l10n.storeCompleted,
                        icon: Icons.task_alt,
                        onTap: () => push(const StoreCompletedPage()))),
                Expanded(
                    child: MgShortcut(
                        title: l10n.storeAnime,
                        icon: Icons.live_tv_outlined,
                        onTap: () => push(const StoreTvPage()))),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(child: _RandomPicks(fallback: featured)),
        if (picks.isNotEmpty) ...[
          SliverToBoxAdapter(child: MgShelfHeader(title: l10n.storePicks)),
          SliverToBoxAdapter(child: StoreBookGrid(books: picks)),
        ],
        if (rank.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: MgShelfHeader(
              title: l10n.storePopular,
              moreLabel: l10n.storeMore,
              onMore: () => push(const StoreRankPage()),
            ),
          ),
          SliverToBoxAdapter(child: _RankColumns(books: rank)),
        ],
        if (recent.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: MgShelfHeader(
              title: l10n.storeRecent,
              moreLabel: l10n.storeMore,
              onMore: () => push(const StoreCatalogPage()),
            ),
          ),
          SliverToBoxAdapter(
            child: StoreBookRow(books: recent, overlay: (book) => book.updated),
          ),
        ],
        if (tv.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: MgShelfHeader(
              title: l10n.storeAnime,
              moreLabel: l10n.storeMore,
              onMore: () => push(const StoreTvPage()),
            ),
          ),
          SliverToBoxAdapter(
            child: StoreBookRow(
              books: tv,
              badge: (book) => storeTvBadge(context, book),
              overlay: (book) => book.tv?.studio,
            ),
          ),
        ],
        if (completed.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: MgShelfHeader(
              title: l10n.storeCompletedPicks,
              moreLabel: l10n.storeMore,
              onMore: () => push(const StoreCompletedPage()),
            ),
          ),
          SliverToBoxAdapter(child: StoreBookGrid(books: completed)),
        ],
        if (long.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: MgShelfHeader(
              title: l10n.storeLong,
              moreLabel: l10n.storeMore,
              onMore: () => push(const StoreCatalogPage(sort: StoreSort.volumes)),
            ),
          ),
          SliverToBoxAdapter(
            child: StoreBookRow(
              books: long,
              overlay: (book) => l10n.storeVolumeCount(book.volumes),
            ),
          ),
        ],
        if (home.tags.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: MgShelfHeader(
              title: l10n.storeTags,
              moreLabel: l10n.storeMore,
              onMore: () => push(const StoreCategoryPage()),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: metrics.inset),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tag in home.tags)
                    MgChip(
                      label: tag.name,
                      selected: false,
                      checkmark: false,
                      onTap: () => push(StoreCatalogPage(tags: [tag.name])),
                    ),
                ],
              ),
            ),
          ),
        ],
        SliverToBoxAdapter(child: SizedBox(height: 28 + MediaQuery.paddingOf(context).bottom)),
      ],
    );
  }
}

/// TV status pill for a cover: airing in the accent, upcoming in blue with its season.
Widget? storeTvBadge(BuildContext context, StoreBook book) {
  final tv = book.tv;
  if (tv == null) return null;
  final l10n = L10n.of(context);
  return switch (tv.status) {
    StoreTvStatus.airing => StoreBadge(text: l10n.storeTvAiring),
    StoreTvStatus.upcoming =>
      StoreBadge(text: tv.season.isNotEmpty ? tv.season : l10n.storeTvUpcoming, color: MgColors.blue),
    StoreTvStatus.completed =>
      tv.season.isNotEmpty ? StoreBadge(text: tv.season, color: const Color(0x99000000)) : null,
  };
}

/// Random picks: a new draw each launch and on "shuffle"; the home's daily featured set stands in until it lands.
class _RandomPicks extends ConsumerWidget {
  const _RandomPicks({required this.fallback});

  final List<StoreBook> fallback;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    final drawn = ref.watch(storeRandomPicksProvider).valueOrNull;
    final books = drawn == null || drawn.isEmpty ? fallback : drawn;
    if (books.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MgShelfHeader(
          title: l10n.storeRandomPicks,
          moreLabel: l10n.storeRefresh,
          moreIcon: Icons.refresh_rounded,
          onMore: () => shuffleStoreRandomPicks(ref),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: _FeaturedRow(key: ValueKey(books.map((b) => b.id).join(',')), books: books),
        ),
      ],
    );
  }
}

/// Wide cards with the cover beside a short synopsis.
class _FeaturedRow extends StatelessWidget {
  const _FeaturedRow({super.key, required this.books});

  final List<StoreBook> books;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final palette = MgPalette.of(context);
    final cardWidth = metrics.wide ? metrics.span(3) : metrics.content * .86;
    const coverWidth = 84.0;
    return SizedBox(
      height: coverWidth / storeCoverRatio + 24,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: metrics.inset),
        itemCount: books.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) {
          final book = books[index];
          return SizedBox(
            width: cardWidth,
            child: Material(
              color: mgSheetGroupColor(context),
              borderRadius: BorderRadius.circular(14),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => openStoreBook(context, book),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                          width: coverWidth,
                          child: StoreCover(url: book.cover, width: coverWidth, radius: 6)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(book.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    fontSize: 16, height: 1.3, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            Text(book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                            const SizedBox(height: 6),
                            Expanded(
                              // As many whole lines as fit under a one- or two-line title.
                              child: LayoutBuilder(builder: (context, box) {
                                final line = MediaQuery.textScalerOf(context).scale(13) * 1.45;
                                final lines = (box.maxHeight / line).floor();
                                if (lines < 1) return const SizedBox.shrink();
                                return Text(
                                    (book.description ?? '').replaceAll(RegExp(r'\s*\n+\s*'), ''),
                                    maxLines: lines,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        fontSize: 13, height: 1.45, color: palette.secondaryLabel));
                              }),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The weekly top ten as two swipeable columns of five ranked rows.
class _RankColumns extends StatelessWidget {
  const _RankColumns({required this.books});

  final List<StoreBook> books;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final l10n = L10n.of(context);
    final columns = <List<StoreBook>>[];
    for (var i = 0; i < books.length; i += 5) {
      columns.add(books.sublist(i, i + 5 > books.length ? books.length : i + 5));
    }
    final columnWidth = metrics.wide ? metrics.span(2) : metrics.content * .88;
    return SizedBox(
      height: 5 * (52 / storeCoverRatio + 16),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: metrics.inset),
        itemCount: columns.length,
        separatorBuilder: (_, __) => const SizedBox(width: 16),
        itemBuilder: (context, column) => SizedBox(
          width: columnWidth,
          child: Column(
            children: [
              for (var i = 0; i < columns[column].length; i++)
                StoreBookTile(
                  book: columns[column][i],
                  coverWidth: 52,
                  compact: true,
                  leading: StoreRankNumber(rank: column * 5 + i + 1),
                  extra: (columns[column][i].readers ?? 0) > 0
                      ? l10n.storeReaders(columns[column][i].readers!)
                      : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final fill = MgPalette.of(context).fill;
    Widget block(double height, {double? width, double radius = 12}) => Container(
          height: height,
          width: width,
          decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(radius)),
        );
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.symmetric(horizontal: metrics.inset, vertical: 4),
      children: [
        block((metrics.width - 40).clamp(0, 520) / 1.9, radius: 18),
        const SizedBox(height: 28),
        Row(children: [
          for (var i = 0; i < 5; i++)
            Expanded(child: Center(child: block(44, width: 44, radius: 14))),
        ]),
        const SizedBox(height: 32),
        block(20, width: 120, radius: 4),
        const SizedBox(height: 14),
        Row(children: [
          for (var i = 0; i < 3; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: AspectRatio(aspectRatio: storeCoverRatio, child: block(0, radius: 8))),
          ],
        ]),
      ],
    );
  }
}
