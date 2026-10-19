import 'dart:convert';
import 'dart:ffi';

import 'package:dio/dio.dart';

const githubRepository = String.fromEnvironment('GITHUB_REPOSITORY', defaultValue: 'Teikaraku/monogatari-novel');

class GitHubReleaseAsset {
  const GitHubReleaseAsset({required this.name, required this.downloadUrl, this.sha256 = '', this.size = 0});

  final String name;
  final Uri downloadUrl;

  /// Lower-case hex digest GitHub records for the upload; empty when it has none.
  final String sha256;
  final int size;
}

class GitHubRelease {
  const GitHubRelease({required this.repository, required this.tagName, required this.body, required this.assets});

  final String repository;
  final String tagName;
  final String body;
  final List<GitHubReleaseAsset> assets;

  String get displayVersion => tagName.replaceFirst(RegExp(r'^(?:monogatari-v|v)'), '');

  Uri get releaseUrl => Uri.https('github.com', '/$repository/releases/tag/$tagName');

  GitHubReleaseAsset? assetFor(String operatingSystem, {Abi? abi}) {
    if (operatingSystem == 'ios') {
      for (final asset in assets) {
        final name = asset.name.toLowerCase();
        if (name.contains('ios') && name.endsWith('.ipa')) return asset;
      }
      return null;
    }
    if (operatingSystem != 'android') return null;
    final architecture = switch (abi ?? Abi.current()) {
      Abi.androidArm64 => 'arm64',
      Abi.androidArm => 'armv7',
      Abi.androidX64 => 'x64',
      Abi.androidIA32 => 'x86',
      _ => null,
    };
    if (architecture == null) return null;
    GitHubReleaseAsset? universal;
    for (final asset in assets) {
      final name = asset.name.toLowerCase();
      if (!name.contains('android') || !name.endsWith('.apk')) continue;
      if (_androidArchitecture(name) == architecture) return asset;
      if (RegExp(r'(^|[-_.])universal([-_.]|$)').hasMatch(name)) universal ??= asset;
    }
    return universal;
  }
}

String? _androidArchitecture(String name) {
  if (RegExp(r'arm64|aarch64').hasMatch(name)) return 'arm64';
  if (RegExp(r'armv7|armeabi-v7a|arm-v7').hasMatch(name)) return 'armv7';
  if (RegExp(r'x86_64|x64|amd64').hasMatch(name)) return 'x64';
  if (RegExp(r'(^|[-_.])x86([-_.]|$)').hasMatch(name)) return 'x86';
  return null;
}

