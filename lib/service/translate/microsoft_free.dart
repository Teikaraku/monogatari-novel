import 'dart:convert';

import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

const _translateUrl = 'https://edge.microsoft.com/translate/translatetext';
const _maxBatchTexts = 50;
const _maxBatchCharacters = 50000;

class MicrosoftFreeTranslateProvider extends TranslateServiceProvider {
  MicrosoftFreeTranslateProvider({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  @override
  TranslateService get service => TranslateService.microsoftFree;

  @override
  String getLabel(BuildContext context) => L10n.of(context).translateMicrosoftFree;

  String? _languageCode(LangListEnum lang) {
    switch (lang) {
      case LangListEnum.auto:
      case LangListEnum.crimeanTatarLatin:
      case LangListEnum.crimeanTatarCyrillic:
        return null;
      case LangListEnum.simplifiedChinese:
        return 'zh-Hans';
      case LangListEnum.traditionalChinese:
        return 'zh-Hant';
      default:
        return lang.code;
    }
  }

  @override
  String mapLanguageCode(LangListEnum lang) => _languageCode(lang) ?? 'en';

  @override
  Widget translate(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) {
    return convertStreamToWidget(
      translateStream(text, from, to, contextText: contextText, isFullText: isFullText),
    );
  }

  @override
  Stream<String> translateStream(
    String text,
    LangListEnum from,
    LangListEnum to, {
    String? contextText,
    bool isFullText = false,
  }) async* {
    try {
      yield '...';
      final results = await _requestBatch([text], from, to);
      yield results.single;
    } catch (e) {
      AnxLog.severe('Translate Microsoft Free Error: error=$e');
      yield* Stream.error(Exception(e));
    }
  }

  Future<List<String>> translateBatch(List<String> texts, LangListEnum from, LangListEnum to) async {
    if (texts.isEmpty) return [];
    final results = List.generate(texts.length, (_) => StringBuffer());
    final batch = <String>[];
    final owners = <int>[];
    var characters = 0;

    Future<void> flush() async {
      if (batch.isEmpty) return;
      final translated = await _requestBatch(batch, from, to);
      for (var i = 0; i < translated.length; i++) {
        results[owners[i]].write(translated[i]);
      }
      batch.clear();
      owners.clear();
      characters = 0;
    }

    for (var i = 0; i < texts.length; i++) {
      for (final chunk in _splitText(texts[i])) {
        final count = chunk.runes.length;
        if (batch.length == _maxBatchTexts || characters + count > _maxBatchCharacters) {
          await flush();
        }
        batch.add(chunk);
        owners.add(i);
        characters += count;
      }
    }
    await flush();
    return results.map((result) => result.toString()).toList();
  }

  Iterable<String> _splitText(String text) sync* {
    if (text.isEmpty) {
      yield '';
      return;
    }
    var chunk = StringBuffer();
    var characters = 0;
    for (final rune in text.runes) {
      chunk.writeCharCode(rune);
      characters++;
      if (characters == _maxBatchCharacters) {
        yield chunk.toString();
        chunk = StringBuffer();
        characters = 0;
      }
    }
    if (characters > 0) yield chunk.toString();
  }

  Future<List<String>> _requestBatch(List<String> texts, LangListEnum from, LangListEnum to) async {
    final source = _languageCode(from);
    final options = Options(
      method: 'POST',
      headers: {Headers.contentTypeHeader: Headers.jsonContentType},
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
    ).compose(
      _dio.options.copyWith(headers: {}, queryParameters: {}),
      _translateUrl,
      data: List<String>.of(texts),
      queryParameters: {
        'api-version': '3.0',
        'isEnterpriseClient': 'false',
        'to': mapLanguageCode(to),
        if (source != null) 'from': source,
      },
    );
    final response = await _dio.fetch<dynamic>(options);
    final body = response.data;
    if (response.statusCode != 200 || body is! String) {
      throw Exception('Microsoft API Error: ${response.data}');
    }
    final dynamic data;
    try {
      data = jsonDecode(body);
    } on FormatException {
      throw Exception('Microsoft API Error: ${response.data}');
    }
    if (data is! List || data.length != texts.length) {
      throw Exception('Microsoft API Error: ${response.data}');
    }
    final results = <String>[];
    for (final item in data) {
      final translations = item is Map ? item['translations'] : null;
      if (translations is! List || translations.isEmpty) {
        throw Exception('Microsoft API response invalid');
      }
      final translation = translations.first;
      final text = translation is Map ? translation['text'] : null;
      if (text is! String) throw Exception('Microsoft API response invalid');
      results.add(text);
    }
    return results;
  }
}
