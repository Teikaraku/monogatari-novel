import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_catalog_page.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:anx_reader/service/bookstore/store_library.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class StoreDetailPage extends ConsumerWidget {
  const StoreDetailPage({super.key, required this.id, this.preview});

  final String id;

  /// The summary the user tapped, shown at once while the details load.
  final StoreBook? preview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(storeBookProvider(id));
    final palette = MgPalette.of(context);
    final book = detail.valueOrNull?.book ?? preview;
    final accent = Theme.of(context).colorScheme.primary;
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
                    IconButton(
                      icon: Icon(Icons.arrow_back, color: accent),
                      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
            Expanded(
              child: book == null
                  ? detail.hasError
                      ? MgEmptyState(
                          icon: Icons.wifi_off,
                          title: L10n.of(context).storeOffline,
                          action: L10n.of(context).storeRetry,
                          onAction: () => ref.invalidate(storeBookProvider(id)),
                        )
                      : const Center(child: CircularProgressIndicator(strokeWidth: 2))
                  : _DetailBody(book: book, detail: detail.valueOrNull),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.book, required this.detail});

  final StoreBook book;
  final StoreBookDetail? detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final inset = 20 + mgCenteredInset(context, mgDetailWidth);
    final progress = ref.watch(storeProgressProvider(book.id));
    final inShelf = ref.watch(storeShelfProvider).contains(book.id);
    final volumes = detail?.volumeList ?? const <StoreVolume>[];
    final resume = progress.valueOrNull;
    final tv = detail?.book.tv;

    void read([StoreVolume? volume]) {
      final details = detail;
      if (details == null || details.volumeList.isEmpty) return;
      final target = volume ??
          details.volumeList.firstWhere((v) => v.n == resume?.volume,
              orElse: () => details.volumeList.first);
      StoreLibrary.instance.open(context, ref, details, target);
    }

    return ListView(
      padding: EdgeInsets.fromLTRB(inset, 4, inset, 32 + MediaQuery.paddingOf(context).bottom),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 112, child: StoreCover(url: book.coverLarge ?? book.cover, width: 112)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(book.title,
                      style: const TextStyle(fontSize: 22, height: 1.3, fontWeight: FontWeight.bold)),
                  if (book.author.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(book.author,
                          style: TextStyle(
                              fontSize: 15, color: Theme.of(context).colorScheme.primary)),
                    ),
                  if ((detail?.illustrator ?? '').isNotEmpty || (detail?.publisher ?? '').isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        [detail!.illustrator, detail!.publisher].where((s) => s.isNotEmpty).join(' · '),
                        style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(storeMetaLine(context, book),
                        style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
                  ),
                  if (book.updated.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(book.updated,
                          style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
                    ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: volumes.isEmpty ? null : () => read(),
                icon: const Icon(Icons.menu_book, size: 20),
                label: Text(resume == null
                    ? l10n.storeStartReading
                    : '${l10n.storeContinueReading} · ${_volumeName(volumes, resume.volume)}'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 46,
              child: OutlinedButton.icon(
                onPressed: () => StoreLibrary.instance.toggleShelf(ref, detail?.book ?? book),
                icon: Icon(inShelf ? Icons.bookmark : Icons.bookmark_add_outlined,
                    size: 20, color: inShelf ? Theme.of(context).colorScheme.primary : null),
                label: Text(inShelf ? l10n.storeInShelf : l10n.storeAddToShelf),
              ),
            ),
          ],
        ),
        if (tv != null) ...[
          const SizedBox(height: 14),
          _TvStrip(tv: tv),
        ],
        if (book.tags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final tag in (detail?.book.tags ?? book.tags))
                MgChip(
                  label: tag,
                  selected: false,
                  checkmark: false,
                  onTap: () => Navigator.of(context).push(CupertinoPageRoute(
                    builder: (_) => StoreCatalogPage(tags: [tag]),
                  )),
                ),
            ],
          ),
        ],
        if ((detail?.description ?? '').isNotEmpty) ...[
          const SizedBox(height: 22),
          Text(l10n.storeSynopsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          MgExpandableText(detail!.description),
        ],
        if (volumes.isNotEmpty) ...[
          const SizedBox(height: 22),
          Text('${l10n.storeVolumes} · ${volumes.length}',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          for (final volume in volumes)
            _VolumeRow(
              bookId: book.id,
              volume: volume,
              current: resume?.volume == volume.n,
              percent: resume?.volume == volume.n ? resume?.percent : null,
              onTap: () => read(volume),
              onChapter: (href) {
                final details = detail;
                if (details != null) StoreLibrary.instance.open(context, ref, details, volume, href: href);
              },
            ),
        ],
      ],
    );
  }

  String _volumeName(List<StoreVolume> volumes, int n) {
    final volume = volumes.where((v) => v.n == n).firstOrNull;
    if (volume == null) return '$n';
    return volume.label.length > 12 ? '${volume.label.substring(0, 12)}…' : volume.label;
  }
}