/// Public GitHub Releases is the only source of application update metadata.
class GitHubReleases {
  GitHubReleases({String repository = githubRepository, Dio? dio})
      : repository = repository.trim(),
        _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 20),
            ));

  final String repository;
  final Dio _dio;
  Future<GitHubRelease?>? _pending;

  bool get isConfigured =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$').hasMatch(repository) &&
      !const ['.', '..'].contains(repository.split('/').last);

  Future<GitHubRelease?> latest() {
    if (!isConfigured) return Future.value(null);
    final pending = _pending;
    if (pending != null) return pending;
    late final Future<GitHubRelease?> request;
    request = _loadLatest().whenComplete(() {
      if (identical(_pending, request)) _pending = null;
    });
    _pending = request;
    return request;
  }

  Future<GitHubRelease?> _loadLatest() async {
    final response = await _dio.get<String>(
      'https://api.github.com/repos/$repository/releases/latest',
      options: Options(
        headers: {'Accept': 'application/vnd.github+json'},
        responseType: ResponseType.plain,
        validateStatus: (status) => status == 200 || status == 404,
      ),
    );
    if (response.statusCode == 404) return null;
    final decoded = jsonDecode(response.data ?? '');
    if (decoded is! Map<String, dynamic> ||
        decoded['tag_name'] is! String ||
        (decoded['tag_name'] as String).trim().isEmpty ||
        (decoded['body'] != null && decoded['body'] is! String) ||
        (decoded['assets'] != null && decoded['assets'] is! List)) {
      throw const FormatException('GitHub release metadata is invalid');
    }
    if (decoded['draft'] == true || decoded['prerelease'] == true) return null;
    final tag = decoded['tag_name'] as String;
    final assets = <GitHubReleaseAsset>[];
    for (final item in decoded['assets'] as List? ?? const []) {
      if (item is! Map || item['name'] is! String || item['browser_download_url'] is! String) continue;
      final name = item['name'] as String;
      final uri = Uri.tryParse(item['browser_download_url'] as String);
      if (name.isEmpty || uri == null || !_isReleaseAsset(uri, tag)) continue;
      final digest = item['digest'];
      final sha256 = digest is String && RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digest)
          ? digest.substring('sha256:'.length).toLowerCase()
          : '';
      final size = item['size'];
      assets.add(GitHubReleaseAsset(name: name, downloadUrl: uri, sha256: sha256, size: size is int ? size : 0));
    }
    return GitHubRelease(
      repository: repository,
      tagName: tag,
      body: decoded['body'] as String? ?? '',
      assets: List.unmodifiable(assets),
    );
  }

  bool _isReleaseAsset(Uri uri, String tag) {
    final segments = uri.pathSegments;
    final repositoryParts = repository.split('/');
    return uri.scheme == 'https' &&
        uri.host.toLowerCase() == 'github.com' &&
        uri.userInfo.isEmpty &&
        (!uri.hasPort || uri.port == 443) &&
        segments.length == 6 &&
        segments[0].toLowerCase() == repositoryParts[0].toLowerCase() &&
        segments[1].toLowerCase() == repositoryParts[1].toLowerCase() &&
        segments[2] == 'releases' &&
        segments[3] == 'download' &&
        segments[4] == tag &&
        segments[5].isNotEmpty;
  }
}

bool isNewerRelease(String currentVersion, String tagName) {
  final current = _SemanticVersion.tryParse(currentVersion);
  final release = _SemanticVersion.tryParse(tagName);
  return current != null && release != null && current.compareTo(release) < 0;
}

class _SemanticVersion implements Comparable<_SemanticVersion> {
  const _SemanticVersion(this.core, this.prerelease);

  static final _pattern = RegExp(
    r'^(?:monogatari-v|v)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );
  static final _numericIdentifier = RegExp(r'^[0-9]+$');

  final List<BigInt> core;
  final List<String> prerelease;

  static _SemanticVersion? tryParse(String version) {
    final match = _pattern.firstMatch(version);
    if (match == null || match.end != version.length) return null;
    final prerelease = match[4]?.split('.') ?? const <String>[];
    for (final identifier in prerelease) {
      if (_numericIdentifier.hasMatch(identifier) && identifier.length > 1 && identifier.startsWith('0')) return null;
    }
    return _SemanticVersion([for (var i = 1; i <= 3; i++) BigInt.parse(match[i]!)], prerelease);
  }

  @override
  int compareTo(_SemanticVersion other) {
    for (var i = 0; i < core.length; i++) {
      final comparison = core[i].compareTo(other.core[i]);
      if (comparison != 0) return comparison;
    }
    if (prerelease.isEmpty || other.prerelease.isEmpty) {
      if (prerelease.isEmpty && other.prerelease.isEmpty) return 0;
      return prerelease.isEmpty ? 1 : -1;
    }
    for (var i = 0; i < prerelease.length && i < other.prerelease.length; i++) {
      final local = prerelease[i];
      final remote = other.prerelease[i];
      final localNumeric = _numericIdentifier.hasMatch(local);
      final remoteNumeric = _numericIdentifier.hasMatch(remote);
      final int comparison;
      if (localNumeric && remoteNumeric) {
        comparison = BigInt.parse(local).compareTo(BigInt.parse(remote));
      } else if (localNumeric != remoteNumeric) {
        comparison = localNumeric ? -1 : 1;
      } else {
        comparison = local.compareTo(remote);
      }
      if (comparison != 0) return comparison;
    }
    return prerelease.length.compareTo(other.prerelease.length);
  }
}
