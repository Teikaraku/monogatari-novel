import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/notes/export_all_notes.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

Book _book(int id, {String title = '书名', bool deleted = false, String? storeKey}) {
  return Book(
    id: id,
    title: title,
    author: '作者',
    coverPath: '',
    filePath: '',
    lastReadPosition: '',
    readingPercentage: 0,
    isDeleted: deleted,
    rating: 0,
    storeKey: storeKey,
    createTime: DateTime(2026, 1, 1),
    updateTime: DateTime(2026, 1, 1),
  );
}

BookNote _note({
  int bookId = 1,
  String cfi = 'epubcfi(/6/2!/4/2:2)',
  String chapter = '第一章',
  String content = '摘录',
  String? readerNote,
}) {
  return BookNote(
    bookId: bookId,
    cfi: cfi,
    chapter: chapter,
    content: content,
    readerNote: readerNote,
    type: 'highlight',
    color: 'FF0000',
    createTime: DateTime(2026, 1, 1),
    updateTime: DateTime(2026, 1, 2),
  );
}

Future<Map<String, String>> _readArchive(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes(), verify: true);
  expect(archive.files.every((entry) => entry.isFile), isTrue);
  return {for (final entry in archive.files) entry.name: utf8.decode(entry.content as List<int>)};
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('all_notes_test_');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  Future<File> export({
    AllNotesFormat format = AllNotesFormat.markdown,
    required List<Book> books,
    Map<int, List<BookNote>> notes = const {},
  }) {
    return exportAllNotesZip(
      format: format,
      loadBooks: () async => books,
      loadNotes: (bookId) async => notes[bookId] ?? [],
      getTempDirectory: () async => directory,
      now: () => DateTime(2026, 2, 3),
    );
  }

  test('exports only books with notes, includes store volumes and excludes deleted books', () async {
    final requestedBooks = <int>[];
    final file = await exportAllNotesZip(
      loadBooks: () async => [
        _book(1, title: '本地书'),
        _book(2, title: '书库书', storeKey: '251/1'),
        _book(3, title: '已删除', deleted: true),
        _book(4, title: '无笔记'),
      ],
      loadNotes: (bookId) async {
        requestedBooks.add(bookId);
        return bookId == 4 ? [] : [_note(bookId: bookId)];
      },
      getTempDirectory: () async => directory,
      now: () => DateTime(2026, 2, 3),
    );
    final entries = await _readArchive(file);
    expect(entries.keys, ['本地书.md', '书库书.md']);
    expect(requestedBooks, [1, 2, 4]);
    expect(path.basename(file.path), '物语笔记-2026-02-03.zip');
    expect(path.dirname(file.path), directory.path);
  });

  test('sanitizes paths and invalid characters, then increments duplicate archive names', () async {
    final file = await export(
      books: [
        _book(1, title: '../../奇<书>:?|*\u0000'),
        _book(2, title: r'..\..\奇书'),
        _book(3, title: '奇书'),
        _book(4, title: '奇书 (2)'),
      ],
      notes: {
        for (var id = 1; id <= 4; id++) id: [_note(bookId: id, content: '摘录$id')]
      },
    );
    final entries = await _readArchive(file);
    expect(entries.keys, ['奇书.md', '奇书 (2).md', '奇书 (3).md', '奇书 (2) (2).md']);
    for (var id = 1; id <= 4; id++) {
      expect(entries.values.elementAt(id - 1), contains('摘录$id'));
    }
  });

  test('truncates long Unicode filenames while retaining extension and duplicate suffix', () async {
    final title = List.filled(140, '物').join();
    final file = await export(
      format: AllNotesFormat.txt,
      books: [_book(1, title: title), _book(2, title: title)],
      notes: {
        1: [_note()],
        2: [_note(bookId: 2)]
      },
    );
    final entries = await _readArchive(file);
    expect(entries, hasLength(2));
    expect(entries.keys.first, '${List.filled(116, '物').join()}.txt');
    expect(entries.keys.last, '${List.filled(112, '物').join()} (2).txt');
    expect(entries.keys.every((name) => name.runes.length <= 120), isTrue);
  });

  final notes = [
    _note(cfi: 'epubcfi(/6/4!/4/2:1)', chapter: '', content: '末段', readerNote: ''),
    _note(cfi: 'epubcfi(/6/2!/4/2:10)', content: '', readerNote: '只有想法'),
    _note(content: '第一段\n第二行', readerNote: '感想\n续行'),
  ];

  test('Markdown matches single-book export with merged headings and numeric CFI ordering', () async {
    final file = await export(books: [_book(1)], notes: {1: notes});
    final entries = await _readArchive(file);
    expect(
        entries['书名.md'],
        '# 书名\n\n *作者*\n\n'
        '## 第一章\n\n'
        '> 第一段\n第二行\n\n'
        '感想\n续行\n\n\n'
        '只有想法\n\n\n'
        '## \n\n'
        '> 末段\n\n\n');
    expect(RegExp('## 第一章').allMatches(entries.values.single), hasLength(1));
    expect(notes.first.chapter, isEmpty);
    expect(notes[1].cfi, endsWith(':10)'));
  });

  test('TXT matches single-book export, including trimming and multiline notes', () async {
    final file = await export(format: AllNotesFormat.txt, books: [_book(1)], notes: {1: notes});
    final entries = await _readArchive(file);
    expect(
        entries['书名.txt'],
        '第一章\n'
        '\t第一段\n第二行\n'
        '\t\t感想\n续行\n\n'
        '\t\t只有想法\n\n'
        '末段');
    expect('第一章'.allMatches(entries.values.single), hasLength(1));
  });

  test('keeps repeated chapter titles separate when another chapter intervenes', () async {
    final file = await export(
      books: [_book(1)],
      notes: {
        1: [
          _note(cfi: 'epubcfi(/6/10)', chapter: '重复标题', content: '第三段'),
          _note(cfi: 'epubcfi(/6/4)', chapter: '中间章节', content: '第二段'),
          _note(cfi: 'epubcfi(/6/2)', chapter: '重复标题', content: '第一段'),
        ],
      },
    );
    final content = (await _readArchive(file)).values.single;
    expect('## 重复标题'.allMatches(content), hasLength(2));
    expect(content.indexOf('第一段'), lessThan(content.indexOf('第二段')));
    expect(content.indexOf('第二段'), lessThan(content.indexOf('第三段')));
  });

  test('replaces an existing archive with the same date instead of retaining old files', () async {
    final previous = File(path.join(directory.path, '物语笔记-2026-02-03.zip'));
    await previous.writeAsString('old archive');
    final file = await export(books: [
      _book(1)
    ], notes: {
      1: [_note()]
    });
    expect(file.path, previous.path);
    expect((await _readArchive(file)).keys, ['书名.md']);

    final replacement = await export(books: [
      _book(2, title: '新书')
    ], notes: {
      2: [_note(bookId: 2)]
    });
    expect(replacement.path, previous.path);
    expect((await _readArchive(replacement)).keys, ['新书.md']);
    expect(await directory.list().length, 1);
  });

  for (final books in [
    <Book>[],
    [_book(1)],
    [_book(2, deleted: true)]
  ]) {
    test('throws no_notes without creating an archive for ${books.map((book) => book.id).toList()}', () async {
      await expectLater(
        export(books: books, notes: {
          2: [_note(bookId: 2)]
        }),
        throwsA(isA<StateError>().having((error) => error.message, 'message', 'no_notes')),
      );
      expect(await directory.list().isEmpty, isTrue);
    });
  }
}
