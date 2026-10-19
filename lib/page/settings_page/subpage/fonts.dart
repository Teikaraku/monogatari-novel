import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/fonts.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher_string.dart';

/// Free fonts to download: a preview strip, name and description, and a download control.
class FontsSettingPage extends ConsumerWidget {
  const FontsSettingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    final fontList = ref.watch(fontsProvider);
    return MgSubPage(
      title: l10n.downloadFonts,
      grouped: true,
      body: fontList.when(
        data: (fonts) => fonts.isEmpty
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : ListView.separated(
                padding: EdgeInsets.fromLTRB(
                    16 + mgCenteredInset(context, mgReadableWidth), 12, 16 + mgCenteredInset(context, mgReadableWidth),
                    32 + MediaQuery.paddingOf(context).bottom),
                itemCount: fonts.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) => _FontCard(font: fonts[index]),
              ),
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (error, stack) => MgEmptyState(icon: Icons.font_download_off_outlined, title: l10n.fontFailedToLoadFonts),
      ),
    );
  }
}

class _FontCard extends StatelessWidget {
  const _FontCard({required this.font});

  final RemoteFontModel font;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final link = TextStyle(fontSize: 12, color: palette.secondaryLabel);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(color: palette.card, borderRadius: BorderRadius.circular(14)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (font.preview.isNotEmpty)
            Container(
              height: 56,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(color: palette.fill, borderRadius: BorderRadius.circular(10)),
              child: CachedNetworkImage(
                imageUrl: 'https://fonts.anxcye.com/${font.preview}',
                color: onSurface,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                placeholder: (context, url) => const SizedBox.shrink(),
                errorWidget: (context, url, error) => Align(
                  alignment: Alignment.centerLeft,
                  child: Icon(Icons.broken_image_outlined, color: palette.secondaryLabel),
                ),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(font.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                    if (font.desc.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(font.desc,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, height: 1.4, color: palette.secondaryLabel)),
                      ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 12,
                      children: [
                        GestureDetector(
                          onTap: () => launchUrlString(font.official, mode: LaunchMode.externalApplication),
                          child: Text(L10n.of(context).fontOfficialWebsite, style: link),
                        ),
                        GestureDetector(
                          onTap: () => launchUrlString(font.license.url, mode: LaunchMode.externalApplication),
                          child: Text(font.license.name, style: link),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _DownloadControl(font: font),
            ],
          ),
        ],
      ),
    );
  }
}

class _DownloadControl extends ConsumerWidget {
  const _DownloadControl({required this.font});

  final RemoteFontModel font;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final state = ref.watch(fontDownloadsProvider)[font.id];
    final downloads = ref.read(fontDownloadsProvider.notifier);
    final done = font.files.every((file) => downloads.isDownloaded(font.id, file));

    Widget pill(String label, VoidCallback? onTap, {bool filled = true, IconData? icon}) => Material(
          color: filled ? scheme.primary : palette.fill,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    Icon(icon, size: 15, color: filled ? scheme.onPrimary : palette.secondaryLabel),
                    const SizedBox(width: 4),
                  ],
                  Text(label,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: filled ? scheme.onPrimary : palette.secondaryLabel)),
                ],
              ),
            ),
          ),
        );

    if (done) return pill(l10n.fontDownloaded, null, filled: false, icon: Icons.check);

    switch (state?.status) {
      case DownloadStatus.downloading:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 34,
              height: 34,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(value: state!.progress, strokeWidth: 3),
                  InkResponse(
                    onTap: () => downloads.pauseDownload(font.id),
                    radius: 18,
                    child: Icon(Icons.pause_rounded, size: 18, color: scheme.primary),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close_rounded, size: 20, color: palette.secondaryLabel),
              onPressed: () => downloads.cancelDownload(font.id),
            ),
          ],
        );
      case DownloadStatus.paused:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            pill(l10n.commonResume, () => downloads.resumeDownload(font)),
            IconButton(
              icon: Icon(Icons.close_rounded, size: 20, color: palette.secondaryLabel),
              onPressed: () => downloads.cancelDownload(font.id),
            ),
          ],
        );
      case DownloadStatus.failed:
        return pill(l10n.commonRetry, () => downloads.startDownload(font), icon: Icons.refresh);
      default:
        return pill(l10n.commonDownload, () => downloads.startDownload(font), icon: Icons.download_rounded);
    }
  }
}
