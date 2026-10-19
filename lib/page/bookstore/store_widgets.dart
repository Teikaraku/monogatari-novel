import 'dart:async';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_detail_page.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Cover aspect ratio of bookstore cards (width / height).
const double storeCoverRatio = 0.72;

String storeWords(BuildContext context, int words) {
  if (words <= 0) return '';
  final zh = Localizations.localeOf(context).languageCode == 'zh';
  if (zh) {
    return words >= 10000 ? '${(words / 10000).toStringAsFixed(1)}万字' : '$words字';
  }
  return words >= 1000 ? '${(words / 1000).round()}K words' : '$words words';
}

String storeStatus(BuildContext context, StoreStatus status) => switch (status) {
      StoreStatus.completed => L10n.of(context).storeStatusCompleted,
      StoreStatus.ongoing => L10n.of(context).storeStatusOngoing,
      StoreStatus.unknown => '',
    };

/// "已完结 · 14.2万字 · 3卷" without empty parts.
String storeMetaLine(BuildContext context, StoreBook book) => [
      storeStatus(context, book.status),
      storeWords(context, book.words),
      if (book.volumes > 0) L10n.of(context).storeVolumeCount(book.volumes),
    ].where((part) => part.isNotEmpty).join(' · ');

void openStoreBook(BuildContext context, StoreBook book) {
  Navigator.of(context).push(CupertinoPageRoute(
    builder: (context) => StoreDetailPage(id: book.id, preview: book),
  ));
}

/// A network cover decoded at its display size, with a quiet placeholder.
class StoreCover extends StatelessWidget {
  const StoreCover({super.key, required this.url, this.width, this.radius = 8});

  final String? url;
  final double? width;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final placeholder = Container(
      color: palette.fill,
      alignment: Alignment.center,
      child: Icon(Icons.menu_book, color: palette.secondaryLabel.withValues(alpha: .5)),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: storeCoverRatio,
        child: url == null
            ? placeholder
            : LayoutBuilder(builder: (context, constraints) {
                final logical = width ?? constraints.maxWidth;
                final cacheWidth = logical.isFinite
                    ? (logical * MediaQuery.devicePixelRatioOf(context)).round()
                    : null;
                return CachedNetworkImage(
                  imageUrl: url!,
                  fit: BoxFit.cover,
                  memCacheWidth: cacheWidth,
                  fadeInDuration: const Duration(milliseconds: 150),
                  placeholder: (_, __) => Container(color: palette.fill),
                  errorWidget: (_, __, ___) => placeholder,
                );
              }),
      ),
    );
  }
}

/// A small pill drawn over a cover's corner.
class StoreBadge extends StatelessWidget {
  const StoreBadge({super.key, required this.text, this.color = MgColors.pink});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(5)),
        child: Text(text,
            maxLines: 1,
            style: const TextStyle(fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
      );
}

/// Cover, title and author; [overlay] and [badge] decorate the cover.
class StoreBookCard extends StatelessWidget {
  const StoreBookCard({
    super.key,
    required this.book,
    this.titleLines = 2,
    this.badge,
    this.overlay,
    this.subtitle,
  });

  final StoreBook book;
  final int titleLines;
  final Widget? badge;
  final String? overlay;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final second = subtitle ?? book.author;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => openStoreBook(context, book),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              StoreCover(url: book.cover),
              if (badge != null) Positioned(left: 6, top: 6, child: badge!),
              if (overlay != null && overlay!.isNotEmpty)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(7, 14, 7, 5),
                    decoration: const BoxDecoration(
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Color(0xB8000000)],
                      ),
                    ),
                    child: Text(overlay!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Colors.white, height: 1.25)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 7),
          Text(book.title,
              maxLines: titleLines,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 14, height: 1.35, fontWeight: FontWeight.w500)),
          if (second.isNotEmpty)
            Text(second,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, height: 1.4, color: palette.secondaryLabel)),
        ],
      ),
    );
  }
}

/// Three columns on phones, six on wide windows, aligned with the shelf headers.
class StoreBookGrid extends StatelessWidget {
  const StoreBookGrid({super.key, required this.books, this.badge, this.overlay});

