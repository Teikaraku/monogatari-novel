import 'package:anx_reader/dao/base_dao.dart';
import 'package:sqflite/sqflite.dart';

class StoreBookTagDao extends BaseDao {
  static const _table = 'tb_store_book_tags';

  Future<List<int>> tagIdsForStore(String storeId) {
    return queryList(
      _table,
      columns: ['tag_id'],
      where: 'store_id = ?',
      whereArgs: [storeId],
      mapper: (row) => row['tag_id'] as int,
    );
  }

  Future<Map<String, List<int>>> storeIdToTagIds({List<String>? storeIds}) async {
    if (storeIds != null && storeIds.isEmpty) return {};
    final db = await database;
    final rows = await db.query(
      _table,
      columns: ['store_id', 'tag_id'],
      where: storeIds == null ? null : 'store_id IN (${List.filled(storeIds.length, '?').join(',')})',
      whereArgs: storeIds,
    );
    final result = <String, List<int>>{};
    for (final row in rows) {
      result.putIfAbsent(row['store_id'] as String, () => []).add(row['tag_id'] as int);
    }
    return result;
  }

  Future<void> attach(String storeId, int tagId) async {
    await insert(
      _table,
      {'store_id': storeId, 'tag_id': tagId},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> detach(String storeId, int tagId) async {
    await delete(_table, where: 'store_id = ? AND tag_id = ?', whereArgs: [storeId, tagId]);
  }

  Future<void> deleteByTag(int tagId) async {
    await delete(_table, where: 'tag_id = ?', whereArgs: [tagId]);
  }
}

final storeBookTagDao = StoreBookTagDao();
