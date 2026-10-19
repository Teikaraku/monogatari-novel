import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:anx_reader/service/wifi_transfer/upload_page.dart';
import 'package:anx_reader/utils/get_path/get_temp_dir.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as path;

enum WifiTransferStatus { stopped, starting, running, failed }

class WifiTransferUpload {
  final String id;
  final String fileName;
  final int totalBytes;
  final int receivedBytes;
  final bool done;
  final String? error;
  final File? file;

  const WifiTransferUpload({
    required this.id,
    required this.fileName,
    required this.totalBytes,
    required this.receivedBytes,
    required this.done,
    this.error,
    this.file,
  });
}

class WifiTransferState {
  final WifiTransferStatus status;
  final List<String> urls;
  final List<WifiTransferUpload> uploads;
  final String? error;

  WifiTransferState(
      {required this.status, List<String> urls = const [], List<WifiTransferUpload> uploads = const [], this.error})
      : urls = List.unmodifiable(urls),
        uploads = List.unmodifiable(uploads);
}

class WifiTransferAddress {
  final String interfaceName;
  final String address;

  const WifiTransferAddress({required this.interfaceName, required this.address});
}

List<WifiTransferAddress> sortTransferAddresses(Iterable<WifiTransferAddress> addresses) {
  bool preferred(WifiTransferAddress value) =>
      RegExp(r'wlan|wifi|en0|eth|ap', caseSensitive: false).hasMatch(value.interfaceName);
  bool private(WifiTransferAddress value) {
    final octets = value.address.split('.').map(int.tryParse).toList();
    if (octets.length != 4) return false;
    return octets[0] == 10 ||
        (octets[0] == 172 && octets[1] != null && octets[1]! >= 16 && octets[1]! <= 31) ||
        (octets[0] == 192 && octets[1] == 168);
  }

  final result = addresses.where((value) => !value.address.startsWith('169.254.')).toList();
  final order = {for (var i = 0; i < result.length; i++) result[i]: i};
  result.sort((a, b) {
    final interfaceOrder = (preferred(a) ? 0 : 1).compareTo(preferred(b) ? 0 : 1);
    if (interfaceOrder != 0) return interfaceOrder;
    final privateOrder = (private(a) ? 0 : 1).compareTo(private(b) ? 0 : 1);
    return privateOrder != 0 ? privateOrder : order[a]!.compareTo(order[b]!);
  });
  return result;
}

String _limitFileName(String name, [String suffix = '']) {
  final extension = path.posix.extension(name);
  final stem = name.substring(0, name.length - extension.length);
  final available = max(0, 120 - extension.runes.length - suffix.runes.length);
  return '${String.fromCharCodes(stem.runes.take(available))}$suffix$extension';
}

String sanitizeTransferFileName(String rawName) {
  var name = rawName.replaceAll('\\', '/').split('/').last;
  name = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f-\x9f]'), '').trim();
  return _limitFileName(name.isEmpty ? 'book' : name);
}

String uniqueTransferFileName(String rawName, bool Function(String name) exists) {
  final name = sanitizeTransferFileName(rawName);
  var candidate = name;
  for (var number = 2; exists(candidate); number++) {
    candidate = _limitFileName(name, ' ($number)');
  }
  return candidate;
}

Map<String, String> _dispositionParameters(String value) {
  final pattern = RegExp(r'(?:^|;)\s*([\w*.-]+)\s*=\s*(?:"((?:\\.|[^"])*)"|([^;]*))');
  return {
    for (final match in pattern.allMatches(value))
      match[1]!.toLowerCase(): (match[2] ?? match[3]!.trim()).replaceAll(r'\"', '"'),
  };
}

String? transferFileNameFromDisposition(String value) {
  final parameters = _dispositionParameters(value);
  final extended = parameters['filename*'];
  if (extended != null) {
    final match = RegExp(r"^UTF-8'[^']*'(.*)$", caseSensitive: false).firstMatch(extended);
    if (match != null) {
      try {
        return Uri.decodeComponent(match[1]!);
      } on FormatException {
        // Fall back to the ordinary filename when extended syntax is invalid.
      }
    }
  }
  final name = parameters['filename'];
  if (name == null) return null;
  try {
    return utf8.decode(latin1.encode(name));
  } on FormatException {
    return name;
  } on ArgumentError {
    return name;
  }
}

