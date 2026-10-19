import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

class _Entry {
  _Entry(this.body, this.etag, this.fetchedAt);

  final List<int> body;
  final String? etag;
  DateTime fetchedAt;
  Object? decoded;

  Map<String, dynamic> get json => (decoded ??= jsonDecode(utf8.decode(body))) as Map<String, dynamic>;
}

/// Client for the bookstore API with a two-level cache: answers come from memory or disk at once and
/// are revalidated with If-None-Match, so pages open instantly and a 304 costs no download.
class BookstoreApi {
  BookstoreApi({
    Dio? dio,
    String baseUrl = StoreConfig.base,
    Future<Directory> Function()? cacheDirectory,
  })  : _baseUrl = baseUrl,
        _dio = dio ?? Dio(),
        _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory {
    _dio.options = _dio.options.copyWith(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.bytes,
      validateStatus: (status) => status != null && (status == 304 || status < 400),
    );
  }

  static final instance = BookstoreApi();

  /// The server marks responses fresh for 60 seconds; within that window no request is made.
  static const _freshFor = Duration(seconds: 60);
  static const _memoryLimit = 96;

  final String _baseUrl;
  final Dio _dio;
  final Future<Directory> Function() _cacheDirectory;
  final _memory = <String, _Entry>{};
  final _inflight = <String, Future<_Entry>>{};
  Future<Directory>? _dir;

  void _requireConfigured() {
    if (!StoreConfig.isConfigured(_baseUrl)) {
      throw StateError('Bookstore service is not configured');
    }
  }

  Future<Directory> _cacheDir() => _dir ??= () async {
        _requireConfigured();
        final service = sha1.convert(utf8.encode(_baseUrl)).toString();
        final dir = Directory('${(await _cacheDirectory()).path}/bookstore/$service');
        await dir.create(recursive: true);
        return dir;
      }();

  String _key(String path, Map<String, Object?> query) {
    final params = query.entries
        .where((e) => e.value != null)
        .expand((e) => e.value is List ? (e.value as List).map((v) => '${e.key}=$v') : ['${e.key}=${e.value}'])
        .toList()
      ..sort();
    return params.isEmpty ? path : '$path?${params.join('&')}';
  }

  void _remember(String key, _Entry entry) {
    _memory.remove(key);
    _memory[key] = entry;
    while (_memory.length > _memoryLimit) {
      _memory.remove(_memory.keys.first);
    }
  }

  Future<_Entry?> _readDisk(String key) async {
    try {
      final dir = await _cacheDir();
      final name = sha1.convert(utf8.encode(key)).toString();
      final body = File('${dir.path}/$name.body');
      if (!await body.exists()) return null;
      final etagFile = File('${dir.path}/$name.etag');
      final etag = await etagFile.exists() ? await etagFile.readAsString() : null;
      // A disk copy is shown immediately but always revalidated.
      return _Entry(await body.readAsBytes(), etag, DateTime.fromMillisecondsSinceEpoch(0));
    } catch (e) {
      AnxLog.warning('Bookstore cache read failed: $e');
      return null;
    }
  }

  Future<void> _writeDisk(String key, _Entry entry) async {
    try {
      final dir = await _cacheDir();
      final name = sha1.convert(utf8.encode(key)).toString();
      await File('${dir.path}/$name.body').writeAsBytes(entry.body, flush: false);
      if (entry.etag != null) {
        await File('${dir.path}/$name.etag').writeAsString(entry.etag!);
      }
    } catch (e) {
      AnxLog.warning('Bookstore cache write failed: $e');
    }
  }

  Future<_Entry> _fetch(String path, Map<String, Object?> query, String key, _Entry? cached) {
    return _inflight[key] ??= () async {
      try {
        final response = await _dio.get<List<int>>(
          path,
          queryParameters: {
            for (final e in query.entries)
              if (e.value != null) e.key: e.value,
          },
          options: Options(headers: {
            if (cached?.etag != null) HttpHeaders.ifNoneMatchHeader: cached!.etag,
          }),
        );
        if (response.statusCode == 304 && cached != null) {
          cached.fetchedAt = DateTime.now();
          _remember(key, cached);
          return cached;
        }
        final entry = _Entry(
          response.data ?? const [],
          response.headers.value(HttpHeaders.etagHeader),
          DateTime.now(),
        );
        entry.json; // Fail here, not in the UI, if the body is not JSON.
        _remember(key, entry);
        unawaited(_writeDisk(key, entry));
        return entry;
      } finally {
        _inflight.remove(key);
      }
    }();
  }

