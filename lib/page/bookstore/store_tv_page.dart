import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:flutter/material.dart';

/// Anime adaptations as a season timeline: this season's shows on wide cards, announced shows
/// grouped by season along a timeline, and past seasons as cover walls grouped by year.
class StoreTvPage extends StatefulWidget {
  const StoreTvPage({super.key});

  @override
  State<StoreTvPage> createState() => _StoreTvPageState();
}

class _StoreTvPageState extends State<StoreTvPage> {
  final _airing = StorePager((o, l) => BookstoreApi.instance.tv(StoreTvStatus.airing, offset: o, limit: l), pageSize: 60);
  final _upcoming = StorePager((o, l) => BookstoreApi.instance.tv(StoreTvStatus.upcoming, offset: o, limit: l), pageSize: 60);
  final _aired = StorePager((o, l) => BookstoreApi.instance.tv(StoreTvStatus.completed, offset: o, limit: l), pageSize: 60);

  @override
  void initState() {
    super.initState();
    _airing.more();
    _upcoming.more();
    _aired.more();
  }

  @override
  void dispose() {
    _airing.dispose();
    _upcoming.dispose();
    _aired.dispose();
    super.dispose();
  }

  Future<void> _refresh() => Future.wait([_airing.reset(), _upcoming.reset(), _aired.reset()]);

  static String currentSeason() {
    final now = DateTime.now();
    return '${now.year}年${'冬春夏秋'[(now.month - 1) ~/ 3]}';
  }

  /// Consecutive runs of [books] sharing a key, in order.
  static List<(String, List<StoreBook>)> _group(List<StoreBook> books, String Function(StoreBook) key) {
    final groups = <(String, List<StoreBook>)>[];
    for (final book in books) {
      final k = key(book);
      if (groups.isEmpty || groups.last.$1 != k) groups.add((k, []));
      groups.last.$2.add(book);
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final metrics = MgShelfMetrics.of(context);
    return MgPage(
      title: l10n.storeAnime,
      body: ListenableBuilder(
        listenable: Listenable.merge([_airing, _upcoming, _aired]),
        builder: (context, _) {
          if (_airing.items.isEmpty && _upcoming.items.isEmpty && _aired.items.isEmpty) {
            final error = _airing.error ?? _upcoming.error ?? _aired.error;
            return error != null
                ? MgEmptyState(icon: Icons.wifi_off, title: l10n.storeOffline, action: l10n.storeRetry, onAction: _refresh)
                : const Center(child: CircularProgressIndicator(strokeWidth: 2));
          }
          final upcoming = _group(_upcoming.items, (b) => b.tv?.season.isNotEmpty == true ? b.tv!.season : l10n.storeTvUpcoming);
          final years = _group(_aired.items, (b) {
            final season = b.tv?.season ?? '';
            final year = RegExp(r'^\d{4}').stringMatch(season);
            return year ?? (season.isNotEmpty ? season : l10n.storeTvAired);
          });
          return RefreshIndicator(
            onRefresh: _refresh,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification.metrics.extentAfter < 800) _aired.more();
                return false;
              },
              child: CustomScrollView(
                slivers: [
                  if (_airing.items.isNotEmpty) ...[
                    SliverToBoxAdapter(
                      child: _SeasonHeader(
                        season: currentSeason(),
                        label: l10n.storeTvAiring,
                        count: _airing.total ?? _airing.items.length,
                      ),
                    ),
                    SliverToBoxAdapter(child: _AiringRow(books: _airing.items)),
                  ],
                  if (upcoming.isNotEmpty) ...[
                    SliverToBoxAdapter(child: MgShelfHeader(title: l10n.storeTvUpcoming)),
                    for (final (season, books) in upcoming)
                      SliverToBoxAdapter(child: _TimelineGroup(season: season, books: books)),
                  ],
                  if (years.isNotEmpty) ...[
                    SliverToBoxAdapter(child: MgShelfHeader(title: l10n.storeTvAired)),
                    for (final (year, books) in years) ...[
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(metrics.inset, 14, metrics.inset, 10),
                          child: Text(year,
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: MgPalette.of(context).secondaryLabel)),
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: StoreBookGrid(
                          books: books,
                          overlay: (book) => book.tv?.studio.isNotEmpty == true ? book.tv!.studio : book.tv?.season,
                        ),
                      ),
                    ],
                  ],
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 48 + MediaQuery.paddingOf(context).bottom,
                      child: _aired.loading
                          ? const Center(
                              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                          : null,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SeasonHeader extends StatelessWidget {
  const _SeasonHeader({required this.season, required this.label, required this.count});

  final String season;
  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.fromLTRB(metrics.inset, 6, metrics.inset, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(season, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(6)),
              child: Text('$label · $count',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
        ],
      ),
    );
  }
}

/// This season's shows: wide tinted cards that page sideways.
class _AiringRow extends StatelessWidget {
  const _AiringRow({required this.books});

  final List<StoreBook> books;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final cardWidth = metrics.wide ? metrics.span(2) : metrics.content * .82;
    const coverWidth = 96.0;
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
              color: accent.withValues(alpha: .07),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => openStoreBook(context, book),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: coverWidth, child: StoreCover(url: book.coverLarge ?? book.cover, width: coverWidth)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(book.title,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17, height: 1.3, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 6),
                            if (book.tv?.studio.isNotEmpty == true)
                              Row(children: [
                                Icon(Icons.movie_creation_outlined, size: 15, color: accent),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(book.tv!.studio,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 13, color: accent, fontWeight: FontWeight.w600)),
                                ),
                              ]),
                            const Spacer(),
                            Text(book.author,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
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
            ),
          );
        },
      ),
    );
  }
}

/// One announced season on the timeline: a dot and label on the rail, then its shows.
class _TimelineGroup extends StatelessWidget {
  const _TimelineGroup({required this.season, required this.books});

  final String season;
  final List<StoreBook> books;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(left: metrics.inset, right: metrics.inset),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: 18,
              child: Column(
                children: [
                  const SizedBox(height: 6),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  ),
                  Expanded(child: Container(width: 2, color: accent.withValues(alpha: .2))),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(season, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: accent)),
                  const SizedBox(height: 4),
                  for (final book in books)
                    InkWell(
                      onTap: () => openStoreBook(context, book),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(width: 48, child: StoreCover(url: book.cover, width: 48, radius: 6)),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(book.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  Text(
                                    [book.tv?.badge ?? '', book.tv?.studio ?? '']
                                        .where((s) => s.isNotEmpty)
                                        .join(' · '),
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
                    ),
                  const SizedBox(height: 10),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