class _TvStrip extends StatelessWidget {
  const _TvStrip({required this.tv});

  final StoreTv tv;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final status = switch (tv.status) {
      StoreTvStatus.airing => l10n.storeTvAiring,
      StoreTvStatus.upcoming => tv.badge.isNotEmpty ? tv.badge : l10n.storeTvUpcoming,
      StoreTvStatus.completed => l10n.storeTvAired,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: mgSheetGroupColor(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.live_tv_outlined, size: 20, color: MgColors.pink),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              [l10n.storeAnime, tv.season, tv.studio, status].where((s) => s.isNotEmpty).join(' · '),
              style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
            ),
          ),
        ],
      ),
    );
  }
}

class _VolumeRow extends StatefulWidget {
  const _VolumeRow({
    required this.bookId,
    required this.volume,
    required this.current,
    required this.percent,
    required this.onTap,
    required this.onChapter,
  });

  final String bookId;
  final StoreVolume volume;
  final bool current;
  final double? percent;
  final VoidCallback onTap;
  final ValueChanged<String> onChapter;

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

/// A volume: tap to read it; volumes with a table of contents unfold their chapters in place.
class _VolumeRowState extends State<_VolumeRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final volume = widget.volume;
    final size = volume.size >= 1 << 20
        ? '${(volume.size / (1 << 20)).toStringAsFixed(1)} MB'
        : '${(volume.size / 1024).round()} KB';
    final meta = [
      size,
      if (volume.chapters > 0) l10n.storeChapterCount(volume.chapters),
      if (widget.percent != null) '${(widget.percent! * 100).round()}%',
    ].join(' · ');
    final expandable = volume.chapters > 0;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.separator, width: .5))),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: widget.onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 52),
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(volume.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: widget.current ? FontWeight.w600 : FontWeight.normal,
                              color: widget.current ? accent : null,
                            )),
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(meta, style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                        ),
                      ],
                    ),
                  ),
                  if (expandable)
                    IconButton(
                      tooltip: _open ? l10n.storeHideChapters : l10n.storeShowChapters,
                      onPressed: () => setState(() => _open = !_open),
                      icon: AnimatedRotation(
                        turns: _open ? .5 : 0,
                        duration: const Duration(milliseconds: 200),
                        child: Icon(Icons.expand_more, color: palette.secondaryLabel),
                      ),
                    )
                  else
                    Icon(Icons.chevron_right, color: palette.secondaryLabel.withValues(alpha: .7)),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _open
                ? _VolumeChapters(bookId: widget.bookId, n: volume.n, onChapter: widget.onChapter)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

class _VolumeChapters extends ConsumerWidget {
  const _VolumeChapters({required this.bookId, required this.n, required this.onChapter});

  final String bookId;
  final int n;
  final ValueChanged<String> onChapter;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = MgPalette.of(context);
    final toc = ref.watch(storeVolumeTocProvider((bookId, n)));
    return toc.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (_, __) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextButton.icon(
          onPressed: () => ref.invalidate(storeVolumeTocProvider((bookId, n))),
          icon: const Icon(Icons.refresh, size: 18),
          label: Text(L10n.of(context).storeRetry),
        ),
      ),
      data: (items) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final item in items)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => onChapter(item.href),
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12.0 + 16 * item.level.clamp(0, 3), 9, 8, 9),
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: item.level == 0 ? 14 : 13,
                      height: 1.35,
                      color: item.level == 0 ? null : palette.secondaryLabel,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
