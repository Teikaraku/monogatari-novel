import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_detail_page.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/bookstore/store_library.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

/// One row of the history tab: a shelf book, or a bookstore series with its last-read volume.
sealed class HistoryEntry {
  const HistoryEntry(this.time, this.title, this.author, this.percent);

  final DateTime time;
  final String title;
  final String author;
  final double percent;
}

class ShelfHistoryEntry extends HistoryEntry {
  ShelfHistoryEntry(this.book)
      : super(book.updateTime, book.title, book.author, book.readingPercentage);

  final Book book;
}

class StoreHistoryEntry extends HistoryEntry {
  StoreHistoryEntry(this.record, this.volume)
      : super(record.lastReadTime!, record.title, record.author, volume?.readingPercentage ?? 0);

  final StoreRecord record;

  /// The hidden book row of the last-read volume; null if it was never opened on this device.
  final Book? volume;
}

/// Recently read shelf books and bookstore series; recomputed when the shelf or the store history changes.
final readingHistoryProvider = FutureProvider.autoDispose<List<HistoryEntry>>((ref) async {
  ref.watch(bookListProvider);
  final store = await ref.watch(storeHistoryProvider.future);
  final shelf = await bookDao.selectReadingHistory();
  final volumes = {
    for (final row in await bookDao.selectBooks(includeDeleted: false, includeStore: true))
      if (row.storeKey != null) row.storeKey!: row,
  };
  return [
    ...shelf.map(ShelfHistoryEntry.new),
    ...store.map((record) =>
        StoreHistoryEntry(record, volumes['${record.storeId}/${record.lastVolume}'])),
  ]..sort((a, b) => b.time.compareTo(a.time));
});

class HistoryPage extends ConsumerStatefulWidget {
  const HistoryPage({super.key});

  @override
  ConsumerState<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends ConsumerState<HistoryPage> {
  String _query = '';

  String _day(BuildContext context, DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final difference = today.difference(day).inDays;
    final locale = Localizations.localeOf(context).toString();
    if (difference == 0) return locale.startsWith('zh') ? '今天' : 'Today';
    if (difference == 1) return locale.startsWith('zh') ? '昨天' : 'Yesterday';
    if (difference < 7) return DateFormat.EEEE(locale).format(date);
    if (date.year == now.year) return DateFormat.MMMd(locale).format(date);
    return DateFormat.yMMMd(locale).format(date);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final history = ref.watch(readingHistoryProvider);
    final query = _query.trim().toLowerCase();
    return MgPage(
      title: l10n.navBarHistory,
      showBack: false,
      contentWidth: mgDetailWidth,
      header: MgReadable(
        maxWidth: mgDetailWidth,
        child: MgSearchField(
          placeholder: l10n.navBarSearch,
          onChanged: (value) => setState(() => _query = value),
        ),
      ),
      body: history.when(
        skipLoadingOnReload: true,
        loading: () => const SizedBox.shrink(),
        error: (error, _) => MgEmptyState(icon: Icons.history, title: error.toString()),
        data: (entries) {
          final visible = query.isEmpty
              ? entries
              : entries
                  .where((entry) =>
                      entry.title.toLowerCase().contains(query) ||
                      entry.author.toLowerCase().contains(query))
                  .toList();
          if (visible.isEmpty) {
            return MgEmptyState(icon: Icons.history, title: l10n.mgHistoryEmpty);
          }
          final rows = <Object>[];
          String? currentDay;
          for (final entry in visible) {
            final day = _day(context, entry.time);
            if (day != currentDay) {
              rows.add(day);
              currentDay = day;
            }
            rows.add(entry);
          }
          final inset = 16 + mgCenteredInset(context, mgDetailWidth);
          return ListView.builder(
            padding: EdgeInsets.fromLTRB(inset, 4, inset, 24),
            itemCount: rows.length,
            itemBuilder: (context, index) {
              final row = rows[index];
              if (row is String) {
                return Padding(
                  padding: const EdgeInsets.only(top: 14, bottom: 6),
                  child: Text(row, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                );
              }
              return _HistoryRow(entry: row as HistoryEntry);
            },
          );
        },
      ),
    );
  }
}

class _HistoryRow extends ConsumerWidget {
  const _HistoryRow({required this.entry});

  final HistoryEntry entry;

  void _openDetail(BuildContext context, StoreRecord record) {
    Navigator.of(context).push(CupertinoPageRoute(
      builder: (_) => StoreDetailPage(id: record.storeId, preview: record.toBook()),
    ));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entry = this.entry;
    final palette = MgPalette.of(context);
    final percent = (entry.percent * 100).clamp(0, 100).round();
    final Widget cover;
    final VoidCallback onTap;
    String? volumeLabel;
    switch (entry) {
      case ShelfHistoryEntry(:final book):
        cover = BookCover(book: book, width: 53, height: 78, radius: 6);
        onTap = () => pushToReadingPage(ref, context, book);
      case StoreHistoryEntry(:final record, :final volume):
        cover = SizedBox(width: 53, child: StoreCover(url: record.coverUrl, width: 53, radius: 6));
        volumeLabel = volume?.title.replaceFirst(record.title, '').trim();
        onTap = volume == null
            ? () => _openDetail(context, record)
            : () async {
                await pushToReadingPage(ref, context, volume);
                ref.invalidate(storeHistoryProvider);
              };
    }
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            cover,
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      [if (volumeLabel?.isNotEmpty ?? false) volumeLabel!, entry.author]
                          .where((s) => s.isNotEmpty)
                          .join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14, color: palette.secondaryLabel),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                                value: entry.percent.clamp(0, 1).toDouble(), minHeight: 3),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text('$percent%',
                            style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (entry is StoreHistoryEntry)
              IconButton(
                icon: Icon(Icons.more_horiz, color: Theme.of(context).colorScheme.primary),
                onPressed: () => _openDetail(context, entry.record),
              ),
          ],
        ),
      ),
    );
  }
}
