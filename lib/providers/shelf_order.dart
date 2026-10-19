import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/sort_field.dart';
import 'package:anx_reader/enums/sort_order.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/providers/book_filters.dart';
import 'package:lpinyin/lpinyin.dart';

/// What the shelf sorts by. Local books and bookstore series share it so both interleave in one order.
class ShelfSortKey {
  const ShelfSortKey({
    required this.title,
    required this.author,
    required this.lastRead,
    required this.progress,
    required this.added,
  });

  factory ShelfSortKey.book(Book book) => ShelfSortKey(
        title: book.title,
        author: book.author,
        lastRead: book.updateTime,
        progress: book.readingPercentage,
        added: book.createTime,
      );

  final String title;
  final String author;
  final DateTime lastRead;
  final double progress;
  final DateTime added;
}

final _sortable = <String, String>{};

/// Titles and authors compare by pinyin; conversions are cached because sorting asks for them repeatedly.
String _pinyin(String text) => _sortable[text] ??= () {
      try {
        return PinyinHelper.getPinyin(text, format: PinyinFormat.WITHOUT_TONE);
      } catch (_) {
        return text;
      }
    }();

int compareShelfKeys(ShelfSortKey a, ShelfSortKey b) {
  final result = switch (Prefs().sortField) {
    SortFieldEnum.title => _pinyin(a.title).compareTo(_pinyin(b.title)),
    SortFieldEnum.author => _pinyin(a.author).compareTo(_pinyin(b.author)),
    SortFieldEnum.lastReadTime => a.lastRead.compareTo(b.lastRead),
    SortFieldEnum.progress => a.progress.compareTo(b.progress),
    SortFieldEnum.importTime => a.added.compareTo(b.added),
  };
  return Prefs().sortOrder == SortOrderEnum.ascending ? result : -result;
}

const shelfFinishedAt = 0.98;

/// Reading status as commercial readers count it: not started until first opened, finished at the end.
bool matchesShelfStatus(ReadingStatusFilter filter, {required bool opened, required bool finished}) =>
    switch (filter) {
      ReadingStatusFilter.none => true,
      ReadingStatusFilter.notStarted => !opened,
      ReadingStatusFilter.finished => opened && finished,
      ReadingStatusFilter.reading => opened && !finished,
    };

bool bookMatchesStatus(Book book, ReadingStatusFilter filter) => matchesShelfStatus(
      filter,
      opened: book.lastReadPosition.isNotEmpty || book.readingPercentage > 0,
      finished: book.readingPercentage >= shelfFinishedAt,
    );
