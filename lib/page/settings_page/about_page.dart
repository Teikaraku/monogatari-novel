import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/service/update/github_release.dart';
import 'package:anx_reader/utils/app_version.dart';
import 'package:anx_reader/utils/check_update.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const _upstream = 'https://github.com/Anxcye/anx-reader';

Future<void> _openLink(String url) async {
  try {
    if (await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) return;
  } catch (_) {}
  AnxToast.show(url);
}

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<String> _version = getAppVersion();
  int _taps = 0;
  Timer? _tapReset;

  @override
  void dispose() {
    _tapReset?.cancel();
    super.dispose();
  }

  /// Copies the version; seven quick taps turn on the developer options.
  void _onVersionTap(String version) {
    Clipboard.setData(ClipboardData(text: version));
    AnxToast.show(L10n.of(context).notesPageCopied);
    _taps++;
    _tapReset?.cancel();
    _tapReset = Timer(const Duration(seconds: 2), () => _taps = 0);
    if (_taps >= 7 && !Prefs().developerOptionsEnabled) {
      _taps = 0;
      Prefs().developerOptionsEnabled = true;
      AnxToast.show('Developer options enabled');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return MgPage(
      title: l10n.mgAbout,
      grouped: true,
      contentWidth: mgReadableWidth,
      body: FutureBuilder<String>(
        future: _version,
        builder: (context, snapshot) {
          final version = (snapshot.data ?? '') + (kDebugMode ? ' (debug)' : '');
          return ListView(
            padding: EdgeInsets.only(bottom: 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              MgReadable(child: _Header(version: version, onVersionTap: () => _onVersionTap(snapshot.data ?? ''))),
              const SizedBox(height: 12),
              if (EnvVar.enableCheckUpdate)
                MgGroup(children: [
                  _AboutLink.action(
                    icon: Icons.system_update_outlined,
                    title: l10n.aboutCheckForUpdates,
                    onTap: () => checkUpdate(true),
                  ),
                  _AboutLink(
                    icon: Icons.history_rounded,
                    title: l10n.viewChangelog,
                    url: 'https://github.com/$githubRepository/releases',
                  ),
                ]),
              MgGroup(title: l10n.mgAboutOpenSource, children: [
                _AboutLink.page(
                  icon: Icons.favorite_outline_rounded,
                  title: l10n.mgCredits,
                  page: () => const _CreditsPage(),
                ),
                _AboutLink(icon: Icons.balance_rounded, title: l10n.mgAboutMit, url: '$_upstream/blob/main/LICENSE'),
                _AboutLink.action(
                  icon: Icons.description_outlined,
                  title: l10n.mgAboutThirdParty,
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: MgBrand.name(context),
                    applicationVersion: version,
                  ),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }
}

/// The app icon beside its name, then the version (tap to copy) and a one-line tagline.
class _Header extends StatelessWidget {
  const _Header({required this.version, required this.onVersionTap});

  final String version;
  final VoidCallback onVersionTap;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final name = MgBrand.name(context);
    final other = name == MgBrand.zh ? MgBrand.en : MgBrand.zh;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Image.asset('assets/branding/logo_rounded.png', width: 64, height: 64, cacheWidth: 192),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(name,
                          style: TextStyle(fontSize: 34, height: 1.15, fontWeight: FontWeight.w600, color: accent)),
                    ),
                    Text(other, style: TextStyle(fontSize: 14, color: palette.secondaryLabel)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onVersionTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text('${l10n.appVersion} $version',
                  style: TextStyle(fontSize: 14, color: palette.secondaryLabel)),
            ),
          ),
          const SizedBox(height: 6),
          Text(l10n.mgAboutTagline, style: const TextStyle(fontSize: 16)),
        ],
      ),
    );
  }
}

/// A row with a tinted icon: external links end in an "open" mark, pages in a chevron.
class _AboutLink extends StatelessWidget {
  const _AboutLink({required this.icon, required this.title, required String this.url, this.subtitle})
      : page = null,
        onTap = null;

  const _AboutLink.page({required this.icon, required this.title, required Widget Function() this.page})
      : url = null,
        subtitle = null,
        onTap = null;

  const _AboutLink.action({required this.icon, required this.title, required VoidCallback this.onTap})
      : url = null,
        subtitle = null,
        page = null;

  final IconData icon;
  final String title;
  final String? subtitle;
  final String? url;
  final Widget Function()? page;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return MgRow(
      title: title,
      subtitle: subtitle,
      leading: Icon(icon, size: 22, color: Theme.of(context).colorScheme.primary),
      trailing: url == null
          ? null
          : Icon(Icons.open_in_new_rounded, size: 18, color: palette.secondaryLabel.withValues(alpha: .7)),
      showChevron: url == null,
      onTap: () {
        if (url != null) {
          _openLink(url!);
        } else if (page != null) {
          Navigator.of(context).push(CupertinoPageRoute(builder: (_) => page!()));
        } else {
          onTap?.call();
        }
      },
    );
  }
}

class _CreditsPage extends StatelessWidget {
  const _CreditsPage();

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return MgPage(
      title: l10n.mgCredits,
      grouped: true,
      contentWidth: mgReadableWidth,
      body: ListView(
        padding: EdgeInsets.only(top: 4, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: [
          MgGroup(title: l10n.mgCreditsContrib, children: [
            _AboutLink(icon: Icons.code_rounded, title: 'Anx Reader', subtitle: l10n.mgCreditsUpstream, url: _upstream),
            _AboutLink(
              icon: Icons.people_outline_rounded,
              title: l10n.mgCreditsContributors('Anx Reader'),
              url: '$_upstream/graphs/contributors',
            ),
            _AboutLink(
              icon: Icons.auto_stories_outlined,
              title: 'foliate-js',
              subtitle: l10n.mgCreditsEngine,
              url: 'https://github.com/johnfactotum/foliate-js',
            ),
          ]),
          MgGroup(title: l10n.mgCreditsServices, children: [
            _AboutLink(
              icon: Icons.translate_rounded,
              title: 'Microsoft Translator',
              subtitle: l10n.mgCreditsTranslate,
              url: 'https://www.microsoft.com/translator',
            ),
          ]),
          MgGroup(title: l10n.mgCreditsProjects, children: [
            _AboutLink(
              icon: Icons.flutter_dash_rounded,
              title: 'Flutter',
              subtitle: l10n.mgCreditsFramework,
              url: 'https://flutter.dev',
            ),
            _AboutLink(
              icon: Icons.web_rounded,
              title: 'flutter_inappwebview',
              subtitle: l10n.mgCreditsWebView,
              url: 'https://github.com/pichillilorenzo/flutter_inappwebview',
            ),
            _AboutLink(
              icon: Icons.account_tree_outlined,
              title: 'Riverpod',
              subtitle: l10n.mgCreditsState,
              url: 'https://riverpod.dev',
            ),
            _AboutLink(
              icon: Icons.storage_rounded,
              title: 'sqflite',
              subtitle: l10n.mgCreditsStorage,
              url: 'https://github.com/tekartik/sqflite',
            ),
            _AboutLink(
              icon: Icons.cloud_outlined,
              title: 'Dio',
              subtitle: l10n.mgCreditsNetwork,
              url: 'https://github.com/cfug/dio',
            ),
            _AboutLink(
              icon: Icons.sort_by_alpha_rounded,
              title: 'lpinyin',
              subtitle: l10n.mgCreditsPinyin,
              url: 'https://github.com/flutterchina/lpinyin',
            ),
          ]),
        ],
      ),
    );
  }
}
