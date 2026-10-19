import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/service/translate/microsoft_free.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Request {
  const _Request(this.options, this.body);

  final RequestOptions options;
  final String body;

  List<String> get texts => (jsonDecode(body) as List).cast<String>();
}

class _Adapter implements HttpClientAdapter {
  _Adapter(this.reply);

  final FutureOr<ResponseBody> Function(_Request) reply;
  final List<_Request> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = requestStream == null ? '' : await utf8.decoder.bind(requestStream).join();
    final request = _Request(options, body);
    requests.add(request);
    return await reply(request);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object? value, [int status = 200]) => ResponseBody.fromString(
      jsonEncode(value),
      status,
      headers: {
        Headers.contentTypeHeader: ['application/json; charset=utf-8'],
      },
    );

ResponseBody _translated([List<String> values = const ['译文']]) => _json([
      for (final value in values)
        {
          'translations': [
            {'text': value, 'to': 'zh-Hans'},
          ],
        },
    ]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MicrosoftFreeTranslateProvider provider(_Adapter adapter) {
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    return MicrosoftFreeTranslateProvider(dio: dio);
  }

  Future<List<String>> translate(
    MicrosoftFreeTranslateProvider value, {
    String text = 'Hello 世界',
    LangListEnum from = LangListEnum.auto,
    LangListEnum to = LangListEnum.simplifiedChinese,
  }) =>
      value.translateStream(text, from, to).toList();

  Future<List<String>> batch(MicrosoftFreeTranslateProvider value, List<String> texts) =>
      value.translateBatch(texts, LangListEnum.auto, LangListEnum.simplifiedChinese);

  test('registers the free provider first', () {
    expect(TranslateService.values.first, TranslateService.microsoftFree);
    expect(TranslateService.microsoftFree.provider, isA<MicrosoftFreeTranslateProvider>());
    expect(getTranslateService('microsoftFree'), TranslateService.microsoftFree);
    expect(getTranslateService('microsoft'), TranslateService.microsoftApi);
    expect(TranslateService.microsoftFree.isWebView, isFalse);
  });

  test('uses the exact endpoint, JSON strings, and automatic source detection without authorization', () async {
    final adapter = _Adapter((_) => _json([
          {
            'detectedLanguage': {'language': 'en', 'score': 1.0},
            'translations': [
              {'text': '译文', 'to': 'zh-Hans', 'sentLen': {}},
            ],
          },
        ]));

    expect(await translate(provider(adapter)), ['...', '译文']);
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.options.method, 'POST');
    expect(request.options.uri.scheme, 'https');
    expect(request.options.uri.host, 'edge.microsoft.com');
    expect(request.options.uri.path, '/translate/translatetext');
    expect(request.options.uri.queryParameters, {
      'api-version': '3.0',
      'isEnterpriseClient': 'false',
      'to': 'zh-Hans',
    });
    expect(request.options.headers.keys.any((key) => key.toLowerCase() == 'authorization'), isFalse);
    expect(request.options.contentType, 'application/json');
    expect(request.options.responseType, ResponseType.plain);
    expect(jsonDecode(request.body), ['Hello 世界']);
  });

  test('decodes a Unicode JSON translation served as text/plain', () async {
    final adapter = _Adapter((_) => ResponseBody.fromString(
          jsonEncode([
            {
              'translations': [
                {'text': '译文：こんにちは 😀', 'to': 'zh-Hans'},
              ],
            },
          ]),
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
          },
        ));
    expect(await translate(provider(adapter)), ['...', '译文：こんにちは 😀']);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.options.responseType, ResponseType.plain);
  });

  test('decodes Unicode text/plain JSON responses across sequential batches', () async {
    final inputs = List.generate(51, (index) => '第 $index 段 😀');
    final adapter = _Adapter((request) => ResponseBody.fromString(
          jsonEncode([
            for (final text in request.texts)
              {
                'translations': [
                  {'text': '译文：$text', 'to': 'zh-Hans'},
                ],
              },
          ]),
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
          },
        ));
    expect(await batch(provider(adapter), inputs), inputs.map((text) => '译文：$text').toList());
    expect(adapter.requests.map((request) => request.texts.length), [50, 1]);
    expect(adapter.requests.map((request) => request.options.responseType), everyElement(ResponseType.plain));
  });

  for (final contentType in ['text/plain; charset=utf-8', 'application/json; charset=utf-8']) {
    test('invalid JSON served as $contentType reports a Microsoft API Error', () async {
      final adapter = _Adapter((_) => ResponseBody.fromString(
            '{invalid JSON 😀',
            200,
            headers: {
              Headers.contentTypeHeader: [contentType],
            },
          ));
      await expectLater(
        provider(adapter).translateStream('paragraph', LangListEnum.auto, LangListEnum.simplifiedChinese),
        emitsInOrder([
          '...',
          emitsError(isA<Exception>().having((error) => error.toString(), 'message', contains('Microsoft API Error'))),
          emitsDone,
        ]),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.options.responseType, ResponseType.plain);
    });
  }

  test('a batch with invalid text/plain JSON fails as a Microsoft API Error', () async {
    final adapter = _Adapter((_) => ResponseBody.fromString(
          '[{"translations":',
          200,
          headers: {
            Headers.contentTypeHeader: ['text/plain; charset=utf-8'],
          },
        ));
    await expectLater(
      batch(provider(adapter), ['first', 'second']),
      throwsA(isA<Exception>().having((error) => error.toString(), 'message', contains('Microsoft API Error'))),
    );
    expect(adapter.requests, hasLength(1));
  });

  test('does not inherit stale Dio headers or query parameters or mutate its base options', () async {
    final adapter = _Adapter((_) => _translated());
    final dio = Dio(BaseOptions(
      headers: {'Authorization': 'Bearer obsolete', 'X-Old': 'unused'},
      queryParameters: {'from': 'ja', 'to': 'ru', 'old': 'unused'},
      connectTimeout: const Duration(seconds: 2),
    ))
      ..httpClientAdapter = adapter;
    addTearDown(() => dio.close(force: true));
    expect(await translate(MicrosoftFreeTranslateProvider(dio: dio)), ['...', '译文']);
    final request = adapter.requests.single.options;
    expect(request.uri.queryParameters, {
      'api-version': '3.0',
      'isEnterpriseClient': 'false',
      'to': 'zh-Hans',
    });
    expect(request.headers.keys.any((key) => key.toLowerCase() == 'authorization'), isFalse);
    expect(request.headers.keys.any((key) => key.toLowerCase() == 'x-old'), isFalse);
    expect(request.connectTimeout, const Duration(seconds: 2));
    expect(dio.options.headers['Authorization'], 'Bearer obsolete');
    expect(dio.options.headers['X-Old'], 'unused');
    expect(dio.options.queryParameters, {'from': 'ja', 'to': 'ru', 'old': 'unused'});
  });

  test('maps all supported enum codes and preserves Norwegian Bokmal nb', () {
    final value = provider(_Adapter((_) => throw StateError('No request expected')));
    const expected = {
      LangListEnum.english: 'en',
      LangListEnum.simplifiedChinese: 'zh-Hans',
      LangListEnum.traditionalChinese: 'zh-Hant',
      LangListEnum.arabic: 'ar',
      LangListEnum.bulgarian: 'bg',
      LangListEnum.catalan: 'ca',
      LangListEnum.croatian: 'hr',
      LangListEnum.czech: 'cs',
      LangListEnum.danish: 'da',
      LangListEnum.dutch: 'nl',
      LangListEnum.finnish: 'fi',
      LangListEnum.french: 'fr',
      LangListEnum.german: 'de',
      LangListEnum.greek: 'el',
      LangListEnum.hindi: 'hi',
      LangListEnum.hungarian: 'hu',
      LangListEnum.indonesian: 'id',
      LangListEnum.italian: 'it',
      LangListEnum.japanese: 'ja',
      LangListEnum.korean: 'ko',
      LangListEnum.malay: 'ms',
      LangListEnum.maltese: 'mt',
      LangListEnum.norwegian: 'nb',
      LangListEnum.polish: 'pl',
      LangListEnum.portuguese: 'pt',
      LangListEnum.romanian: 'ro',
      LangListEnum.russian: 'ru',
      LangListEnum.slovak: 'sk',
      LangListEnum.slovenian: 'sl',
      LangListEnum.spanish: 'es',
      LangListEnum.swedish: 'sv',
      LangListEnum.tamil: 'ta',
      LangListEnum.telugu: 'te',
      LangListEnum.thai: 'th',
      LangListEnum.turkish: 'tr',
      LangListEnum.ukrainian: 'uk',
      LangListEnum.vietnamese: 'vi',
    };
    for (final entry in expected.entries) {
      expect(value.mapLanguageCode(entry.key), entry.value, reason: entry.key.name);
    }
  });

  test('includes mapped explicit source and target codes', () async {
    final adapter = _Adapter((_) => _translated());
    await translate(provider(adapter), from: LangListEnum.traditionalChinese, to: LangListEnum.norwegian);
    expect(adapter.requests.single.options.uri.queryParameters, {
      'api-version': '3.0',
      'isEnterpriseClient': 'false',
      'to': 'nb',
      'from': 'zh-Hant',
    });
  });

  for (final unsupported in [LangListEnum.crimeanTatarLatin, LangListEnum.crimeanTatarCyrillic]) {
    test('falls back to detection and English for ${unsupported.name}', () async {
      final adapter = _Adapter((_) => _translated());
      await translate(provider(adapter), from: unsupported, to: unsupported);
      expect(adapter.requests.single.options.uri.queryParameters, {
        'api-version': '3.0',
        'isEnterpriseClient': 'false',
        'to': 'en',
      });
    });
  }

  test('batch translates each response in order using its first translation', () async {
    final adapter = _Adapter((_) => _json([
          {
            'translations': [
              {'text': 'first result'},
              {'text': 'ignored alternative'},
            ],
          },
          {
            'translations': [
              {'text': 'second result'},
            ],
          },
        ]));
    expect(await batch(provider(adapter), ['first input', 'second input']), ['first result', 'second result']);
    expect(adapter.requests.single.texts, ['first input', 'second input']);
  });

  test('an empty batch returns immediately without making a request', () async {
    final adapter = _Adapter((_) => throw StateError('No request expected'));
    expect(await batch(provider(adapter), []), isEmpty);
    expect(adapter.requests, isEmpty);
  });

  test('exactly 50 paragraphs fit in one request', () async {
    final inputs = List.generate(50, (index) => 'paragraph $index');
    final adapter = _Adapter((request) => _translated(request.texts));
    expect(await batch(provider(adapter), inputs), inputs);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.texts, inputs);
  });

  test('51 paragraphs are split into batches of 50 and one', () async {
    final inputs = List.generate(51, (index) => 'paragraph $index');
    final adapter = _Adapter((request) => _translated(request.texts));
    expect(await batch(provider(adapter), inputs), inputs);
    expect(adapter.requests.map((request) => request.texts.length), [50, 1]);
    expect(adapter.requests.expand((request) => request.texts), inputs);
  });

  test('exactly 50000 characters across paragraphs fit in one request', () async {
    final inputs = ['a' * 25000, 'b' * 25000];
    final adapter = _Adapter((request) => _translated(request.texts));
    expect(await batch(provider(adapter), inputs), inputs);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.texts, inputs);
  });

  test('50001 characters across paragraphs require a second request', () async {
    final inputs = ['a' * 25000, 'b' * 25000, 'c'];
    final adapter = _Adapter((request) => _translated(request.texts));
    expect(await batch(provider(adapter), inputs), inputs);
    expect(adapter.requests.map((request) => request.texts.length), [2, 1]);
    expect(adapter.requests.map((request) => request.texts.fold<int>(0, (sum, text) => sum + text.length)), [50000, 1]);
    expect(adapter.requests.expand((request) => request.texts), inputs);
  });

  test('a 50001-character paragraph is split and reassembled into one result', () async {
    final input = 'a' * 50000 + 'b';
    final adapter = _Adapter((request) => _translated(request.texts.map((text) => 'part${text.length}').toList()));
    expect(await batch(provider(adapter), [input]), ['part50000part1']);
    expect(adapter.requests.map((request) => request.texts.single.length), [50000, 1]);
    expect(adapter.requests.expand((request) => request.texts).join(), input);
  });

  test('multiple fragments keep the original paragraph count and order', () async {
    final inputs = ['prefix', '${'a' * 50000}${'b' * 50000}c', 'suffix'];
    final adapter = _Adapter((request) => _translated(request.texts.map((text) => text.toUpperCase()).toList()));
    expect(await batch(provider(adapter), inputs), inputs.map((text) => text.toUpperCase()).toList());
    expect(adapter.requests.length, greaterThanOrEqualTo(3));
    for (final request in adapter.requests) {
      expect(request.texts.length, lessThanOrEqualTo(50));
      expect(request.texts.fold<int>(0, (sum, text) => sum + text.runes.length), lessThanOrEqualTo(50000));
    }
  });

  test('character limits count Unicode code points rather than UTF-16 code units', () async {
    final inputs = ['😀' * 25000, 'a' * 25000];
    final adapter = _Adapter((request) => _translated(request.texts));
    expect(await batch(provider(adapter), inputs), inputs);
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.texts.fold<int>(0, (sum, text) => sum + text.runes.length), 50000);
    expect(adapter.requests.single.texts.fold<int>(0, (sum, text) => sum + text.length), 75000);
  });

  test('splitting a long Unicode paragraph never cuts a surrogate pair', () async {
    final input = '😀' * 49999 + '🦊a';
    final adapter = _Adapter((request) => _translated(request.texts));
    expect(await batch(provider(adapter), [input]), [input]);
    expect(adapter.requests.map((request) => request.texts.single.runes.length), [50000, 1]);
    for (final request in adapter.requests) {
      for (final text in request.texts) {
        expect(text.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff), isFalse);
      }
    }
  });

  test('batch requests wait for earlier results and preserve ordering across all batches', () async {
    final inputs = List.generate(101, (index) => 'paragraph $index');
    final firstStarted = Completer<void>();
    final secondStarted = Completer<void>();
    final firstRelease = Completer<void>();
    final secondRelease = Completer<void>();
    var active = 0;
    var maximumActive = 0;
    var calls = 0;
    final adapter = _Adapter((request) async {
      active++;
      if (active > maximumActive) maximumActive = active;
      calls++;
      if (calls == 1) {
        firstStarted.complete();
        await firstRelease.future;
      } else if (calls == 2) {
        secondStarted.complete();
        await secondRelease.future;
      }
      active--;
      return _translated(request.texts.map((text) => 'translated $text').toList());
    });
    addTearDown(() {
      if (!firstRelease.isCompleted) firstRelease.complete();
      if (!secondRelease.isCompleted) secondRelease.complete();
    });
    final result = batch(provider(adapter), inputs);
    await firstStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, hasLength(1));
    firstRelease.complete();
    await secondStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, hasLength(2));
    secondRelease.complete();
    expect(await result, inputs.map((text) => 'translated $text').toList());
    expect(adapter.requests.map((request) => request.texts.length), [50, 50, 1]);
    expect(maximumActive, 1);
  });

  test('a failed batch stops before issuing later batches', () async {
    var calls = 0;
    final adapter = _Adapter((request) {
      calls++;
      return calls == 1 ? _translated(request.texts) : _json({'error': 'unavailable'}, 503);
    });
    await expectLater(batch(provider(adapter), List.generate(101, (index) => 'paragraph $index')), throwsException);
    expect(adapter.requests, hasLength(2));
  });

  final invalidResponses = <String, Object?>{
    'null': null,
    'object': {'unexpected': true},
    'string': 'unexpected',
    'empty list': [],
    'null entry': [null],
    'missing translations': [{}],
    'null translations': [
      {'translations': null},
    ],
    'object translations': [
      {'translations': {}},
    ],
    'empty translations': [
      {'translations': []},
    ],
    'null translation': [
      {
        'translations': [null],
      },
    ],
    'missing text': [
      {
        'translations': [{}],
      },
    ],
    'null text': [
      {
        'translations': [
          {'text': null},
        ],
      },
    ],
    'non-string text': [
      {
        'translations': [
          {'text': 42},
        ],
      },
    ],
  };
  for (final entry in invalidResponses.entries) {
    test('rejects malformed response: ${entry.key}', () async {
      final adapter = _Adapter((_) => _json(entry.value));
      await expectLater(translate(provider(adapter)), throwsException);
      expect(adapter.requests, hasLength(1));
    });
  }

  for (final count in [1, 3]) {
    test('rejects $count results for a two-paragraph request', () async {
      final adapter = _Adapter((_) => _translated(List.generate(count, (index) => 'result $index')));
      await expectLater(batch(provider(adapter), ['first', 'second']), throwsException);
      expect(adapter.requests, hasLength(1));
    });
  }

  for (final status in [201, 204, 400, 401, 429, 503]) {
    test('a $status response reports one stream error without retrying', () async {
      final adapter = _Adapter((_) => _json({'error': 'unavailable'}, status));
      await expectLater(
        provider(adapter).translateStream('paragraph', LangListEnum.auto, LangListEnum.simplifiedChinese),
        emitsInOrder(['...', emitsError(isA<Exception>()), emitsDone]),
      );
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.options.uri.path, '/translate/translatetext');
    });
  }

  test('supports the existing text-only full-text translation entry point', () async {
    final adapter = _Adapter((_) => _translated());
    expect(
      await provider(adapter).translateTextOnly(
        'paragraph',
        LangListEnum.auto,
        LangListEnum.simplifiedChinese,
        isFullText: true,
      ),
      '译文',
    );
    expect(adapter.requests, hasLength(1));
    expect(adapter.requests.single.texts, ['paragraph']);
  });

  for (final status in [401, 503]) {
    test('text-only translation makes exactly three attempts for $status responses', () async {
      final adapter = _Adapter((_) => _json({'error': 'unavailable'}, status));
      await expectLater(
        provider(adapter).translateTextOnly('paragraph', LangListEnum.auto, LangListEnum.simplifiedChinese),
        throwsA(isA<Exception>().having((error) => error.toString(), 'message', contains('after 3 attempts'))),
      );
      expect(adapter.requests, hasLength(3));
      for (final request in adapter.requests) {
        expect(request.options.method, 'POST');
        expect(request.options.uri.path, '/translate/translatetext');
        expect(request.options.headers.keys.any((key) => key.toLowerCase() == 'authorization'), isFalse);
      }
    });
  }

  test('text-only translation preserves ordinary retries and backoff including a 401', () async {
    final calls = <int>[];
    final clock = Stopwatch()..start();
    final adapter = _Adapter((_) {
      calls.add(clock.elapsedMilliseconds);
      final statuses = [503, 401, 200];
      expect(calls.length, lessThanOrEqualTo(statuses.length));
      final status = statuses[calls.length - 1];
      return status == 200 ? _translated() : _json({'error': 'unavailable'}, status);
    });
    expect(
      await provider(adapter).translateTextOnly('paragraph', LangListEnum.auto, LangListEnum.simplifiedChinese),
      '译文',
    );
    expect(calls, hasLength(3));
    expect(calls[1] - calls[0], greaterThanOrEqualTo(90));
    expect(calls[2] - calls[1], greaterThanOrEqualTo(190));
  });

  test('text-only translation retries malformed results at most three times', () async {
    final adapter = _Adapter((_) => _json({'unexpected': true}));
    await expectLater(
      provider(adapter).translateTextOnly('paragraph', LangListEnum.auto, LangListEnum.simplifiedChinese),
      throwsA(isA<Exception>().having((error) => error.toString(), 'message', contains('after 3 attempts'))),
    );
    expect(adapter.requests, hasLength(3));
  });

  for (final invalidResult in ['', ' ', '...']) {
    test('text-only translation rejects empty or placeholder results: "$invalidResult"', () async {
      final adapter = _Adapter((_) => _translated([invalidResult]));
      await expectLater(
        provider(adapter).translateTextOnly('paragraph', LangListEnum.auto, LangListEnum.simplifiedChinese),
        throwsA(isA<Exception>().having((error) => error.toString(), 'message', contains('no valid result'))),
      );
      expect(adapter.requests, hasLength(3));
    });
  }

  testWidgets('uses the existing localized label and has no configuration', (tester) async {
    final value = provider(_Adapter((_) => throw StateError('No request expected')));
    await tester.runAsync(() => L10n.delegate.load(const Locale('en')));
    var checkedConfiguration = false;
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(builder: (context) {
        expect(value.getLabel(context), L10n.of(context).translateMicrosoftFree);
        expect(value.getConfigItems(context), isEmpty);
        checkedConfiguration = true;
        return const SizedBox.shrink();
      }),
    ));
    await tester.pumpAndSettle();
    expect(checkedConfiguration, isTrue);
    value.saveConfig({'api_key': 'unused'});
    expect(value.getConfig(), isEmpty);
  });

  group('translation preferences', () {
    test('defaults both translation services to microsoftFree', () async {
      SharedPreferences.setMockInitialValues({});
      await Prefs().initPrefs();
      expect(Prefs().translateService, TranslateService.microsoftFree);
      expect(Prefs().fullTextTranslateService, TranslateService.microsoftFree);
    });

    test('preserves every existing explicitly selected service', () async {
      for (final service in TranslateService.values) {
        SharedPreferences.setMockInitialValues({
          'translateService': service.name,
          'fullTextTranslateService': service.name,
        });
        await Prefs().initPrefs();
        expect(Prefs().translateService, service);
        expect(Prefs().fullTextTranslateService, service);
        expect(Prefs().prefs.getString('translateService'), service.name);
        expect(Prefs().prefs.getString('fullTextTranslateService'), service.name);
      }
    });

    test('retains the existing migration for the legacy microsoft selection', () async {
      SharedPreferences.setMockInitialValues({
        'translateService': 'microsoft',
        'fullTextTranslateService': 'microsoft',
      });
      await Prefs().initPrefs();
      expect(Prefs().translateService, TranslateService.microsoftApi);
      expect(Prefs().fullTextTranslateService, TranslateService.microsoftApi);
      expect(Prefs().prefs.getString('fullTextTranslateService'), 'microsoftApi');
    });
  });
}