  /// Emits the cached answer first (when there is one) and then the server's, unless unchanged.
  /// Network errors are swallowed when a cached answer was already emitted.
  Stream<T> watch<T>(
    String path,
    T Function(Map<String, dynamic> json) parse, {
    Map<String, Object?> query = const {},
    bool revalidate = false,
  }) async* {
    _requireConfigured();
    final key = _key(path, query);
    final cached = _memory[key] ?? await _readDisk(key);
    if (cached != null) {
      _remember(key, cached);
      yield parse(cached.json);
      if (!revalidate && DateTime.now().difference(cached.fetchedAt) < _freshFor) return;
    }
    try {
      final fresh = await _fetch(path, query, key, cached);
      if (!identical(fresh, cached)) yield parse(fresh.json);
    } catch (e) {
      if (cached == null) rethrow;
      AnxLog.info('Bookstore offline, kept cached $key: $e');
    }
  }

  /// The freshest answer available: cache within the freshness window, otherwise the network
  /// (falling back to an older cached copy when offline).
  Future<T> get<T>(
    String path,
    T Function(Map<String, dynamic> json) parse, {
    Map<String, Object?> query = const {},
  }) async {
    _requireConfigured();
    final key = _key(path, query);
    final cached = _memory[key] ?? await _readDisk(key);
    if (cached != null && DateTime.now().difference(cached.fetchedAt) < _freshFor) {
      return parse(cached.json);
    }
    try {
      return parse((await _fetch(path, query, key, cached)).json);
    } catch (e) {
      if (cached == null) rethrow;
      return parse(cached.json);
    }
  }

  /// [revalidate] asks the server even within the freshness window (pull to refresh).
  Stream<StoreHome> home({bool revalidate = false}) =>
      watch('/api/v1/home', StoreHome.fromJson, revalidate: revalidate);

  Stream<StoreBookDetail> book(String id) => watch('/api/v1/books/$id', StoreBookDetail.fromJson);

  Future<List<StoreTocItem>> volumeToc(String id, int n) => get(
        '/api/v1/books/$id/volumes/$n/toc',
        (json) => (json['items'] as List? ?? const [])
            .map((item) => StoreTocItem.fromJson(item as Map<String, dynamic>))
            .where((item) => item.title.isNotEmpty && item.href.isNotEmpty)
            .toList(),
      );

  Future<StorePage> books({
    List<String> tags = const [],
    StoreStatus? status,
    StoreSort sort = StoreSort.updated,
    int? seed,
    int? minVolumes,
    int? maxVolumes,
    bool withDescription = false,
    int offset = 0,
    int limit = 30,
  }) =>
      get('/api/v1/books', StorePage.fromJson, query: {
        if (tags.isNotEmpty) 'tag': tags,
        if (status != null && status != StoreStatus.unknown) 'status': status.name,
        'sort': sort.name,
        if (sort == StoreSort.random) 'seed': seed,
        if (minVolumes != null) 'min_volumes': minVolumes,
        if (maxVolumes != null) 'max_volumes': maxVolumes,
        if (withDescription) 'with_description': 1,
        'offset': offset,
        'limit': limit,
      });

  Stream<StoreDiscover> discover() => watch('/api/v1/discover', StoreDiscover.fromJson);

  Future<StorePage> theme(String key, {StoreSort sort = StoreSort.random, int? seed, int offset = 0, int limit = 30}) =>
      get('/api/v1/themes/$key', StorePage.fromJson, query: {
        'sort': sort.name,
        if (sort == StoreSort.random) 'seed': seed,
        'offset': offset,
        'limit': limit,
      });

  Future<StorePage> search(String q, {int offset = 0, int limit = 30}) =>
      get('/api/v1/search', StorePage.fromJson, query: {'q': q, 'offset': offset, 'limit': limit});

  Future<StorePage> rank(StoreRankPeriod period,
          {StoreBoard board = StoreBoard.popular, int offset = 0, int limit = 30}) =>
      get('/api/v1/rank', StorePage.fromJson, query: {
        if (board != StoreBoard.popular) 'board': board.api,
        if (board.periodic) 'period': period.name,
        'offset': offset,
        'limit': limit,
      });

  /// Anonymous shelf events feed the favourites chart; failures are ignored.
  Future<void> reportShelf(String bookId, {required bool added, required String install}) async {
    if (!StoreConfig.isConfigured(_baseUrl)) return;
    try {
      await _dio.get<List<int>>('/api/v1/events', queryParameters: {
        'type': 'shelf',
        'book': bookId,
        'action': added ? 'add' : 'remove',
        'install': install,
      });
    } catch (e) {
      AnxLog.info('Bookstore shelf event not sent: $e');
    }
  }

  Future<StorePage> tv(StoreTvStatus section, {int offset = 0, int limit = 30}) =>
      get('/api/v1/tv', StorePage.fromJson, query: {'section': section.name, 'offset': offset, 'limit': limit});

  Future<List<StoreTag>> tags({int covers = 0}) => get(
        '/api/v1/tags',
        query: {if (covers > 0) 'covers': covers},
        (json) => (json['tags'] as List? ?? const []).map((t) => StoreTag.fromJson(t as Map<String, dynamic>)).toList(),
      );
}
