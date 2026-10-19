import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/reading_time.dart';
import 'package:anx_reader/models/tag.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_actions.dart';
import 'package:anx_reader/page/book_notes_page.dart';
import 'package:anx_reader/page/bookstore/store_detail_page.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/providers/tags.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/bookshelf/book_cover.dart';
import 'package:anx_reader/widgets/common/tag_editor_sheet.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;

/// Opens the right detail page: bookstore volumes are read-only and show their store page;
/// imported books open the editable local detail page.
Future<void> openBookDetail(BuildContext context, Book book) {
  final storeKey = book.storeKey;
  return Navigator.of(context).push(CupertinoPageRoute(
    builder: (_) => storeKey != null
        ? StoreDetailPage(id: storeKey.split('/').first)
        : BookDetail(book: book),
  ));
}

class _BookStats {
  const _BookStats({
    required this.seconds,
    required this.days,
    required this.notes,
    required this.size,
  });

  final int seconds;

  /// Reading time per calendar day, newest first.
  final List<(String, int)> days;
  final int notes;
  final int size;
}

/// Detail page of an imported book: everything here is the user's own and editable.
class BookDetail extends ConsumerStatefulWidget {
  const BookDetail({super.key, required this.book});

  final Book book;

  @override
  ConsumerState<BookDetail> createState() => _BookDetailState();
}

class _BookDetailState extends ConsumerState<BookDetail> {
  late final Book _book = widget.book;
  late Future<_BookStats> _stats = _loadStats();
  bool _allDays = false;