class _UploadFailure implements Exception {
  final int status;
  final String error;

  const _UploadFailure(this.status, this.error);
}

class _Upload {
  final String id;
  final int totalBytes;
  final completed = Completer<void>();
  String fileName = '';
  int receivedBytes = 0;
  bool done = false;
  bool cancelled = false;
  bool inputFailed = false;
  String? error;
  File? temporary;
  File? file;
  final firstPart = Completer<MimeMultipart?>();
  final bodyDone = Completer<void>();
  StreamSubscription<MimeMultipart>? parts;
  StreamIterator<List<int>>? data;

  _Upload(this.id, this.totalBytes);

  WifiTransferUpload snapshot() => WifiTransferUpload(
        id: id,
        fileName: fileName,
        totalBytes: totalBytes,
        receivedBytes: receivedBytes,
        done: done,
        error: error,
        file: file,
      );

  Future<void> cancelStreams() async {
    if (!firstPart.isCompleted) firstPart.complete(null);
    if (!bodyDone.isCompleted) bodyDone.complete();
    try {
      await data?.cancel();
    } catch (_) {}
    try {
      await parts?.cancel();
    } catch (_) {}
  }
}

class WifiTransferServer {
  static final WifiTransferServer instance = WifiTransferServer();
  static const _extensions = {'epub', 'mobi', 'azw3', 'fb2', 'txt', 'pdf'};
  final int maxFileBytes;
  final Future<Directory> Function() _tempDirectory;
  final Future<List<WifiTransferAddress>> Function() _addresses;
  final _state = ValueNotifier(WifiTransferState(status: WifiTransferStatus.stopped));
  final _received = StreamController<File>.broadcast();
  final _active = <_Upload>{};
  final _history = <_Upload>[];
  final _reserved = <String>{};
  final _clock = Stopwatch()..start();
  HttpServer? _server;
  Future<void>? _starting;
  Future<void>? _stopping;
  Timer? _progressTimer;
  int _lastProgress = 0;
  int _generation = 0;
  String _token = '';

  WifiTransferServer({
    this.maxFileBytes = 500 * 1024 * 1024,
    Future<Directory> Function()? tempDirectory,
    Future<List<WifiTransferAddress>> Function()? addresses,
  })  : assert(maxFileBytes >= 0),
        _tempDirectory = tempDirectory ?? getAnxTempDir,
        _addresses = addresses ?? _networkAddresses;

  ValueListenable<WifiTransferState> get state => _state;
  Stream<File> get received => _received.stream;

