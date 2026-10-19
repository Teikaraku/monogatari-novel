import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/service/update/github_release.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);

  final FutureOr<ResponseBody> Function(RequestOptions) reply;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return await reply(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _response(Object? data, {int status = 200, String contentType = 'application/json'}) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: ['$contentType; charset=utf-8'],
      },
    );

Map<String, Object?> _release({List<Object?> assets = const []}) => {
      'tag_name': 'monogatari-v1.2.3',
      'body': '# 更新\n阅读体验改善 📚',
      'draft': false,
      'prerelease': false,
      'assets': assets,
    };

Map<String, Object?> _asset(String name, {String? url}) => {
      'name': name,
      'browser_download_url': url ?? 'https://github.com/owner/novel/releases/download/monogatari-v1.2.3/$name',
    };

void main() {
  GitHubReleases client(_Adapter adapter, {String repository = 'owner/novel'}) {
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    return GitHubReleases(repository: repository, dio: dio);
  }

  for (final contentType in ['application/json', 'text/plain']) {
    test('reads the configured latest release as plain text with $contentType', () async {
      final adapter = _Adapter((_) => _response(_release(), contentType: contentType));
      final release = await client(adapter).latest();
      final request = adapter.requests.single;
      expect(request.uri.toString(), 'https://api.github.com/repos/owner/novel/releases/latest');
      expect(request.method, 'GET');
      expect(request.responseType, ResponseType.plain);
      expect(request.headers['Accept'], 'application/vnd.github+json');
      expect(request.headers.keys.any((key) => key.toLowerCase() == 'authorization'), isFalse);
      expect(release!.tagName, 'monogatari-v1.2.3');
      expect(release.displayVersion, '1.2.3');
      expect(release.body, '# 更新\n阅读体验改善 📚');
      expect(release.releaseUrl.toString(), 'https://github.com/owner/novel/releases/tag/monogatari-v1.2.3');
    });
  }

  for (final repository in ['', ' ', 'owner', 'owner/repo/extra', 'https://github.com/owner/repo', 'owner/..']) {
    test('does not request an unconfigured or invalid repository: $repository', () async {
      final adapter = _Adapter((_) => throw StateError('Must not request'));
      final releases = client(adapter, repository: repository);
      expect(releases.isConfigured, isFalse);
      expect(await releases.latest(), isNull);
      expect(adapter.requests, isEmpty);
    });
  }

  test('a missing public release returns null without parsing a 404 body', () async {
    final adapter = _Adapter((_) => ResponseBody.fromString('Not Found', 404));
    expect(await client(adapter).latest(), isNull);
    expect(adapter.requests, hasLength(1));
  });

  for (final field in ['draft', 'prerelease']) {
    test('ignores $field releases', () async {
      final adapter = _Adapter((_) => _response(_release()..[field] = true));
      expect(await client(adapter).latest(), isNull);
    });
  }

  for (final status in [401, 403, 429, 500]) {
    test('surfaces HTTP $status as a check failure', () async {
      final adapter = _Adapter((_) => _response({'message': 'Unavailable'}, status: status));
      await expectLater(client(adapter).latest(), throwsA(isA<DioException>()));
      expect(adapter.requests, hasLength(1));
    });
  }

  test('invalid JSON is a check failure', () async {
    final adapter = _Adapter((_) => ResponseBody.fromString('not JSON', 200));
    await expectLater(client(adapter).latest(), throwsFormatException);
  });

  for (final entry in <String, Object?>{
    'null': null,
    'list': [],
    'missing tag': {'assets': []},
    'empty tag': {'tag_name': ' '},
    'numeric tag': {'tag_name': 123},
    'invalid assets': {'tag_name': 'v1.0.0', 'assets': {}},
    'invalid body': {'tag_name': 'v1.0.0', 'body': []},
  }.entries) {
    test('rejects malformed metadata: ${entry.key}', () async {
      final adapter = _Adapter((_) => _response(entry.value));
      await expectLater(client(adapter).latest(), throwsFormatException);
    });
  }

  test('omitted body and assets are valid for a release page only', () async {
    final adapter = _Adapter((_) => _response({'tag_name': 'v2.0.0'}));
    final release = (await client(adapter).latest())!;
    expect(release.body, isEmpty);
    expect(release.assets, isEmpty);
    expect(release.assetFor('ios'), isNull);
    expect(release.releaseUrl.toString(), 'https://github.com/owner/novel/releases/tag/v2.0.0');
  });

  test('only accepts assets from the configured repository and exact release', () async {
    final adapter = _Adapter((_) => _response(_release(assets: [
          _asset('valid.apk'),
          _asset('case.apk', url: 'https://github.com/OWNER/NOVEL/releases/download/monogatari-v1.2.3/case.apk'),
          _asset('bad.apk', url: 'http://github.com/owner/novel/releases/download/monogatari-v1.2.3/bad.apk'),
          _asset('bad.apk', url: 'https://example.com/owner/novel/releases/download/monogatari-v1.2.3/bad.apk'),
          _asset('bad.apk', url: 'https://github.com/other/repo/releases/download/monogatari-v1.2.3/bad.apk'),
          _asset('bad.apk', url: 'https://github.com/owner/novel/releases/download/v9.0.0/bad.apk'),
          _asset('bad.apk', url: 'https://user@github.com/owner/novel/releases/download/monogatari-v1.2.3/bad.apk'),
          _asset('bad.apk', url: 'https://github.com:123/owner/novel/releases/download/monogatari-v1.2.3/bad.apk'),
          _asset('bad.apk', url: 'https://github.com/owner/novel/releases/latest'),
          {'name': 'bad.apk', 'browser_download_url': 123},
          {'browser_download_url': 'https://github.com/'},
          null,
        ])));
    final release = (await client(adapter).latest())!;
    expect(release.assets.map((asset) => asset.name), ['valid.apk', 'case.apk']);
    expect(() => release.assets.clear(), throwsUnsupportedError);
  });

  test('release page ignores an unrelated html_url or mirror field', () async {
    final adapter = _Adapter((_) => _response(_release()
      ..['html_url'] = 'https://example.com/releases/latest'
      ..['mirror'] = 'https://example.com/updates'));
    final release = (await client(adapter).latest())!;
    expect(release.releaseUrl.toString(), 'https://github.com/owner/novel/releases/tag/monogatari-v1.2.3');
  });

  test('concurrent checks share one request and a later check refreshes metadata', () async {
    final ready = Completer<void>();
    final adapter = _Adapter((_) async {
      await ready.future;
      return _response(_release());
    });
    final releases = client(adapter);
    final first = releases.latest();
    final second = releases.latest();
    expect(identical(first, second), isTrue);
    ready.complete();
    expect(await first, same(await second));
    expect(adapter.requests, hasLength(1));
    await releases.latest();
    expect(adapter.requests, hasLength(2));
  });

  test('a failed check does not prevent a later request', () async {
    var attempts = 0;
    final adapter =
        _Adapter((_) => ++attempts == 1 ? ResponseBody.fromString('Unavailable', 500) : _response(_release()));
    final releases = client(adapter);
    await expectLater(releases.latest(), throwsA(isA<DioException>()));
    expect(await releases.latest(), isNotNull);
    expect(attempts, 2);
  });

  test('a stalled response times out and releases the shared request for a successful retry', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) {
      if (++requests == 1) return; // Keep the first connection open without sending a response.
      request.response.headers.contentType = ContentType.text;
      request.response.write(jsonEncode(_release()));
      unawaited(request.response.close());
    });
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 1),
      receiveTimeout: const Duration(milliseconds: 200),
    ));
    addTearDown(() => dio.close(force: true));
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      options.path = 'http://127.0.0.1:${server.port}/latest';
      handler.next(options);
    }));
    final releases = GitHubReleases(repository: 'owner/novel', dio: dio);
    final stalled = releases.latest();
    expect(identical(stalled, releases.latest()), isTrue);
    await expectLater(
      stalled,
      throwsA(isA<DioException>().having((error) => error.type, 'type', DioExceptionType.receiveTimeout)),
    );
    expect(requests, 1);
    final retry = releases.latest();
    expect(identical(retry, stalled), isFalse);
    expect((await retry)!.tagName, 'monogatari-v1.2.3');
    expect(requests, 2);
  });

  group('release assets', () {
    late GitHubRelease release;

    setUp(() async {
      final adapter = _Adapter((_) => _response(_release(assets: [
            _asset('Monogatari-Novel-Android-universal.apk'),
            _asset('Monogatari-Novel-Android-arm64.apk'),
            _asset('Monogatari-Novel-Android-armv7.apk'),
            _asset('Monogatari-Novel-Android-x64.apk'),
            _asset('Monogatari-Novel-Android-x86.apk'),
            _asset('Monogatari-Novel-Android.aab'),
            _asset('Monogatari-Novel-iOS-unsigned.ipa'),
          ])));
      release = (await client(adapter).latest())!;
    });

    for (final entry in {
      Abi.androidArm64: 'arm64',
      Abi.androidArm: 'armv7',
      Abi.androidX64: 'x64',
      Abi.androidIA32: 'x86',
    }.entries) {
      test('Android ${entry.value} prefers its exact ABI over universal', () {
        expect(release.assetFor('android', abi: entry.key)!.name, 'Monogatari-Novel-Android-${entry.value}.apk');
      });
    }

    test('iOS uses the IPA attached to the selected release', () {
      final asset = release.assetFor('ios')!;
      expect(asset.name, 'Monogatari-Novel-iOS-unsigned.ipa');
      expect(asset.downloadUrl.toString(),
          'https://github.com/owner/novel/releases/download/monogatari-v1.2.3/Monogatari-Novel-iOS-unsigned.ipa');
    });

    test('unsupported platforms do not select mobile installers', () {
      expect(release.assetFor('windows'), isNull);
      expect(release.assetFor('macos'), isNull);
      expect(release.assetFor('linux'), isNull);
      expect(release.assetFor('android', abi: Abi.windowsX64), isNull);
    });

    test('falls back to an explicitly universal APK', () {
      final universal = GitHubRelease(
        repository: release.repository,
        tagName: release.tagName,
        body: release.body,
        assets: [release.assets.first],
      );
      expect(universal.assetFor('android', abi: Abi.androidX64)!.name, 'Monogatari-Novel-Android-universal.apk');
    });

    test('never assumes an unlabelled or incompatible APK is universal', () async {
      final adapter = _Adapter((_) => _response(_release(assets: [
            _asset('Monogatari-Novel-Android.apk'),
            _asset('Monogatari-Novel-Android-arm64.apk'),
          ])));
      final release = (await client(adapter).latest())!;
      expect(release.assetFor('android', abi: Abi.androidX64), isNull);
    });
  });

  group('semantic versions', () {
    for (final prefix in ['', 'v', 'monogatari-v']) {
      test('accepts $prefix tags and compares numeric version components', () {
        expect(isNewerRelease('1.2.9+100', '${prefix}1.2.10'), isTrue);
        expect(isNewerRelease('1.2.9', '${prefix}1.3.0'), isTrue);
        expect(isNewerRelease('1.9.0', '${prefix}2.0.0'), isTrue);
        expect(isNewerRelease('2.0.0', '${prefix}1.9.99'), isFalse);
        expect(isNewerRelease('1.2.9+1', '${prefix}1.2.9+2'), isFalse);
      });
    }

    test('compares prerelease precedence with SemVer rules', () {
      const ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0'
      ];
      for (var i = 0; i < ordered.length - 1; i++) {
        expect(isNewerRelease(ordered[i], ordered[i + 1]), isTrue);
        expect(isNewerRelease(ordered[i + 1], ordered[i]), isFalse);
      }
    });

    for (final invalid in [
      '',
      'version1.0.0',
      'v1.0',
      '1.0.0.1',
      '01.0.0',
      '1.0.0-01',
      '1.0.0-',
      '1.0.0+',
      '1.0.0\n'
    ]) {
      test('malformed version cannot trigger an update: ${jsonEncode(invalid)}', () {
        expect(isNewerRelease('0.0.1', invalid), isFalse);
        expect(isNewerRelease(invalid, '99.0.0'), isFalse);
      });
    }
  });
}