  Future<_BookStats> _loadStats() async {
    final id = _book.id;
    final results = await Future.wait([
      readingTimeDao.selectReadingTimeByBookId(id),
      bookNoteDao.selectBookNotesByBookId(id),
      () async {
        final file = File(_book.fileFullPath);
        return await file.exists() ? await file.length() : 0;
      }(),
    ]);
    final log = results[0] as List<ReadingTime>;
    final perDay = <String, int>{};
    var seconds = 0;
    for (final entry in log) {
      seconds += entry.readingTime;
      final day = entry.dateOnly ?? '';
      if (day.isNotEmpty) perDay[day] = (perDay[day] ?? 0) + entry.readingTime;
    }
    final days = perDay.entries.map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$1.compareTo(a.$1));
    return _BookStats(
      seconds: seconds,
      days: days,
      notes: (results[1] as List).length,
      size: results[2] as int,
    );
  }

  void _changed() {
    ref.read(bookListProvider.notifier).refresh();
    ref.read(syncProvider.notifier).syncData(SyncDirection.upload, ref, trigger: SyncTrigger.manual);
    if (mounted) setState(() {});
  }

  String get _format {
    final extension = path.extension(_book.filePath).replaceFirst('.', '');
    return extension.isEmpty ? '-' : extension.toUpperCase();
  }

  String get _description =>
      (_book.description ?? '').replaceAll(RegExp(r'<[^>]*>'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  Future<void> _openNotes(int count) => Navigator.of(context).push(CupertinoPageRoute(
        builder: (_) => BookNotesPage(book: _book, numberOfNotes: count, isMobile: true),
      ));

  Future<void> _replaceCover(File image) async {
    final old = File(_book.coverFullPath);
    if (await old.exists()) await old.delete();
    final parts = _book.coverPath.split('-');
    var stem = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('') : _book.coverPath;
    stem = path.withoutExtension(stem);
    if (!stem.startsWith('cover/')) stem = 'cover/$stem';
    final relative = '$stem-${DateTime.now().millisecondsSinceEpoch}.png';
    await File(getBasePath(relative)).writeAsBytes(await image.readAsBytes());
    _book.coverPath = relative;
  }

  Future<void> _editInfo() async {
    final l10n = L10n.of(context);
    final title = TextEditingController(text: _book.title);
    final author = TextEditingController(text: _book.author);
    File? cover;
    final saved = await showMgSheet<bool>(
      context: context,
      title: l10n.bookInfoEdit,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheet) {
          Future<void> pickCover() async {
            try {
              final result = await FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false);
              final picked = result?.files.single.path;
              if (picked != null) setSheet(() => cover = File(picked));
            } catch (e) {
              AnxToast.show(l10n.filePickerFailed(e.toString()));
            }
          }

          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: GestureDetector(
                    onTap: pickCover,
                    child: Column(
                      children: [
                        SizedBox(
                          width: 96,
                          height: 136,
                          child: cover != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(cover!, fit: BoxFit.cover, cacheWidth: 300),
                                )
                              : BookCover(book: _book, width: 96, height: 136),
                        ),
                        const SizedBox(height: 8),
                        Text(l10n.bookInfoCover,
                            style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.primary)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                _Field(label: l10n.bookInfoTitle, controller: title, maxLines: 3),
                const SizedBox(height: 12),
                _Field(label: l10n.bookInfoAuthor, controller: author),
              ],
            ),
          );
        },
      ),
      footer: (context) => MgSheetButtons(
        secondary: l10n.commonCancel,
        onSecondary: () => Navigator.of(context).pop(false),
        primary: l10n.commonSave,
        onPrimary: () => Navigator.of(context).pop(true),
      ),
    );
    if (saved == true) {
      final newTitle = title.text.replaceAll('\n', ' ').trim();
      if (newTitle.isNotEmpty) _book.title = newTitle;
      _book.author = author.text.trim();
      if (cover != null) await _replaceCover(cover!);
      await bookDao.updateBook(_book);
      _changed();
    }
    title.dispose();
    author.dispose();
  }

  Future<void> _manageTags() => showTagEditorSheet(
        context,
        binding: BookTagBinding(_book.id),
        onChanged: () {
          ref.read(bookListProvider.notifier).refresh();
          ref.invalidate(bookTagEditorProvider(_book.id));
        },
      );

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final inset = 20 + mgCenteredInset(context, mgDetailWidth);
    final percent = (_book.readingPercentage * 100).round();
    final description = _description;

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
                    TextButton(onPressed: _editInfo, child: Text(l10n.commonEdit)),
                    MgMenuButton(
                      sections: () => [
                        [
                          MgMenuAction(
                            title: l10n.shareFile,
                            icon: Icons.ios_share,
                            onTap: () => shareLocalBook(_book),
                          ),
                          MgMenuAction(
                            title: l10n.bookBottomSheetReplaceFile,
                            icon: Icons.swap_horiz,
                            onTap: () async {
                              if (await replaceLocalBookFile(context, ref, _book)) {
                                setState(() { _stats = _loadStats(); });
                              }
                            },
                          ),
                          if (Prefs().webdavStatus)
                            MgMenuAction(
                              title: l10n.bookSyncStatusReleaseSpace,
                              icon: Icons.cloud_upload_outlined,
                              onTap: () => releaseLocalBookSpace(context, ref, _book),
                            ),
                        ],
                        [
                          MgMenuAction(
                            title: l10n.commonDelete,
                            icon: Icons.delete_outline,
                            destructive: true,
                            onTap: () async {
                              if (await deleteLocalBook(context, ref, _book) && context.mounted) {
                                Navigator.of(context).maybePop();
                              }
                            },
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            Expanded(
              child: FutureBuilder<_BookStats>(
                future: _stats,
                builder: (context, snapshot) {
                  final stats = snapshot.data;
                  return ListView(
                    padding: EdgeInsets.fromLTRB(inset, 4, inset, 32 + MediaQuery.paddingOf(context).bottom),
                    children: [
                      _header(context, stats),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () => pushToReadingPage(ref, context, _book),
                              icon: const Icon(Icons.menu_book, size: 20),
                              label: Text(percent > 0
                                  ? '${l10n.storeContinueReading} · $percent%'
                                  : l10n.storeStartReading),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 46,
                            child: OutlinedButton.icon(
                              onPressed: () => _openNotes(stats?.notes ?? 0),
                              icon: const Icon(Icons.edit_note, size: 22),
                              label: Text(stats == null || stats.notes == 0
                                  ? l10n.notes
                                  : '${l10n.notes} ${stats.notes}'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _StatsCard(stats: stats, percent: percent),
                      const SizedBox(height: 22),
                      _SectionTitle(
                        l10n.tagsSectionTitle,
                        action: l10n.bookInfoManage,
                        onAction: _manageTags,
                      ),
                      const SizedBox(height: 10),
                      _AttachedTags(bookId: _book.id, onAdd: _manageTags),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        _SectionTitle(l10n.storeSynopsis),
                        const SizedBox(height: 8),
                        MgExpandableText(description),
                      ],
                      const SizedBox(height: 22),
                      _SectionTitle(l10n.bookInfoSection),
                      const SizedBox(height: 10),
                      MgGroup(
                        padding: EdgeInsets.zero,
                        color: mgSheetGroupColor(context),
                        children: [
                          MgRow(title: l10n.bookInfoFormat, value: _format, showChevron: false),
                          MgRow(
                            title: l10n.bookInfoSize,
                            value: stats == null ? '' : formatFileSize(stats.size),
                            showChevron: false,
                          ),
                          MgRow(title: l10n.bookInfoImported, value: _date(_book.createTime), showChevron: false),
                          MgRow(
                            title: l10n.bookInfoLastRead,
                            value: percent > 0 ? _date(_book.updateTime) : l10n.bookInfoNotStarted,
                            showChevron: false,
                          ),
                        ],
                      ),
                      if (stats != null && stats.days.isNotEmpty) ...[
                        const SizedBox(height: 22),
                        _SectionTitle(
                          l10n.bookInfoLog,
                          action: stats.days.length > 7 && !_allDays ? l10n.storeMore : null,
                          onAction: () => setState(() => _allDays = true),
                        ),
                        const SizedBox(height: 4),
                        for (final (day, seconds) in stats.days.take(_allDays ? 90 : 7))
                          _LogRow(day: day, seconds: seconds, max: stats.days.map((d) => d.$2).reduce((a, b) => a > b ? a : b)),
                      ],
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context, _BookStats? stats) {
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final meta = [_format, if (stats != null && stats.size > 0) formatFileSize(stats.size)].join(' · ');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Hero(
          tag: _book.coverFullPath,
          child: BookCover(book: _book, width: 112, height: 160),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_book.title, style: const TextStyle(fontSize: 22, height: 1.3, fontWeight: FontWeight.bold)),
              if (_book.author.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(_book.author, style: TextStyle(fontSize: 15, color: accent)),
                ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(meta, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
              ),
              const SizedBox(height: 10),
              _RatingStars(
                rating: _book.rating,
                onChanged: (value) => setState(() => updateBookRating(_book, value)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _date(DateTime? time) => time == null ? '-' : time.toIso8601String().substring(0, 10);
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title, {this.action, this.onAction});

  final String title;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Expanded(child: Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
          if (action != null)
            GestureDetector(
              onTap: onAction,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(action!, style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.primary)),
              ),
            ),
        ],
      );
}

/// Five tappable stars in the accent colour; tapping the current rating clears it.
class _RatingStars extends StatelessWidget {
  const _RatingStars({required this.rating, required this.onChanged});

  final double rating;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final empty = MgPalette.of(context).separator;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onChanged(rating == i ? 0 : i.toDouble()),
            child: Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(
                rating >= i
                    ? Icons.star_rounded
                    : rating >= i - .5
                        ? Icons.star_half_rounded
                        : Icons.star_outline_rounded,
                size: 24,
                color: rating >= i - .5 ? accent : empty,
              ),
            ),
          ),
      ],
    );
  }
}

/// Reading time, days and progress in one gray card.
class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats, required this.percent});

  final _BookStats? stats;
  final int percent;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final time = mgDuration(l10n, stats?.seconds ?? 0);
    Widget cell(String figure, String label) => Expanded(
          child: Column(
            children: [
              MgFigure(figure),
              const SizedBox(height: 4),
              Text(label, style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
            ],
          ),
        );
    Widget divider() => Container(width: .5, height: 32, color: palette.separator);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(color: mgSheetGroupColor(context), borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Row(
            children: [
              cell(time, l10n.bookInfoReadTime),
              divider(),
              cell(l10n.bookInfoDays(stats?.days.length ?? 0), l10n.bookInfoReadDays),
              divider(),
              cell('$percent%', l10n.bookshelfProgress),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Container(
              height: 4,
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: palette.separator.withValues(alpha: .6),
                borderRadius: BorderRadius.circular(2),
              ),
              child: FractionallySizedBox(
                widthFactor: (percent / 100).clamp(0.0, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({required this.day, required this.seconds, required this.max});

  final String day;
  final int seconds;
  final int max;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final minutes = (seconds / 60).ceil();
    final label = minutes >= 60
        ? '${l10n.commonHours(minutes ~/ 60)} ${l10n.commonMinutes(minutes % 60)}'
        : l10n.commonMinutes(minutes);
    return Container(
      height: 44,
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: palette.separator, width: .5))),
      child: Row(
        children: [
          SizedBox(width: 96, child: Text(day, style: const TextStyle(fontSize: 15))),
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: max == 0 ? 0 : (seconds / max).clamp(.04, 1.0),
                child: Container(
                  height: 6,
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: .75),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 84,
            child: Text(label,
                textAlign: TextAlign.right, style: TextStyle(fontSize: 14, color: palette.secondaryLabel)),
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.controller, this.maxLines = 1});

  final String label;
  final TextEditingController controller;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 6),
          child: Text(label, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
        ),
        TextField(
          controller: controller,
          minLines: 1,
          maxLines: maxLines,
          style: const TextStyle(fontSize: 16),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: mgSheetGroupColor(context),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
          ),
        ),
      ],
    );
  }
}

/// The book's tags as pills, or a single "add tag" pill when there are none.
class _AttachedTags extends ConsumerWidget {
  const _AttachedTags({required this.bookId, required this.onAdd});

  final int bookId;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(bookTagEditorProvider(bookId)).valueOrNull;
    final attached = state == null ? const <Tag>[] : state.tags.where((t) => state.isAttached(t.id)).toList();
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final tag in attached) TagPill(tag: tag, selected: false, onTap: onAdd),
        if (attached.isEmpty)
          MgChip(
            label: L10n.of(context).bookInfoAddTag,
            selected: false,
            checkmark: false,
            trailingIcon: Icons.add,
            onTap: onAdd,
          ),
      ],
    );
  }
}