  final List<StoreBook> books;
  final Widget? Function(StoreBook book)? badge;
  final String? Function(StoreBook book)? overlay;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final columns = metrics.columns;
    final rows = <Widget>[];
    for (var i = 0; i < books.length; i += columns) {
      final slice = books.sublist(i, i + columns > books.length ? books.length : i + columns);
      rows.add(Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var j = 0; j < columns; j++) ...[
            if (j > 0) const SizedBox(width: 12),
            Expanded(
              child: j < slice.length
                  ? StoreBookCard(
                      book: slice[j],
                      badge: badge?.call(slice[j]),
                      overlay: overlay?.call(slice[j]),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ],
      ));
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: metrics.inset),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            rows[i],
          ],
        ],
      ),
    );
  }
}

/// A sideways row of cards sized so a third of the next card peeks in.
class StoreBookRow extends StatelessWidget {
  const StoreBookRow({super.key, required this.books, this.badge, this.overlay, this.subtitle});

  final List<StoreBook> books;
  final Widget? Function(StoreBook book)? badge;
  final String? Function(StoreBook book)? overlay;
  final String? Function(StoreBook book)? subtitle;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final width = metrics.wide ? metrics.span(6) : (metrics.content - 24) / 3.3;
    final height = width / storeCoverRatio + 62;
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: metrics.inset),
        itemCount: books.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, index) => SizedBox(
          width: width,
          child: StoreBookCard(
            book: books[index],
            badge: badge?.call(books[index]),
            overlay: overlay?.call(books[index]),
            subtitle: subtitle?.call(books[index]),
          ),
        ),
      ),
    );
  }
}

/// A list row: cover, title, author and a meta line; [leading] (e.g. a rank) and [trailing] are optional.
class StoreBookTile extends StatelessWidget {
  const StoreBookTile({
    super.key,
    required this.book,
    this.leading,
    this.extra,
    this.coverWidth = 64,
    this.compact = false,
  });

  final StoreBook book;
  final Widget? leading;
  final String? extra;
  final double coverWidth;

  /// One-line title and no tags, so rows have a fixed height (home page charts).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final meta = storeMetaLine(context, book);
    return InkWell(
      onTap: () => openStoreBook(context, book),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 10)],
            SizedBox(width: coverWidth, child: StoreCover(url: book.cover, width: coverWidth, radius: 6)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      maxLines: compact ? 1 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600)),
                  if (book.author.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(book.author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
                    ),
                  if (meta.isNotEmpty || (extra?.isNotEmpty ?? false))
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        [if (extra?.isNotEmpty ?? false) extra!, if (meta.isNotEmpty) meta].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: palette.secondaryLabel),
                      ),
                    ),
                  if (!compact && book.tags.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Wrap(
                        spacing: 5,
                        runSpacing: 4,
                        children: [
                          for (final tag in book.tags.take(3))
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                              decoration: BoxDecoration(
                                color: palette.fill,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(tag,
                                  style: TextStyle(fontSize: 11, color: palette.secondaryLabel)),
                            ),
                        ],
                      ),
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

/// Rank number: bold accent for the top three, gray after.
class StoreRankNumber extends StatelessWidget {
  const StoreRankNumber({super.key, required this.rank});

  final int rank;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 28,
        child: Text(
          '$rank',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: rank <= 3 ? 20 : 17,
            fontWeight: rank <= 3 ? FontWeight.w800 : FontWeight.w600,
            color: rank <= 3 ? Theme.of(context).colorScheme.primary : MgPalette.of(context).secondaryLabel,
          ),
        ),
      );
}

/// The home carousel of curated wide images; advances every five seconds and restarts after a swipe.
class StoreBannerPager extends StatefulWidget {
  const StoreBannerPager({super.key, required this.banners});

  final List<StoreBanner> banners;

  @override
  State<StoreBannerPager> createState() => _StoreBannerPagerState();
}

class _StoreBannerPagerState extends State<StoreBannerPager> {
  PageController? _controller;
  double? _fraction;
  Timer? _timer;
  int _page = 0;

