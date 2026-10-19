import 'package:anx_reader/service/wifi_transfer/upload_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;

void main() {
  test('upload page has the specified language, text and file selection', () {
    final page = html.parse(uploadPageHtml);
    expect(page.documentElement!.attributes['lang'], 'zh-CN');
    expect(page.querySelector('title')!.text, '物语 · 传书');
    expect(page.querySelector('meta[name="viewport"]')!.attributes['content'], 'width=device-width, initial-scale=1');
    expect(page.querySelector('h1')!.text, '物语 传书');
    expect(page.querySelector('.subtitle')!.text, '支持 EPUB · MOBI · AZW3 · FB2 · TXT · PDF');
    expect(page.querySelector('.prompt')!.text, '拖拽书籍到这里');
    expect(page.querySelector('.hint')!.text, '或点击选择文件');
    expect(page.querySelector('footer')!.text, '请保持 物语 打开并停留在传书页面');
    final input = page.querySelector('input[type="file"]')!;
    expect(input.attributes.containsKey('multiple'), isTrue);
    expect(input.attributes.containsKey('hidden'), isTrue);
    expect(input.attributes['accept'], '.epub,.mobi,.azw3,.fb2,.txt,.pdf');
    expect(page.querySelector('#drop-zone svg'), isNotNull);
  });

  test('upload page contains only inline resources', () {
    final page = html.parse(uploadPageHtml);
    expect(page.querySelectorAll('script[src], link[href], img[src], iframe, object, embed'), isEmpty);
    expect(page.querySelectorAll('script'), hasLength(1));
    expect(page.querySelectorAll('style'), hasLength(1));
    expect(page.querySelector('style')!.text, isNot(contains('url(')));
    expect(page.querySelector('style')!.text, isNot(contains('@import')));
  });
}
