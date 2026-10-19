import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/update/github_release.dart';
import 'package:anx_reader/service/update/update_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _BytesAdapter implements HttpClientAdapter {
  _BytesAdapter(this.bytes);

  final List<int> bytes;
  final requests = <Uri>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options.uri);
    return ResponseBody.fromBytes(bytes, 200, headers: {
      Headers.contentLengthHeader: ['${bytes.length}'],
    });
  }

  @override
  void close({bool force = false}) {}
}

GitHubReleaseAsset _asset({String host = 'github.com', String name = 'Monogatari-Novel-Android-universal.apk', String sha = '', int size = 0}) =>
    GitHubReleaseAsset(
      name: name,
      downloadUrl: Uri.https(host, '/Teikaraku/monogatari-novel/releases/download/v1.0.0/$name'),
      sha256: sha,
      size: size,
    );

void main() {
  late Directory cache;
  final bytes = utf8.encode('package contents');
  final digest = sha256.convert(bytes).toString();

  setUp(() async => cache = await Directory.systemTemp.createTemp('novel_update_test_'));
  tearDown(() async {
    if (await cache.exists()) await cache.delete(recursive: true);
  });

  UpdateDownloader downloader(_BytesAdapter adapter) =>
      UpdateDownloader(dio: Dio()..httpClientAdapter = adapter, cacheDirectory: () async => cache);

  test('a package matching its digest is kept under its own name', () async {
    final file = await downloader(_BytesAdapter(bytes)).download(_asset(sha: digest, size: bytes.length));
    expect(file.path.endsWith('Monogatari-Novel-Android-universal.apk'), isTrue);
    expect(await file.readAsBytes(), bytes);
  });

  test('a package that fails verification is deleted', () async {
    await expectLater(
      downloader(_BytesAdapter(bytes)).download(_asset(sha: '0' * 64)),
      throwsA(isA<FormatException>()),
    );
    expect(cache.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test('a truncated package is rejected', () async {
    await expectLater(
      downloader(_BytesAdapter(bytes)).download(_asset(size: bytes.length + 10)),
      throwsA(isA<FormatException>()),
    );
  });

  test('only GitHub hosts and plain file names are accepted', () async {
    final adapter = _BytesAdapter(bytes);
    await expectLater(downloader(adapter).download(_asset(host: 'example.com')), throwsA(isA<FormatException>()));
    await expectLater(downloader(adapter).download(_asset(name: '.hidden.apk')), throwsA(isA<FormatException>()));
    expect(adapter.requests, isEmpty);
  });

  test('a new download replaces the previous package', () async {
    final first = await downloader(_BytesAdapter(bytes)).download(_asset(name: 'a-android.apk'));
    await downloader(_BytesAdapter(bytes)).download(_asset(name: 'b-android.apk'));
    expect(await first.exists(), isFalse);
  });
}
