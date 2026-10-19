import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/book_note.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/service/wifi_transfer/wifi_transfer_server.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

enum AllNotesFormat { markdown, txt }

/// Writes one file per book that has notes into a zip in the temp directory and returns it.
Future<File> exportAllNotesZip({
  AllNotesFormat format = AllNotesFormat.markdown,
  Future<List<Book>> Function()? loadBooks,
  Future<List<BookNote>> Function(int bookId)? loadNotes,
  Future<Directory> Function()? getTempDirectory,
  DateTime Function()? now,
}) async {
  final books = await (loadBooks?.call() ?? bookDao.selectBooks(includeDeleted: false, includeStore: true));
  final files = <String, String>{};
  final extension = format == AllNotesFormat.markdown ? 'md' : 'txt';
  for (final book in books) {
    if (book.isDeleted) continue;
    final notes = List<BookNote>.from(await (loadNotes?.call(book.id) ?? bookNoteDao.selectBookNotesByBookId(book.id)));
    if (notes.isEmpty) continue;
    notes.sort((a, b) => _compareCfi(a.cfi, b.cfi));
    final fileName = uniqueTransferFileName('${book.title}.$extension', files.containsKey);
    final groups = _groupNotesByChapter(notes);
    files[fileName] = format == AllNotesFormat.markdown
        ? '# ${book.title}\n\n *${book.author}*\n\n${groups.map(_formatMarkdownGroup).join()}'
        : groups.map(_formatPlainGroup).join('\n\n');
  }
  if (files.isEmpty) throw StateError('no_notes');

  final directory = await (getTempDirectory?.call() ?? getAnxTempDir());
  final date = now?.call() ?? DateTime.now();
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final file = File(path.join(directory.path, '物语笔记-${date.year}-$month-$day.zip'));
  if (await file.exists()) await file.delete();
  try {
    await compute(_writeArchive, (path: file.path, files: files));
  } catch (_) {
    if (await file.exists()) await file.delete();
    rethrow;
  }
  return file;
}

Future<void> _writeArchive(({String path, Map<String, String> files}) request) async {
  final encoder = ZipFileEncoder()..create(request.path);
  try {
    for (final entry in request.files.entries) {
      final bytes = utf8.encode(entry.value);
      encoder.addArchiveFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
  } finally {
    await encoder.close();
  }
}

// Keep grouping and formatting identical to export_notes.dart with merged chapter headings.
class _ChapterGroup {
  final String chapter;
  final List<BookNote> notes;

  _ChapterGroup(this.chapter, this.notes);
}

List<_ChapterGroup> _groupNotesByChapter(List<BookNote> notes) {
  final groups = <_ChapterGroup>[];
  for (final note in notes) {
    if (groups.isEmpty || groups.last.chapter != note.chapter) {
      groups.add(_ChapterGroup(note.chapter, []));
    }
    groups.last.notes.add(note);
  }
  return groups;
}

String _formatPlainGroup(_ChapterGroup group) {
  final buffer = StringBuffer();
  if (group.chapter.isNotEmpty) {
    buffer.writeln(group.chapter);
  }
  for (final note in group.notes) {
    if (note.content.isNotEmpty) {
      buffer.writeln('\t${note.content}');
    }
    if (note.readerNote != null && note.readerNote!.isNotEmpty) {
      buffer.writeln('\t\t${note.readerNote}');
    }
    buffer.writeln();
  }
  return buffer.toString().trim();
}

String _formatMarkdownGroup(_ChapterGroup group) {
  final buffer = StringBuffer();
  buffer.writeln('## ${group.chapter}\n');
  for (final note in group.notes) {
    if (note.content.isNotEmpty) {
      buffer.writeln('> ${note.content}\n');
    }
    if (note.readerNote != null && note.readerNote!.isNotEmpty) {
      buffer.writeln('${note.readerNote}\n');
    }
    buffer.writeln();
  }
  return buffer.toString();
}

// Match chapter-position sorting in providers/book_notes.dart.
int _compareCfi(String a, String b) {
  List<String> components(String value) {
    return value.replaceAll('epubcfi(/', '').replaceAll(')', '').replaceAll(',', '').split('/');
  }

  final componentsA = components(a);
  final componentsB = components(b);
  for (int i = 0; i < componentsA.length && i < componentsB.length; i++) {
    final compA = componentsA[i];
    final compB = componentsB[i];
    if (compA.isEmpty || compB.isEmpty) continue;
    if (compA != compB) {
      if (compA.contains(':') && compB.contains(':')) {
        final locA = int.tryParse(compA.split(':')[1]) ?? 0;
        final locB = int.tryParse(compB.split(':')[1]) ?? 0;
        return locA.compareTo(locB);
      }
      final numA = int.tryParse(compA.replaceAll('!', '')) ?? 0;
      final numB = int.tryParse(compB.replaceAll('!', '')) ?? 0;
      return numA.compareTo(numB);
    }
  }
  return componentsA.length.compareTo(componentsB.length);
}
