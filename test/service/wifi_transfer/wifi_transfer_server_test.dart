import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:anx_reader/service/wifi_transfer/wifi_transfer_server.dart';
import 'package:flutter_test/flutter_test.dart';

const _boundary = 'monogatari-test-boundary';

class _Reply {
  const _Reply(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final String body;

  Map<String, dynamic> get json => jsonDecode(body) as Map<String, dynamic>;
}

Future<_Reply> _readReply(HttpClientResponse response) async {
  return _Reply(response.statusCode, response.headers, await utf8.decoder.bind(response).join());
}

String _multipartPrefix(String fileName, {String? disposition}) {
  return '--$_boundary\r\n'
      'Content-Disposition: ${disposition ?? 'form-data; name="file"; filename="$fileName"'}\r\n'
      'Content-Type: application/octet-stream\r\n\r\n';
}

Future<_Reply> _upload(
  HttpClient client,
  Uri base,
  String fileName,
  List<int> bytes, {
  String? disposition,
  bool chunked = false,
}) async {
  final body = [
    ...utf8.encode(_multipartPrefix(fileName, disposition: disposition)),
    ...bytes,
    ...utf8.encode('\r\n--$_boundary--\r\n'),
  ];
  final request = await client.postUrl(base.resolve('upload'));
  request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$_boundary');
  if (!chunked) request.contentLength = body.length;
  request.add(body);
  return _readReply(await request.close());
}

Future<void> _waitFor(bool Function() predicate) async {
  final timer = Stopwatch()..start();
  while (!predicate()) {
    if (timer.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('Expected server state was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<Socket> _beginUpload(Uri base, String name) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4, base.port);
  socket.write('POST ${base.resolve('upload').path} HTTP/1.1\r\n'
      'Host: 127.0.0.1:${base.port}\r\n'
      'Content-Type: multipart/form-data; boundary=$_boundary\r\n'
      'Content-Length: 100000\r\n\r\n'
      '${_multipartPrefix(name)}partial file bytes');
  await socket.flush();
  return socket;
}

void main() {
  group('transfer file names', () {
    test('removes POSIX and Windows traversal prefixes', () {
      expect(sanitizeTransferFileName('../../book.epub'), 'book.epub');
      expect(sanitizeTransferFileName(r'..\..\book.epub'), 'book.epub');
      expect(sanitizeTransferFileName(r'C:\Users\reader\book.epub'), 'book.epub');
      expect(sanitizeTransferFileName(r'../nested\book.epub'), 'book.epub');
    });

    test('removes forbidden and control characters and trims whitespace', () {
      expect(sanitizeTransferFileName('  b<>:"|?*\u0000\u001f\u007fook.epub  '), 'book.epub');
      expect(sanitizeTransferFileName('  中文小说.epub  '), '中文小说.epub');
    });

    test('uses book for an empty cleaned name', () {
      expect(sanitizeTransferFileName(''), 'book');
      expect(sanitizeTransferFileName(' \t<>:"|?*\r\n '), 'book');
    });

    test('truncates the stem to 120 characters and preserves the extension', () {
      final stem = List.filled(150, '书').join();
      final cleaned = sanitizeTransferFileName('$stem.epub');
      expect(cleaned.length, 120);
      expect(cleaned, '${List.filled(115, '书').join()}.epub');
      expect(sanitizeTransferFileName(List.filled(121, 'a').join()).length, 120);
    });

    test('decodes RFC 5987 UTF-8 names and prefers them over filename', () {
      final encoded = Uri.encodeComponent('中文小说.epub');
      expect(
        transferFileNameFromDisposition('form-data; name="file"; filename*=UTF-8\'\'$encoded'),
        '中文小说.epub',
      );
      expect(
        transferFileNameFromDisposition('form-data; filename="fallback.epub"; filename*=UTF-8\'\'$encoded'),
        '中文小说.epub',
      );
      expect(transferFileNameFromDisposition('form-data; name="file"; filename="plain.epub"'), 'plain.epub');
      expect(transferFileNameFromDisposition('form-data; name="file"'), isNull);
    });

    test('increments collisions without losing the extension', () {
      final existing = {'book.epub', 'book (2).epub', 'book (3).epub'};
      expect(uniqueTransferFileName('book.epub', existing.contains), 'book (4).epub');
      expect(uniqueTransferFileName('other.epub', existing.contains), 'other.epub');
      expect(uniqueTransferFileName('book', {'book', 'book (2)'}.contains), 'book (3)');
    });
  });

  group('transfer addresses', () {
    test('filters link-local addresses and orders interface preference before private range', () {
      const addresses = [
        WifiTransferAddress(interfaceName: 'vpn', address: '8.8.8.8'),
        WifiTransferAddress(interfaceName: 'wifi0', address: '169.254.1.2'),
        WifiTransferAddress(interfaceName: 'vpn', address: '192.168.1.2'),
        WifiTransferAddress(interfaceName: 'wlan0', address: '8.8.4.4'),
        WifiTransferAddress(interfaceName: 'wlan0', address: '192.168.1.3'),
      ];
      expect(
        sortTransferAddresses(addresses).map((item) => item.address),
        ['192.168.1.3', '8.8.4.4', '192.168.1.2', '8.8.8.8'],
      );
      expect(addresses.length, 5);
    });

    for (final name in ['wlan0', 'wifi0', 'en0', 'eth0', 'ap0']) {
      test('recognizes preferred interface $name', () {
        final sorted = sortTransferAddresses([
          const WifiTransferAddress(interfaceName: 'vpn', address: '192.168.1.2'),
          WifiTransferAddress(interfaceName: name, address: '192.168.1.3'),
        ]);
        expect(sorted.first.interfaceName, name);
      });
    }

    for (final address in ['10.0.0.1', '10.255.255.254', '172.16.0.1', '172.31.255.254', '192.168.0.1']) {
      test('recognizes private IPv4 range $address', () {
        final sorted = sortTransferAddresses([
          const WifiTransferAddress(interfaceName: 'vpn', address: '172.15.255.254'),
          const WifiTransferAddress(interfaceName: 'vpn', address: '172.32.0.1'),
          WifiTransferAddress(interfaceName: 'vpn', address: address),
        ]);
        expect(sorted.first.address, address);
      });
    }
  });

  group('transfer HTTP server', () {
    late Directory directory;
    late WifiTransferServer server;
    late HttpClient client;
    late Uri base;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('wifi-transfer-test-');
      server = WifiTransferServer(
        maxFileBytes: 64,
        tempDirectory: () async => directory,
        addresses: () async => [const WifiTransferAddress(interfaceName: 'wlan0', address: '192.168.1.5')],
      );
      client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      await server.start();
      expect(server.state.value.status, WifiTransferStatus.running);
      base = Uri.parse(server.state.value.urls.single).replace(host: '127.0.0.1');
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await directory.delete(recursive: true);
    });

    test('requires a token and serves only the specified GET route', () async {
      expect(base.path, matches(RegExp(r'^/[a-z0-9]{6}/$')));
      for (final path in ['/', '/wrong/', '/upload', '${base.path}missing']) {
        final request = await client.getUrl(base.replace(path: path));
        final reply = await _readReply(await request.close());
        expect(reply.status, HttpStatus.notFound, reason: path);
        expect(reply.body, isNot(contains('<html')));
      }
      final request = await client.getUrl(base);
      final reply = await _readReply(await request.close());
      expect(reply.status, HttpStatus.ok);
      expect(reply.headers.contentType?.mimeType, 'text/html');
      expect(reply.headers.contentType?.charset, 'utf-8');
      expect(reply.headers.value(HttpHeaders.cacheControlHeader), 'no-store');
      expect(reply.body, contains('<html lang="zh-CN">'));
      expect(reply.body, contains('物语 · 传书'));
      expect(server.state.value.urls.single, startsWith('http://192.168.1.5:'));
    });

    test('uploads binary content once to each broadcast subscriber', () async {
      expect(server.received.isBroadcast, isTrue);
      final firstFiles = <File>[];
      final secondFiles = <File>[];
      final first = server.received.listen(firstFiles.add);
      final second = server.received.listen(secondFiles.add);
      addTearDown(first.cancel);
      addTearDown(second.cancel);
      final bytes = [0, 255, 128, 80, 75, 3, 4, 13, 10];
      final reply = await _upload(client, base, 'book.epub', bytes);
      expect(reply.status, HttpStatus.ok);
      expect(reply.json, {'ok': true, 'name': 'book.epub'});
      expect(reply.headers.contentType?.mimeType, 'application/json');
      expect(reply.headers.contentType?.charset, 'utf-8');
      await _waitFor(() => firstFiles.length == 1 && secondFiles.length == 1);
      expect(firstFiles.single.path, secondFiles.single.path);
      expect(await firstFiles.single.readAsBytes(), bytes);
      final upload = server.state.value.uploads.single;
      expect(upload.id, isNotEmpty);
      expect(upload.fileName, 'book.epub');
      expect(upload.receivedBytes, bytes.length);
      expect(upload.done, isTrue);
      expect(upload.error, isNull);
      expect(upload.file?.path, firstFiles.single.path);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(firstFiles, hasLength(1));
      expect(secondFiles, hasLength(1));
    });

    final extensions = ['epub', 'mobi', 'azw3', 'fb2', 'txt', 'pdf', 'EPUB', 'MOBI', 'AZW3', 'FB2', 'TXT', 'PDF'];
    for (final extension in extensions) {
      test('accepts extension $extension', () async {
        final reply = await _upload(client, base, 'book.$extension', [1, 2, 3]);
        expect(reply.status, HttpStatus.ok);
        expect(reply.json['ok'], isTrue);
        expect(await server.state.value.uploads.single.file!.readAsBytes(), [1, 2, 3]);
      });
    }

    for (final fileName in ['book.exe', 'book.epub.exe', 'book']) {
      test('rejects unsupported filename $fileName without creating a file', () async {
        final reply = await _upload(client, base, fileName, [1, 2, 3]);
        expect(reply.status, HttpStatus.unsupportedMediaType);
        expect(reply.json, {'ok': false, 'error': 'unsupported'});
        expect(directory.listSync(), isEmpty);
      });
    }

    test('accepts the exact file size limit and rejects one extra byte', () async {
      final accepted = await _upload(client, base, 'limit.epub', List.filled(64, 7));
      expect(accepted.status, HttpStatus.ok);
      final rejected = await _upload(client, base, 'oversize.epub', List.filled(65, 7));
      expect(rejected.status, HttpStatus.requestEntityTooLarge);
      expect(rejected.json, {'ok': false, 'error': 'too_large'});
      expect(directory.listSync().map((file) => file.uri.pathSegments.last), ['limit.epub']);
      final upload = server.state.value.uploads.first;
      expect(upload.error, 'too_large');
      expect(upload.file, isNull);
    });

    test('enforces the file limit for chunked requests without Content-Length', () async {
      final reply = await _upload(client, base, 'oversize.epub', List.filled(65, 8), chunked: true);
      expect(reply.status, HttpStatus.requestEntityTooLarge);
      expect(reply.json, {'ok': false, 'error': 'too_large'});
      expect(directory.listSync(), isEmpty);
    });

    test('accepts chunked uploads and reports an unknown total as zero', () async {
      final reply = await _upload(client, base, 'chunked.epub', [1, 2, 3], chunked: true);
      expect(reply.status, HttpStatus.ok);
      final upload = server.state.value.uploads.single;
      expect(upload.totalBytes, 0);
      expect(upload.receivedBytes, 3);
    });

    test('handles RFC 5987 names and never writes outside the temporary directory', () async {
      final name = Uri.encodeComponent('../../中文小说.epub');
      final reply = await _upload(
        client,
        base,
        'fallback.exe',
        [1, 2, 3],
        disposition: 'form-data; name="file"; filename="fallback.exe"; filename*=UTF-8\'\'$name',
      );
      expect(reply.status, HttpStatus.ok);
      expect(reply.json, {'ok': true, 'name': '中文小说.epub'});
      final file = server.state.value.uploads.single.file!;
      expect(file.parent.path, directory.path);
      expect(await file.readAsBytes(), [1, 2, 3]);
    });

    test('preserves existing files while incrementing duplicate names', () async {
      await File('${directory.path}${Platform.pathSeparator}book.epub').writeAsBytes([9]);
      for (var index = 2; index <= 3; index++) {
        final reply = await _upload(client, base, 'book.epub', [index]);
        expect(reply.json, {'ok': true, 'name': 'book ($index).epub'});
      }
      expect(await File('${directory.path}${Platform.pathSeparator}book.epub').readAsBytes(), [9]);
      expect(server.state.value.uploads.map((upload) => upload.fileName), ['book (3).epub', 'book (2).epub']);
      expect(server.state.value.uploads.map((upload) => upload.id).toSet(), hasLength(2));
    });

    test('concurrent equal filenames reserve distinct files without overwriting data', () async {
      final replies = await Future.wait([
        for (var index = 1; index <= 4; index++) _upload(client, base, 'same.epub', [index, index, index]),
      ]);
      expect(replies.map((reply) => reply.status), everyElement(HttpStatus.ok));
      expect(
        replies.map((reply) => reply.json['name']).toSet(),
        {'same.epub', 'same (2).epub', 'same (3).epub', 'same (4).epub'},
      );
      for (var index = 0; index < replies.length; index++) {
        final name = replies[index].json['name'] as String;
        expect(
          await File('${directory.path}${Platform.pathSeparator}$name').readAsBytes(),
          List.filled(3, index + 1),
        );
      }
      expect(directory.listSync(), hasLength(4));
    });

    test('malformed multipart headers return an error without escaping the server zone', () async {
      final body = utf8.encode('--$_boundary\r\nInvalid Header: value\r\n\r\nbytes\r\n--$_boundary--\r\n');
      final request = await client.postUrl(base.resolve('upload'));
      request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$_boundary');
      request.contentLength = body.length;
      request.add(body);
      final reply = await _readReply(await request.close());
      expect(reply.status, inInclusiveRange(400, 499));
      expect(reply.json['ok'], isFalse);
      expect(reply.json['error'], isNotEmpty);
      expect(directory.listSync(), isEmpty);
      expect(server.state.value.status, WifiTransferStatus.running);
      expect((await _upload(client, base, 'after-malformed.epub', [7])).status, HttpStatus.ok);
    });

    test('a complete HTTP request with an incomplete multipart body does not hang', () async {
      final body = utf8.encode('${_multipartPrefix('incomplete.epub')}incomplete');
      final request = await client.postUrl(base.resolve('upload'));
      request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$_boundary');
      request.contentLength = body.length;
      request.add(body);
      final reply = await _readReply(await request.close());
      expect(reply.status, inInclusiveRange(400, 499));
      expect(reply.json['ok'], isFalse);
      expect(reply.json['error'], isNotEmpty);
      expect(directory.listSync(), isEmpty);
      expect((await _upload(client, base, 'after-incomplete.epub', [7])).status, HttpStatus.ok);
    });

    test('throttles streaming progress to 150 ms and publishes completion immediately', () async {
      final clock = Stopwatch()..start();
      final progress = <({int bytes, int microseconds})>[];
      int? completedAt;
      void record() {
        if (server.state.value.uploads.isEmpty) return;
        final upload = server.state.value.uploads.single;
        if (upload.done) {
          completedAt ??= clock.elapsedMicroseconds;
        } else if (upload.receivedBytes > 0 && (progress.isEmpty || progress.last.bytes != upload.receivedBytes)) {
          progress.add((bytes: upload.receivedBytes, microseconds: clock.elapsedMicroseconds));
        }
      }

      server.state.addListener(record);
      addTearDown(() => server.state.removeListener(record));
      final request = await client.postUrl(base.resolve('upload'));
      request.bufferOutput = false;
      request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$_boundary');
      request.add(utf8.encode(_multipartPrefix('progress.epub')));
      await request.flush();
      var sentBytes = 0;
      while (progress.length < 3 && sentBytes < 60) {
        request.add([7, 8]);
        sentBytes += 2;
        await request.flush();
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(progress.length, greaterThanOrEqualTo(3));
      request.add(utf8.encode('\r\n--$_boundary--\r\n'));
      final reply = await _readReply(await request.close());
      expect(reply.status, HttpStatus.ok);
      for (var index = 1; index < progress.length; index++) {
        expect(progress[index].bytes, greaterThan(progress[index - 1].bytes));
        expect(progress[index].microseconds - progress[index - 1].microseconds, greaterThanOrEqualTo(149000));
      }
      expect(completedAt, isNotNull);
      expect(completedAt! - progress.last.microseconds, lessThan(149000));
      final upload = server.state.value.uploads.single;
      expect(upload.done, isTrue);
      expect(upload.error, isNull);
      expect(upload.receivedBytes, sentBytes);
      expect(await upload.file!.length(), sentBytes);
    });

    test('slow temporary directory lookup applies backpressure before buffering the entire upload', () async {
      await server.stop();
      final directoryRequested = Completer<void>();
      final releaseDirectory = Completer<void>();
      const chunkSize = 64 * 1024;
      const chunkCount = 1024;
      server = WifiTransferServer(
        maxFileBytes: chunkSize * chunkCount,
        tempDirectory: () async {
          directoryRequested.complete();
          await releaseDirectory.future;
          return directory;
        },
        addresses: () async => [const WifiTransferAddress(interfaceName: 'wlan0', address: '192.168.1.5')],
      );
      addTearDown(() {
        if (!releaseDirectory.isCompleted) releaseDirectory.complete();
      });
      await server.start();
      base = Uri.parse(server.state.value.urls.single).replace(host: '127.0.0.1');
      final request = await client.postUrl(base.resolve('upload'));
      request.bufferOutput = false;
      request.headers.set(HttpHeaders.contentTypeHeader, 'multipart/form-data; boundary=$_boundary');
      final chunk = List.filled(chunkSize, 7);
      var flushedChunks = 0;
      var bodyFlushed = false;
      Object? sendError;
      Future<_Reply> send() async {
        request.add(utf8.encode(_multipartPrefix('backpressure.epub')));
        for (var index = 0; index < chunkCount; index++) {
          request.add(chunk);
          await request.flush();
          flushedChunks++;
        }
        bodyFlushed = true;
        request.add(utf8.encode('\r\n--$_boundary--\r\n'));
        return _readReply(await request.close());
      }

      final replyFuture = send();
      unawaited(replyFuture.then<void>((_) {}, onError: (Object error, StackTrace stack) {
        sendError = error;
      }));
      try {
        await directoryRequested.future.timeout(const Duration(seconds: 5));
        final clock = Stopwatch()..start();
        var previousChunks = flushedChunks;
        var lastChange = clock.elapsedMilliseconds;
        while (!bodyFlushed && sendError == null && clock.elapsedMilliseconds < 5000) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (flushedChunks != previousChunks) {
            previousChunks = flushedChunks;
            lastChange = clock.elapsedMilliseconds;
          } else if (clock.elapsedMilliseconds - lastChange >= 300) {
            break;
          }
        }
        expect(sendError, isNull);
        expect(bodyFlushed, isFalse);
        expect(flushedChunks, inExclusiveRange(0, chunkCount));
        expect(clock.elapsedMilliseconds - lastChange, greaterThanOrEqualTo(300));
        expect(directory.listSync(), isEmpty);
      } finally {
        releaseDirectory.complete();
      }
      final reply = await replyFuture;
      expect(reply.status, HttpStatus.ok);
      final upload = server.state.value.uploads.single;
      expect(upload.receivedBytes, chunkSize * chunkCount);
      expect(await upload.file!.length(), chunkSize * chunkCount);
      await for (final bytes in upload.file!.openRead()) {
        expect(bytes.any((byte) => byte != 7), isFalse);
      }
    });

    test('rejects a fifth concurrent upload and cleans aborted files', () async {
      final sockets = <Socket>[];
      addTearDown(() {
        for (final socket in sockets) {
          socket.destroy();
        }
      });
      for (var index = 0; index < 4; index++) {
        sockets.add(await _beginUpload(base, 'pending-$index.epub'));
      }
      await _waitFor(() => server.state.value.uploads.length == 4);
      final reply = await _upload(client, base, 'fifth.epub', [1]);
      expect(reply.status, HttpStatus.tooManyRequests);
      expect(reply.json, {'ok': false, 'error': 'busy'});
      for (final socket in sockets) {
        socket.destroy();
      }
      await _waitFor(() => server.state.value.uploads.every((upload) => upload.error != null));
      await _waitFor(() => directory.listSync().isEmpty);
      final recovered = await _upload(client, base, 'recovered.epub', [1]);
      expect(recovered.status, HttpStatus.ok);
    });

    test('removes an incomplete upload when the client disconnects', () async {
      final socket = await _beginUpload(base, 'disconnected.epub');
      addTearDown(socket.destroy);
      await _waitFor(() => server.state.value.uploads.isNotEmpty && directory.listSync().isNotEmpty);
      socket.destroy();
      await _waitFor(() => server.state.value.uploads.single.error != null && directory.listSync().isEmpty);
      expect(server.state.value.uploads.single.file, isNull);
    });

    test('stop closes the port and cleans pending files while preserving completed files', () async {
      expect((await _upload(client, base, 'completed.epub', [1, 2, 3])).status, HttpStatus.ok);
      final completed = server.state.value.uploads.single.file!;
      final socket = await _beginUpload(base, 'pending.epub');
      addTearDown(socket.destroy);
      await _waitFor(() => server.state.value.uploads.length == 2 && directory.listSync().length == 2);
      await server.stop();
      expect(server.state.value.status, WifiTransferStatus.stopped);
      expect(server.state.value.urls, isEmpty);
      expect(await completed.readAsBytes(), [1, 2, 3]);
      expect(directory.listSync(), hasLength(1));
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, base.port, timeout: const Duration(seconds: 1)),
        throwsA(isA<SocketException>()),
      );
      await server.stop();
    });

    test('start is idempotent while running and can restart after stop', () async {
      final original = server.state.value.urls.single;
      await server.start();
      expect(server.state.value.urls.single, original);
      await server.stop();
      await server.start();
      expect(server.state.value.status, WifiTransferStatus.running);
      final restarted = Uri.parse(server.state.value.urls.single).replace(host: '127.0.0.1');
      expect(restarted.path, matches(RegExp(r'^/[a-z0-9]{6}/$')));
      expect((await _upload(client, restarted, 'restarted.epub', [1])).status, HttpStatus.ok);
    });

    test('stop immediately after start cancels the pending startup', () async {
      await server.stop();
      final statuses = <WifiTransferStatus>[];
      void record() => statuses.add(server.state.value.status);
      server.state.addListener(record);
      addTearDown(() => server.state.removeListener(record));
      final starting = server.start();
      await server.stop();
      await starting;
      expect(server.state.value.status, WifiTransferStatus.stopped);
      expect(server.state.value.urls, isEmpty);
      expect(statuses, isNot(contains(WifiTransferStatus.running)));
      await expectLater(
        Socket.connect(InternetAddress.loopbackIPv4, base.port, timeout: const Duration(seconds: 1)),
        throwsA(isA<SocketException>()),
      );
    });

    test('retains only the latest 200 upload records', () async {
      for (var index = 0; index < 201; index++) {
        final reply = await _upload(client, base, 'book-$index.epub', [index % 256]);
        expect(reply.status, HttpStatus.ok);
      }
      final uploads = server.state.value.uploads;
      expect(uploads, hasLength(200));
      expect(uploads.first.fileName, 'book-200.epub');
      expect(uploads.last.fileName, 'book-1.epub');
      expect(uploads.every((upload) => upload.done && upload.error == null), isTrue);
    });
  });

