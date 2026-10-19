import 'dart:io';

import 'package:anx_reader/service/update/github_release.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Downloads a release asset from GitHub into the cache. The installer only ever sees a complete
/// file whose SHA-256 matches the digest GitHub recorded for the upload.
class UpdateDownloader {
  UpdateDownloader({Dio? dio, Future<Directory> Function()? cacheDirectory})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(minutes: 2),
            )),
        _cacheDirectory = cacheDirectory ?? getApplicationCacheDirectory;

  final Dio _dio;
  final Future<Directory> Function() _cacheDirectory;

  static const _githubHosts = {
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'github-releases.githubusercontent.com',
  };

  Future<File> download(
    GitHubReleaseAsset asset, {
    CancelToken? cancelToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final url = asset.downloadUrl;
    if (url.scheme != 'https' || !_githubHosts.contains(url.host.toLowerCase()) || url.userInfo.isNotEmpty) {
      throw const FormatException('Update packages must come from GitHub');
    }
    final name = p.basename(asset.name);
    if (name != asset.name || name.isEmpty || name.startsWith('.')) {
      throw const FormatException('Invalid update package name');
    }
    final directory = Directory(p.join((await _cacheDirectory()).path, 'updates'));
    // Only the newest package is kept.
    if (await directory.exists()) await directory.delete(recursive: true);
    await directory.create(recursive: true);
    final complete = File(p.join(directory.path, name));
    final partial = File('${complete.path}.part');
    try {
      await _dio.download(
        url.toString(),
        partial.path,
        cancelToken: cancelToken,
        onReceiveProgress: (received, total) => onProgress?.call(received, total > 0 ? total : asset.size),
        options: Options(followRedirects: true, receiveTimeout: const Duration(minutes: 2)),
      );
      if (asset.size > 0 && await partial.length() != asset.size) {
        throw const FormatException('The update package is incomplete');
      }
      if (asset.sha256.isNotEmpty) {
        final digest = (await sha256.bind(partial.openRead()).first).toString();
        if (digest != asset.sha256) throw const FormatException('The update package failed verification');
      }
      return await partial.rename(complete.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }
}