  void _schedule() {
    _timer?.cancel();
    if (widget.banners.length < 2) return;
    _timer = Timer(const Duration(seconds: 5), () {
      final controller = _controller;
      if (!mounted || controller == null || !controller.hasClients) return;
      final next = (_page + 1) % widget.banners.length;
      controller.animateToPage(next,
          duration: const Duration(milliseconds: 450), curve: Curves.easeOutCubic);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final pageWidth = metrics.wide
        ? metrics.span(metrics.width >= 1000 ? 3 : 2)
        : (metrics.width - 40).clamp(0, 520).toDouble();
    final pageHeight = pageWidth / 1.9;
    final fraction = ((pageWidth + 12) / metrics.width).clamp(0.1, 1.0);
    if (_fraction != fraction) {
      final old = _controller;
      _controller = PageController(viewportFraction: fraction, initialPage: _page);
      _fraction = fraction;
      WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
      _schedule();
    }
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Column(
      children: [
        SizedBox(
          height: pageHeight,
          child: PageView.builder(
            controller: _controller,
            padEnds: !metrics.wide,
            itemCount: widget.banners.length,
            onPageChanged: (page) {
              setState(() => _page = page);
              _schedule();
            },
            itemBuilder: (context, index) {
              final banner = widget.banners[index];
              final image = pageWidth * dpr > 700 ? banner.image : banner.imageSmall;
              return Padding(
                padding: EdgeInsets.only(
                  left: metrics.wide && index == 0 ? metrics.inset : 6,
                  right: 6,
                ),
                child: GestureDetector(
                  onTap: () => openStoreBook(context, banner.book),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CachedNetworkImage(
                          imageUrl: image,
                          fit: BoxFit.cover,
                          memCacheWidth: (pageWidth * dpr).round(),
                          fadeInDuration: const Duration(milliseconds: 200),
                          placeholder: (_, __) => Container(color: palette.fill),
                          errorWidget: (_, __, ___) => Container(color: palette.fill),
                        ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.center,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Color(0xAD000000)],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 14,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(banner.book.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 19, fontWeight: FontWeight.bold)),
                              if (banner.book.author.isNotEmpty)
                                Text(banner.book.author,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                        color: Colors.white.withValues(alpha: .9), fontSize: 12)),
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
        ),
        if (widget.banners.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.banners.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? accent : palette.separator,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Loads pages of books on demand as the list nears its end.
class StorePager extends ChangeNotifier {
  StorePager(this._load, {this.pageSize = 30});

  final Future<StorePage> Function(int offset, int limit) _load;
  final int pageSize;
  final items = <StoreBook>[];
  int? total;
  bool loading = false;
  Object? error;

  bool get done => total != null && items.length >= total!;

  Future<void> more() async {
    if (loading || done) return;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final page = await _load(items.length, pageSize);
      total = page.total;
      items.addAll(page.items);
      if (page.items.isEmpty) total = items.length;
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> reset() async {
    items.clear();
    total = null;
    error = null;
    notifyListeners();
    await more();
  }
}

/// A sliver list or grid fed by a [StorePager]; asks for the next page when the user nears the end.
class StorePagedSliver extends StatelessWidget {
  const StorePagedSliver({super.key, required this.pager, required this.itemBuilder, this.grid = false});

  final StorePager pager;
  final Widget Function(BuildContext context, StoreBook book, int index) itemBuilder;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: pager,
      builder: (context, _) {
        final metrics = MgShelfMetrics.of(context);
        final count = pager.items.length;
        Widget build(BuildContext context, int index) {
          if (index >= count - 8 && !pager.done && !pager.loading && pager.error == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => pager.more());
          }
          return itemBuilder(context, pager.items[index], index);
        }

        final footer = SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: pager.error != null
                  ? TextButton(onPressed: pager.more, child: Text(L10n.of(context).storeRetry))
                  : pager.loading
                      ? const SizedBox(
                          width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                      : const SizedBox.shrink(),
            ),
          ),
        );
        if (pager.done && count == 0) {
          return SliverFillRemaining(
            hasScrollBody: false,
            child: MgEmptyState(icon: Icons.search_off, title: L10n.of(context).storeNoResults),
          );
        }
        final body = grid
            ? SliverPadding(
                padding: EdgeInsets.fromLTRB(metrics.inset, 8, metrics.inset, 0),
                sliver: SliverGrid(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: metrics.columns,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 16,
                    childAspectRatio: metrics.span(metrics.columns) /
                        (metrics.span(metrics.columns) / storeCoverRatio + 64),
                  ),
                  delegate: SliverChildBuilderDelegate(build, childCount: count),
                ),
              )
            : SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: 16 + mgCenteredInset(context, mgDetailWidth)),
                sliver: SliverList(delegate: SliverChildBuilderDelegate(build, childCount: count)),
              );
        return SliverMainAxisGroup(slivers: [body, footer]);
      },
    );
  }
}