  static Future<List<WifiTransferAddress>> _networkAddresses() async {
    final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4, includeLoopback: false);
    return [
      for (final interface in interfaces)
        for (final address in interface.addresses)
          WifiTransferAddress(interfaceName: interface.name, address: address.address),
    ];
  }

  void _publish({WifiTransferStatus? status, List<String>? urls, String? error}) {
    _state.value = WifiTransferState(
      status: status ?? _state.value.status,
      urls: urls ?? _state.value.urls,
      uploads: _history.map((upload) => upload.snapshot()).toList(),
      error: error,
    );
  }

  void _progress() {
    if (_state.value.status != WifiTransferStatus.running) return;
    if (_progressTimer != null) return;
    final remaining = 150 - (_clock.elapsedMilliseconds - _lastProgress);
    if (remaining <= 0) {
      _lastProgress = _clock.elapsedMilliseconds;
      _publish();
    } else {
      _progressTimer = Timer(Duration(milliseconds: remaining), () {
        _progressTimer = null;
        _lastProgress = _clock.elapsedMilliseconds;
        _publish();
      });
    }
  }

  Future<void> start() async {
    if (_stopping != null) await _stopping;
    if (_state.value.status == WifiTransferStatus.running) return;
    if (_starting != null) return _starting;
    final completed = Completer<void>();
    _starting = completed.future;
    try {
      await _start();
    } finally {
      _starting = null;
      completed.complete();
    }
  }

  Future<void> _start() async {
    final generation = ++_generation;
    _history.clear();
    _lastProgress = _clock.elapsedMilliseconds;
    _publish(status: WifiTransferStatus.starting, urls: []);
    if (generation != _generation) return;
    HttpServer? bound;
    try {
      final random = Random.secure();
      const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
      _token = List.generate(6, (_) => alphabet[random.nextInt(alphabet.length)]).join();
      for (var port = 8866; port <= 8875; port++) {
        try {
          bound = await HttpServer.bind(InternetAddress.anyIPv4, port);
          break;
        } on SocketException {
          if (generation != _generation) return;
        }
      }
      bound ??= await HttpServer.bind(InternetAddress.anyIPv4, 0);
      final addresses = sortTransferAddresses(await _addresses());
      if (generation != _generation) {
        await bound.close(force: true);
        return;
      }
      _server = bound;
      final urls = addresses.map((value) => 'http://${value.address}:${bound!.port}/$_token/').toList();
      bound.listen((request) => unawaited(_handle(request, generation)), onError: (Object error) {
        unawaited(_serverFailed(generation));
      });
      _publish(status: WifiTransferStatus.running, urls: urls);
    } catch (_) {
      try {
        await bound?.close(force: true);
      } catch (_) {}
      if (generation == _generation) {
        _server = null;
        _publish(status: WifiTransferStatus.failed, urls: [], error: 'Unable to start server');
      }
    }
  }

  Future<void> _serverFailed(int generation) async {
    if (generation != _generation) return;
    await stop();
    if (_generation == generation + 1) {
      _publish(status: WifiTransferStatus.failed, urls: [], error: 'Server failed');
    }
  }

  Future<void> stop() async {
    if (_stopping != null) return _stopping;
    final completed = Completer<void>();
    _stopping = completed.future;
    try {
      await _stop();
    } finally {
      _stopping = null;
      completed.complete();
    }
  }

  Future<void> _stop() async {
    ++_generation;
    _progressTimer?.cancel();
    _progressTimer = null;
    final starting = _starting;
    final server = _server;
    _server = null;
    final uploads = _active.toList();
    for (final upload in uploads) {
      upload.cancelled = true;
    }
    _publish(status: WifiTransferStatus.stopped, urls: []);
    try {
      await server?.close(force: true);
    } catch (_) {}
    await Future.wait(uploads.map((upload) => upload.cancelStreams()));
    await Future.wait(uploads.map((upload) => upload.completed.future));
    await starting;
  }

  Future<void> _json(HttpRequest request, int status, Map<String, Object> body) async {
    try {
      request.response
        ..statusCode = status
        ..persistentConnection = false
        ..headers.contentType = ContentType('application', 'json', charset: 'utf-8')
        ..write(jsonEncode(body));
      await request.response.close();
    } catch (_) {}
  }

  Future<void> _handle(HttpRequest request, int generation) async {
    try {
      if (generation == _generation && request.method == 'GET' && request.uri.path == '/$_token/') {
        request.response.headers
          ..contentType = ContentType('text', 'html', charset: 'utf-8')
          ..set(HttpHeaders.cacheControlHeader, 'no-store');
        request.response.write(uploadPageHtml);
        await request.response.close();
      } else if (generation == _generation && request.method == 'POST' && request.uri.path == '/$_token/upload') {
        if (_active.length >= 4) {
          await _json(request, HttpStatus.tooManyRequests, {'ok': false, 'error': 'busy'});
        } else {
          await _upload(request, generation);
        }
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      }
    } catch (_) {
      await _json(request, HttpStatus.internalServerError, {'ok': false, 'error': 'Server error'});
    }
  }

  void _checkActive(_Upload upload, int generation) {
    if (upload.cancelled || generation != _generation) {
      throw const _UploadFailure(HttpStatus.badRequest, 'Upload stopped');
    }
    if (upload.inputFailed) {
      throw const _UploadFailure(HttpStatus.badRequest, 'Upload interrupted');
    }
  }

  void _readMultipart(HttpRequest request, String boundary, _Upload upload) {
    void fail(Object error, StackTrace stack) {
      upload.inputFailed = true;
      unawaited(upload.cancelStreams());
    }

    // Keep listening to outer errors while the file stream is being consumed.
    // mime can also throw from its input callback for malformed headers.
    runZonedGuarded(() {
      upload.parts = request.cast<List<int>>().transform(MimeMultipartTransformer(boundary)).listen(
          (part) {
            if (!upload.firstPart.isCompleted) {
              upload.firstPart.complete(part);
            } else {
              upload.data = StreamIterator(part);
              fail(const FormatException('Expected one file'), StackTrace.current);
            }
          },
          onError: fail,
          onDone: () {
            if (!upload.firstPart.isCompleted) upload.firstPart.complete(null);
            if (!upload.bodyDone.isCompleted) upload.bodyDone.complete();
          });
    }, fail);
  }

  Future<File> _createFile(Directory directory, _Upload upload) async {
    while (true) {
      final name = uniqueTransferFileName(upload.fileName, (name) {
        final filePath = path.join(directory.path, name);
        return _reserved.contains(filePath) ||
            FileSystemEntity.typeSync(filePath, followLinks: false) != FileSystemEntityType.notFound;
      });
      final file = File(path.join(directory.path, name));
      _reserved.add(file.path);
      try {
        await file.create(exclusive: true);
        upload.fileName = name;
        upload.temporary = file;
        return file;
      } on FileSystemException {
        _reserved.remove(file.path);
        if (await FileSystemEntity.type(file.path, followLinks: false) == FileSystemEntityType.notFound) rethrow;
      }
    }
  }

  Future<void> _upload(HttpRequest request, int generation) async {
    final random = Random.secure();
    final id = List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final upload = _Upload(id, max(0, request.contentLength));
    _active.add(upload);
    RandomAccessFile? output;
    var status = HttpStatus.badRequest;
    try {
      final type = request.headers.contentType;
      final boundary = type?.parameters['boundary'];
      if (type?.mimeType != 'multipart/form-data' || boundary == null || boundary.isEmpty) {
        throw const _UploadFailure(HttpStatus.badRequest, 'Invalid upload');
      }
      _readMultipart(request, boundary, upload);
      final part = await upload.firstPart.future;
      _checkActive(upload, generation);
      if (part == null) throw const _UploadFailure(HttpStatus.badRequest, 'Missing file');
      final data = upload.data = StreamIterator(part);
      // Listen before awaiting filesystem work so the first chunk pauses input.
      final firstChunk = data.moveNext().then((value) => value, onError: (Object error, StackTrace stack) {
        upload.inputFailed = true;
        return false;
      });
      final disposition = part.headers['content-disposition'] ?? '';
      final name = transferFileNameFromDisposition(disposition);
      if (_dispositionParameters(disposition)['name'] != 'file' || name == null) {
        throw const _UploadFailure(HttpStatus.badRequest, 'Missing file');
      }
      upload.fileName = sanitizeTransferFileName(name);
      _history.insert(0, upload);
      if (_history.length > 200) _history.removeLast();
      _publish();
      final extension = path.extension(upload.fileName).toLowerCase();
      if (!_extensions.any((allowed) => extension == '.$allowed')) {
        throw const _UploadFailure(HttpStatus.unsupportedMediaType, 'unsupported');
      }
      _checkActive(upload, generation);
      final directory = await _tempDirectory();
      await directory.create(recursive: true);
      _checkActive(upload, generation);
      final file = await _createFile(directory, upload);
      _checkActive(upload, generation);
      output = await file.open(mode: FileMode.write);
      var hasChunk = await firstChunk;
      while (hasChunk) {
        _checkActive(upload, generation);
        upload.receivedBytes += data.current.length;
        if (upload.receivedBytes > maxFileBytes) {
          throw const _UploadFailure(HttpStatus.requestEntityTooLarge, 'too_large');
        }
        await output.writeFrom(data.current);
        _progress();
        hasChunk = await data.moveNext();
      }
      _checkActive(upload, generation);
      await upload.bodyDone.future;
      _checkActive(upload, generation);
      await output.close();
      output = null;
      _checkActive(upload, generation);
      upload.file = file;
      upload.done = true;
      _publish();
      _received.add(file);
      await _json(request, HttpStatus.ok, {'ok': true, 'name': upload.fileName});
    } on _UploadFailure catch (error) {
      status = error.status;
      upload.error = error.error;
    } catch (_) {
      upload.error = upload.cancelled ? 'Upload stopped' : 'Upload interrupted';
    } finally {
      try {
        await output?.close();
      } catch (_) {}
      if (upload.file == null) {
        try {
          await upload.temporary?.delete();
        } catch (_) {}
        upload.done = true;
        _publish();
        await _json(request, status, {'ok': false, 'error': upload.error ?? 'Upload interrupted'});
      }
      await upload.cancelStreams();
      _reserved.remove(upload.temporary?.path);
      _active.remove(upload);
      upload.completed.complete();
    }
  }
}
