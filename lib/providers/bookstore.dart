import 'dart:math';

import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Bumped by pull to refresh; the home stream then revalidates with the server.
final storeHomeRefreshProvider = StateProvider<int>((ref) => 0);

/// The bookstore home stays alive with its tab: cached first, then revalidated.
final storeHomeProvider = StreamProvider<StoreHome>((ref) {
  final refresh = ref.watch(storeHomeRefreshProvider);
  return BookstoreApi.instance.home(revalidate: refresh > 0);
});

final storeBookProvider = StreamProvider.autoDispose.family<StoreBookDetail, String>(
  (ref, id) => BookstoreApi.instance.book(id),
);

/// A volume's chapters, fetched when its row is first expanded.
final storeVolumeTocProvider = FutureProvider.autoDispose.family<List<StoreTocItem>, (String, int)>(
  (ref, key) => BookstoreApi.instance.volumeToc(key.$1, key.$2),
);

final storeTagsProvider = FutureProvider<List<StoreTag>>((ref) => BookstoreApi.instance.tags());

/// Tags with up to four cover previews each, for the category page (which shows three distinct ones).
final storeTagCoversProvider = FutureProvider<List<StoreTag>>((ref) => BookstoreApi.instance.tags(covers: 4));

final storeDiscoverProvider = StreamProvider<StoreDiscover>((ref) => BookstoreApi.instance.discover());

int _newSeed() => Random().nextInt(1 << 31);

/// Seed for the random picks: a fresh draw each launch, redrawn by "shuffle" and pull to refresh.
final storeRandomSeedProvider = StateProvider<int>((ref) => _newSeed());

void shuffleStoreRandomPicks(WidgetRef ref) => ref.read(storeRandomSeedProvider.notifier).state = _newSeed();

const _excludedPhrases = ['机翻', '机润', '润色', '请返回', '介意者', '语言模型'];

/// Six random series worth a wide card: a cover, two or more volumes and a real synopsis.
final storeRandomPicksProvider = FutureProvider<List<StoreBook>>((ref) async {
  final seed = ref.watch(storeRandomSeedProvider);
  final page = await BookstoreApi.instance
      .books(sort: StoreSort.random, seed: seed, withDescription: true, limit: 40);
  return page.items
      .where((book) {
        final text = book.description ?? '';
        return book.cover != null &&
            book.volumes >= 2 &&
            text.length >= 40 &&
            !_excludedPhrases.any(text.contains);
      })
      .take(6)
      .toList();
});