  test('the default file limit is exactly 500 MiB', () {
    expect(WifiTransferServer().maxFileBytes, 500 * 1024 * 1024);
  });

  test('startup failures are reported through state instead of throwing', () async {
    final server = WifiTransferServer(
      addresses: () async => throw const SocketException('addresses unavailable'),
    );
    addTearDown(server.stop);
    await server.start();
    expect(server.state.value.status, WifiTransferStatus.failed);
    expect(server.state.value.error, isNotEmpty);
    expect(server.state.value.urls, isEmpty);
  });

  test('uses a system allocated port when 8866 through 8875 are occupied', () async {
    final reservations = <ServerSocket>[];
    final directory = await Directory.systemTemp.createTemp('wifi-transfer-ports-');
    final server = WifiTransferServer(
      tempDirectory: () async => directory,
      addresses: () async => [const WifiTransferAddress(interfaceName: 'wlan0', address: '192.168.1.5')],
    );
    addTearDown(() async {
      await server.stop();
      for (final reservation in reservations) {
        await reservation.close();
      }
      await directory.delete(recursive: true);
    });
    for (var port = 8866; port <= 8875; port++) {
      try {
        reservations.add(await ServerSocket.bind(InternetAddress.anyIPv4, port));
      } on SocketException {
        // An occupied port already exercises the fallback path.
      }
    }
    await server.start();
    expect(server.state.value.status, WifiTransferStatus.running);
    expect(Uri.parse(server.state.value.urls.single).port, isNot(inInclusiveRange(8866, 8875)));
  });
}
