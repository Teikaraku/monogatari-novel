import 'dart:io';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/update/github_release.dart';
import 'package:anx_reader/service/update/startup_update_check.dart';
import 'package:anx_reader/utils/app_version.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/markdown/styled_markdown.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:url_launcher/url_launcher.dart';

final _releases = GitHubReleases();
final _startupCheck = StartupUpdateCheck();
bool _updateDialogOpen = false;

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
  if (_updateDialogOpen) return;
  _updateDialogOpen = true;
  try {
    if (manualCheck && Navigator.of(context).canPop()) Navigator.of(context).pop();
    final asset = release.assetFor(Platform.operatingSystem);
    final downloadUrl = asset?.downloadUrl ?? release.releaseUrl;
    await SmartDialog.show<void>(
      builder: (BuildContext context) {
        final signingNote = Platform.isIOS && asset != null ? '\n\niOS IPA 需要自行签名安装。' : '';
        return AlertDialog(
          title: Text(L10n.of(context).commonNewVersion, style: const TextStyle(fontWeight: FontWeight.bold)),
          content: SingleChildScrollView(
            child: StyledMarkdown(
              data: '''### ${L10n.of(context).updateNewVersion} ${release.displayVersion}\n
${L10n.of(context).updateCurrentVersion} $currentVersion\n
${release.body}$signingNote''',
            ),
          ),
          actions: <Widget>[
            TextButton(onPressed: () => SmartDialog.dismiss(), child: Text(L10n.of(context).commonCancel)),
            TextButton(
              onPressed: () async {
                try {
                  if (!await launchUrl(downloadUrl, mode: LaunchMode.externalApplication)) {
                    throw StateError('Could not open the GitHub release');
                  }
                } catch (error) {
                  AnxLog.severe('Update: Failed to open GitHub download $error');
                  if (context.mounted) AnxToast.show(L10n.of(context).commonFailed);
                }
              },
              child: Text(L10n.of(context).updateViaGithub),
            ),
          ],
        );
      },
    );
  } finally {
    _updateDialogOpen = false;
  }
}
