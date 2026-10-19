import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/book.dart';
import 'package:anx_reader/dao/database.dart';
import 'package:anx_reader/dao/store_book_tag.dart';
import 'package:anx_reader/dao/tag.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<Database> _openDatabase() async {
  final db = await DBHelper().database;
  // Wait for the legacy migration's asynchronous book query to finish as well.
  await bookDao.selectBooks(includeStore: true);
  return db;
}

Future<void> _expectStoreTagSchema(Database db) async {
  expect(await db.getVersion(), 9);
  final columns = await db.rawQuery('PRAGMA table_info(tb_store_book_tags)');
  expect(columns.map((row) => row['name']), ['store_id', 'tag_id']);
  expect(columns.map((row) => row['type']), ['TEXT', 'INTEGER']);
  expect(columns.map((row) => row['notnull']), [1, 1]);
  expect(columns.map((row) => row['pk']), [1, 2]);
  final indexes = await db.rawQuery('PRAGMA index_list(tb_store_book_tags)');
  expect(indexes.map((row) => row['name']), contains('idx_store_book_tags_tag'));
  final indexedColumns = await db.rawQuery('PRAGMA index_info(idx_store_book_tags_tag)');
  expect(indexedColumns.map((row) => row['name']), ['tag_id']);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late String oldDocumentPath;
  final buildDirectory = Directory(p.join(Directory.current.path, 'build'));

  setUp(() async {
    await DBHelper.close();
    await buildDirectory.create(recursive: true);
    directory = await buildDirectory.createTemp('store_book_tags_test_');
    oldDocumentPath = documentPath;
    documentPath = directory.path;
    await Directory(p.join(directory.path, 'file')).create();
    await Directory(p.join(directory.path, 'cover')).create();
    SharedPreferences.setMockInitialValues({'customStoragePath': directory.path});
    await Prefs().initPrefs();
    DBHelper.updatedDB = false;
  });

  tearDown(() async {
    await DBHelper.close();
    documentPath = oldDocumentPath;
    final resolvedRoot = await buildDirectory.resolveSymbolicLinks();
    final resolvedDirectory = await directory.resolveSymbolicLinks();
    if (!p.isWithin(resolvedRoot, resolvedDirectory)) {
      throw StateError('The test directory must remain inside the project build directory');
    }
    await directory.delete(recursive: true);
  });

  test('new database creates version 9 table and index before opening returns', () async {
    final db = await _openDatabase();
    await _expectStoreTagSchema(db);
    expect(await storeBookTagDao.storeIdToTagIds(), isEmpty);
  });

  test('version 8 upgrade creates the table and preserves existing records', () async {
    sqfliteFfiInit();
    final databasePath = p.join(directory.path, 'databases', 'app_database.db');
    final previous = await databaseFactoryFfi.openDatabase(
      databasePath,
      options: OpenDatabaseOptions(
        version: 8,
        onCreate: (db, version) async {
          await db.execute(createBookSQL);
          await db.execute('ALTER TABLE tb_books ADD COLUMN store_key TEXT');
          await db.execute(createStoreBookSQL);
          await db.execute(createStyleSQL);
          await db.insert('tb_store_books', {'store_id': 'series-1', 'title': 'Existing series', 'in_shelf': 1});
          await db.insert('tb_styles', {'id': 42, 'font_size': 1.0, 'font_family': 'Existing tag'});
        },
      ),
    );
    expect(await previous.getVersion(), 8);
    await previous.close();

    final db = await _openDatabase();
    await _expectStoreTagSchema(db);
    expect((await db.query('tb_store_books')).single['title'], 'Existing series');
    expect((await db.query('tb_styles')).single['font_family'], 'Existing tag');
    await storeBookTagDao.attach('series-1', 42);
    expect(await storeBookTagDao.tagIdsForStore('series-1'), [42]);
  });

  test('attach is idempotent for the same store and tag pair', () async {
    await _openDatabase();
    await storeBookTagDao.attach('series-1', 7);
    await storeBookTagDao.attach('series-1', 7);
    await storeBookTagDao.attach('series-1', 8);
    await storeBookTagDao.attach('series-2', 7);
    expect(await storeBookTagDao.tagIdsForStore('series-1'), unorderedEquals([7, 8]));
    expect(await storeBookTagDao.tagIdsForStore('series-2'), [7]);
    expect(await storeBookTagDao.tagIdsForStore('missing'), isEmpty);
  });

  test('detach removes only the requested pair and tolerates missing pairs', () async {
    await _openDatabase();
    await storeBookTagDao.attach('series-1', 7);
    await storeBookTagDao.attach('series-1', 8);
    await storeBookTagDao.attach('series-2', 7);
    await storeBookTagDao.detach('series-1', 7);
    await storeBookTagDao.detach('series-1', 7);
    expect(await storeBookTagDao.tagIdsForStore('series-1'), [8]);
    expect(await storeBookTagDao.tagIdsForStore('series-2'), [7]);
  });

  test('batch query handles all stores, filters, missing stores and an empty list', () async {
    await _openDatabase();
    await storeBookTagDao.attach('series-1', 7);
    await storeBookTagDao.attach('series-1', 8);
    await storeBookTagDao.attach('series-2', 9);
    final all = await storeBookTagDao.storeIdToTagIds();
    expect(all.keys, unorderedEquals(['series-1', 'series-2']));
    expect(all['series-1'], unorderedEquals([7, 8]));
    expect(all['series-2'], [9]);
    expect(await storeBookTagDao.storeIdToTagIds(storeIds: ['series-2', 'missing']), {
      'series-2': [9],
    });
    expect(await storeBookTagDao.storeIdToTagIds(storeIds: []), isEmpty);
    expect(await storeBookTagDao.storeIdToTagIds(storeIds: ['missing']), isEmpty);
  });

  test('store IDs are bound as values in individual and batch queries', () async {
    await _openDatabase();
    const quotedId = "series' OR 1 = 1 --";
    await storeBookTagDao.attach(quotedId, 7);
    await storeBookTagDao.attach('other', 8);
    expect(await storeBookTagDao.tagIdsForStore(quotedId), [7]);
    expect(await storeBookTagDao.storeIdToTagIds(storeIds: [quotedId]), {
      quotedId: [7],
    });
    await storeBookTagDao.detach(quotedId, 7);
    expect(await storeBookTagDao.tagIdsForStore('other'), [8]);
  });

  test('deleteByTag removes that tag across stores and preserves other tags', () async {
    await _openDatabase();
    await storeBookTagDao.attach('series-1', 7);
    await storeBookTagDao.attach('series-2', 7);
    await storeBookTagDao.attach('series-1', 8);
    await storeBookTagDao.deleteByTag(7);
    await storeBookTagDao.deleteByTag(7);
    expect(await storeBookTagDao.storeIdToTagIds(), {
      'series-1': [8],
    });
  });

  test('deleting a tag clears its local and store relations while preserving other tags', () async {
    await _openDatabase();
    final removedTag = await tagDao.insertTag('Remove');
    final retainedTag = await tagDao.insertTag('Retain');
    await bookTagDao.addRelation(bookId: 1, tagId: removedTag);
    await bookTagDao.addRelation(bookId: 2, tagId: removedTag);
    await bookTagDao.addRelation(bookId: 1, tagId: retainedTag);
    await storeBookTagDao.attach('series-1', removedTag);
    await storeBookTagDao.attach('series-2', removedTag);
    await storeBookTagDao.attach('series-1', retainedTag);

    await tagDao.deleteTag(removedTag);

    expect(await tagDao.getTagById(removedTag), isNull);
    expect((await tagDao.fetchAllTags()).map((tag) => tag.id), [retainedTag]);
    expect(await bookTagDao.fetchTagIdsForBook(1), [retainedTag]);
    expect(await bookTagDao.fetchTagIdsForBook(2), isEmpty);
    expect(await storeBookTagDao.storeIdToTagIds(), {
      'series-1': [retainedTag],
    });
  });

  test('tag deletion rolls back all associations if store cleanup fails', () async {
    final db = await _openDatabase();
    final tagId = await tagDao.insertTag('Retain after rollback');
    await bookTagDao.addRelation(bookId: 1, tagId: tagId);
    await storeBookTagDao.attach('series-1', tagId);
    await db.execute('''
      CREATE TRIGGER reject_store_tag_delete BEFORE DELETE ON tb_store_book_tags
      BEGIN
        SELECT RAISE(ABORT, 'Store tag cleanup failed');
      END
    ''');

    await expectLater(tagDao.deleteTag(tagId), throwsA(isA<DatabaseException>()));

    expect((await tagDao.getTagById(tagId))?.id, tagId);
    expect(await bookTagDao.fetchTagIdsForBook(1), [tagId]);
    expect(await storeBookTagDao.tagIdsForStore('series-1'), [tagId]);
  });
}
