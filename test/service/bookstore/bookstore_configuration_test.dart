import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:anx_reader/service/bookstore/store_library.dart';
import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return ResponseBody.fromString(
      jsonEncode({'items': <Object>[], 'source': 'configured'}),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

// An unconfigured service must return before consulting any UI or database.
class _UnusedContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected context access');
}

class _UnusedRef implements WidgetRef {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('Unexpected provider access');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Dio dio;
  late _Adapter adapter;
  var cacheAccesses = 0;

  setUp(() {
    adapter = _Adapter();
    dio = Dio()..httpClientAdapter = adapter;
    cacheAccesses = 0;
  });
  tearDown(() => dio.close(force: true));

  Future<Directory> unavailableCache() async {
    cacheAccesses++;
    throw FileSystemException('No disk cache in this test');
  }

  test('public build has no default bookstore service', () {
    expect(StoreConfig.base, isEmpty);
    expect(StoreConfig.configured, isFalse);
  });

  test('an empty service never turns relative or cached absolute URLs into remote URLs', () {
    for (final path in [
      '/covers/book.webp',
      'files/book.epub',
      '//example.test/book.epub',
      'https://previous.example.test/book.epub'
    ]) {
      expect(StoreConfig.absolute(path, baseUrl: ''), isEmpty);
    }
  });

  test('configured service resolves paths and preserves explicit HTTP URLs', () {
    expect(StoreConfig.absolute('/files/book.epub', baseUrl: 'https://books.example.test/'),
        'https://books.example.test/files/book.epub');
    expect(StoreConfig.absolute('covers/book.webp', baseUrl: 'https://books.example.test/'),
        'https://books.example.test/covers/book.webp');
    expect(StoreConfig.absolute('https://cdn.example.test/cover.webp', baseUrl: 'https://books.example.test'),
        'https://cdn.example.test/cover.webp');
  });

  test('invalid base URLs and non-HTTP resource URLs stay disabled', () {
    for (final base in ['', '/api', 'file:///library', 'https://']) {
      expect(StoreConfig.isConfigured(base), isFalse);
      expect(StoreConfig.absolute('/files/book.epub', baseUrl: base), isEmpty);
    }
    expect(StoreConfig.absolute('file:///book.epub', baseUrl: 'https://books.example.test'), isEmpty);
    expect(StoreConfig.absolute('//other.example.test/book.epub', baseUrl: 'https://books.example.test'), isEmpty);
  });

  test('unconfigured get and watch never request HTTP or inspect an old disk cache', () async {
    final api = BookstoreApi(dio: dio, baseUrl: '', cacheDirectory: unavailableCache);
    await expectLater(api.get('/api/v1/home', (json) => json), throwsStateError);
    await expectLater(api.watch('/api/v1/home', (json) => json).toList(), throwsStateError);
    expect(adapter.requests, isEmpty);
    expect(cacheAccesses, 0);
  });

  test('unconfigured shelf events make no requests', () async {
    final api = BookstoreApi(dio: dio, baseUrl: '', cacheDirectory: unavailableCache);
    await api.reportShelf('123', added: true, install: 'test-install');
    await api.reportShelf('123', added: false, install: 'test-install');
    expect(adapter.requests, isEmpty);
    expect(cacheAccesses, 0);
  });

  test('unconfigured builds do not expose cached cover URLs to image widgets', () {
    final record = StoreRecord.fromDb({
      'store_id': '123',
      'cover_url': 'https://previous.example.test/cover.webp',
    });
    expect(record.coverUrl, isNull);
    expect(record.toBook().cover, isNull);
    final book = StoreBook.fromJson({
      'id': '123',
      'cover': 'https://previous.example.test/cover.webp',
      'cover_large': '/cover/123.webp',
    });
    expect(book.cover, isNull);
    expect(book.coverLarge, isNull);
  });

  test('configured API requests use only the configured service', () async {
    final api = BookstoreApi(
      dio: dio,
      baseUrl: 'https://books.example.test',
      cacheDirectory: unavailableCache,
    );
    final result = await api.get('/api/v1/books', (json) => json, query: {'limit': 5});
    expect(result['source'], 'configured');
    expect(adapter.requests.single.uri.toString(), 'https://books.example.test/api/v1/books?limit=5');
  });

  test('configured shelf events retain their request parameters', () async {
    final api = BookstoreApi(dio: dio, baseUrl: 'https://books.example.test');
    await api.reportShelf('123', added: true, install: 'test-install');
    final request = adapter.requests.single;
    expect(request.uri.origin, 'https://books.example.test');
    expect(request.uri.path, '/api/v1/events');
    expect(request.queryParameters, {
      'type': 'shelf',
      'book': '123',
      'action': 'add',
      'install': 'test-install',
    });
  });

  test('read events report the opened book and whether they were sent', () async {
    final unconfigured = BookstoreApi(dio: dio, baseUrl: '', cacheDirectory: unavailableCache);
    expect(await unconfigured.reportRead('123', install: 'test-install'), isFalse);
    expect(adapter.requests, isEmpty);
    final api = BookstoreApi(dio: dio, baseUrl: 'https://books.example.test');
    expect(await api.reportRead('123', install: 'test-install'), isTrue);
    final request = adapter.requests.single;
    expect(request.uri.path, '/api/v1/events');
    expect(request.queryParameters, {
      'type': 'read',
      'action': 'open',
      'book': '123',
      'install': 'test-install',
    });
  });

  test('unconfigured volume open and reopen never begin a download or inspect UI state', () async {
    final library = StoreLibrary(dio: dio);
    final detail = StoreBookDetail.fromJson({
      'id': '123',
      'title': 'Book',
      'volume_list': [
        {'n': 1, 'url': '/files/123/1.epub'},
      ],
    });
    await library.open(_UnusedContext(), _UnusedRef(), detail, detail.volumeList.single);
    await library.reopen(_UnusedRef(), _UnusedContext(), Book.mock());
    expect(adapter.requests, isEmpty);
  });
}
