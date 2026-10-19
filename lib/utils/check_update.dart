import 'dart:io';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/service/update/github_release.dart';
import 'package:anx_reader/service/update/startup_update_check.dart';
import 'package:anx_reader/service/update/update_downloader.dart';
import 'package:anx_reader/utils/app_version.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/markdown/styled_markdown.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

final _releases = GitHubReleases();
final _startupCheck = StartupUpdateCheck();
bool _updateSheetOpen = false;

Future<void> checkUpdate(bool manualCheck) async {
  if (!EnvVar.enableCheckUpdate || !_releases.isConfigured) return;
  try {
    if (manualCheck) {
      await _checkAndShowUpdate(true);
    } else {
      await _startupCheck.run(
        checkForUpdate: () => _checkAndShowUpdate(false),
        shouldRetry: (error) =>
            error is DioException &&
            const {
              DioExceptionType.connectionError,
              DioExceptionType.connectionTimeout,
              DioExceptionType.receiveTimeout,
              DioExceptionType.sendTimeout,
            }.contains(error.type),
      );
    }
  } catch (error) {
    final context = navigatorKey.currentContext;
    if (manualCheck && context != null && context.mounted) {
      AnxToast.show(L10n.of(context).commonFailed);
    }
    AnxLog.severe('Update: Failed to check GitHub releases $error');
  }
}

Future<void> _checkAndShowUpdate(bool manualCheck) async {
  final release = await _releases.latest();
  final currentVersion = await getAppVersion();
  final context = navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  if (release == null || !isNewerRelease(currentVersion, release.tagName)) {
    if (manualCheck) AnxToast.show(L10n.of(context).commonNoNewVersion);
    return;
  }
  if (_updateSheetOpen) return;
  _updateSheetOpen = true;
  try {
    await showMgSheet(
      context: context,
      title: L10n.of(context).mgUpdateTitle,
      subtitle: '${currentVersion.split('+').first} → ${release.displayVersion}',
      builder: (_) => _UpdateSheet(release: release),
    );
  } finally {
    _updateSheetOpen = false;
  }
}

Future<void> _open(Uri uri) async {
  try {
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) throw StateError('Could not open $uri');
  } catch (error) {
    AnxLog.severe('Update: Failed to open $uri $error');
    final context = navigatorKey.currentContext;
    if (context != null && context.mounted) AnxToast.show(L10n.of(context).commonFailed);
  }
}

enum _Stage { idle, downloading, ready, failed }

/// Release notes, then: Android downloads and verifies the APK in the app and opens the system
/// installer; iOS downloads the IPA in the browser for self-signing; other systems open the release.
class _UpdateSheet extends StatefulWidget {
  const _UpdateSheet({required this.release});

  final GitHubRelease release;

  @override
  State<_UpdateSheet> createState() => _UpdateSheetState();
}

class _UpdateSheetState extends State<_UpdateSheet> {
  late final GitHubReleaseAsset? _asset = widget.release.assetFor(Platform.operatingSystem);
  _Stage _stage = _Stage.idle;
  int _received = 0;
  int _total = 0;
  CancelToken? _cancel;
  File? _package;

  bool get _inApp => Platform.isAndroid && _asset != null;

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _update() async {
    final asset = _asset;
    if (!_inApp || asset == null) {
      await _open(asset?.downloadUrl ?? widget.release.releaseUrl);
      return;
    }
    final cancel = _cancel = CancelToken();
    setState(() {
      _stage = _Stage.downloading;
      _received = 0;
      _total = asset.size;
    });
    try {
      final package = await UpdateDownloader().download(
        asset,
        cancelToken: cancel,
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      if (!mounted) return;
      setState(() {
        _package = package;
        _stage = _Stage.ready;
      });
      await _install();
    } catch (error) {
      if (cancel.isCancelled || !mounted) return;
      AnxLog.severe('Update: download failed $error');
      setState(() => _stage = _Stage.failed);
    }
  }

  Future<void> _install() async {
    final package = _package;
    if (package == null) return;
    final result = await OpenFilex.open(package.path, type: 'application/vnd.android.package-archive');
    if (result.type != ResultType.done) {
      AnxLog.severe('Update: installer did not open ${result.message}');
      if (mounted) AnxToast.show(L10n.of(context).commonFailed);
    }
  }

  void _cancelDownload() {
    _cancel?.cancel();
    setState(() => _stage = _Stage.idle);
  }

  String _megabytes(int bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final notes = widget.release.body.trim();
    final progress = _total > 0 ? (_received / _total).clamp(0.0, 1.0) : null;

    Widget status() => switch (_stage) {
          _Stage.idle => const SizedBox.shrink(),
          _Stage.downloading => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(value: progress, minHeight: 6),
                ),
                const SizedBox(height: 8),
                Text(
                  [
                    l10n.commonDownloading,
                    if (progress != null) '${(progress * 100).round()}%',
                    if (_total > 0) '${_megabytes(_received)} / ${_megabytes(_total)} MB',
                  ].join('  '),
                  style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                ),
              ],
            ),
          _Stage.ready => Text(l10n.mgUpdateDownloaded, style: TextStyle(fontSize: 14, color: accent)),
          _Stage.failed => Text(l10n.commonDownloadFailed, style: const TextStyle(fontSize: 14, color: MgColors.red)),
        };

    final (String secondary, VoidCallback onSecondary, String primary, VoidCallback? onPrimary) = switch (_stage) {
      _Stage.idle => (l10n.mgUpdateLater, () => Navigator.of(context).pop(), l10n.mgUpdateNow, _update),
      _Stage.downloading => (l10n.commonCancel, _cancelDownload, l10n.commonDownloading, null),
      _Stage.ready => (l10n.mgUpdateLater, () => Navigator.of(context).pop(), l10n.mgUpdateInstall, _install),
      _Stage.failed => (l10n.mgUpdateLater, () => Navigator.of(context).pop(), l10n.commonRetry, _update),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (notes.isNotEmpty)
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .4),
              child: SingleChildScrollView(child: StyledMarkdown(data: notes)),
            ),
          if (Platform.isIOS && _asset != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l10n.mgUpdateIosSign, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              onPressed: () => _open(widget.release.releaseUrl),
              child: Text(l10n.viewChangelog),
            ),
          ),
          if (_stage != _Stage.idle) ...[const SizedBox(height: 4), status(), const SizedBox(height: 12)],
          const SizedBox(height: 4),
          MgSheetButtons(secondary: secondary, onSecondary: onSecondary, primary: primary, onPrimary: onPrimary),
        ],
      ),
    );
  }
}
