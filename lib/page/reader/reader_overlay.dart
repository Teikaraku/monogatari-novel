import 'dart:async';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/reader/listen_panel.dart';
import 'package:anx_reader/page/reader/reader_kit.dart';
import 'package:anx_reader/page/reader/typography_panel.dart';
import 'package:flutter/material.dart';

enum ReaderPanel { main, typography, listen }

/// Everything shown over the page on a tap: a round back button and a capsule of actions at
/// the top, and a floating card at the bottom that holds progress and tools, or one of the
/// type and listen panels.
class ReaderOverlay extends StatefulWidget {
  const ReaderOverlay({
    super.key,
    required this.epubPlayerKey,
    required this.bookmarked,
    required this.night,
    required this.onBack,
    required this.onBookmark,
    required this.onContents,
    required this.onSettings,
    required this.onNight,
    required this.onDismiss,
    required this.menu,
    required this.openBackground,
  });

  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final bool bookmarked;
  final bool night;
  final VoidCallback onBack;
  final VoidCallback onBookmark;
  final VoidCallback onContents;
  final VoidCallback onSettings;
  final VoidCallback onNight;
  final VoidCallback onDismiss;
  final List<List<MgMenuEntry>> Function() menu;
  final VoidCallback openBackground;

  @override
  State<ReaderOverlay> createState() => ReaderOverlayState();
}

class ReaderOverlayState extends State<ReaderOverlay> {
  ReaderPanel _panel = ReaderPanel.main;

  ReaderPanel get panel => _panel;

  void show(ReaderPanel panel) => setState(() => _panel = panel);

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final bottom = switch (_panel) {
      ReaderPanel.main => _MainCard(
          key: const ValueKey('main'),
          epubPlayerKey: widget.epubPlayerKey,
          night: widget.night,
          onContents: widget.onContents,
          onTypography: () => show(ReaderPanel.typography),
          onListen: () => show(ReaderPanel.listen),
          onNight: widget.onNight,
          onSettings: widget.onSettings,
        ),
      ReaderPanel.typography => TypographyPanel(
          key: const ValueKey('typography'),
          epubPlayerKey: widget.epubPlayerKey,
          onClose: () => show(ReaderPanel.main),
          onMore: widget.onSettings,
          onBackground: widget.openBackground,
        ),
      ReaderPanel.listen => ListenPanel(
          key: const ValueKey('listen'),
          epubPlayerKey: widget.epubPlayerKey,
          onClose: () => show(ReaderPanel.main),
        ),
    };

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onDismiss,
            onVerticalDragUpdate: (_) {},
            child: const ColoredBox(color: Color(0x14000000)),
          ),
        ),
        Positioned(
          top: padding.top + 8,
          left: 12,
          right: 12,
          child: Row(
            children: [
              ReaderRoundButton(
                icon: Icons.arrow_back,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                onTap: widget.onBack,
              ),
              const Spacer(),
              ReaderCapsule(children: [
                ReaderCapsuleButton(
                  icon: widget.bookmarked ? Icons.bookmark : Icons.bookmark_border,
                  active: widget.bookmarked,
                  onTap: widget.onBookmark,
                ),
                MgMenu(
                  sections: widget.menu,
                  builder: (context, open) => ReaderCapsuleButton(icon: Icons.more_horiz, onTap: () => open()),
                ),
              ]),
            ],
          ),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: padding.bottom + 12,
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, .06), end: Offset.zero).animate(animation),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.bottomCenter,
                children: [...previous, if (current != null) current],
              ),
              child: bottom,
            ),
          ),
        ),
      ],
    );
  }
}

class _MainCard extends StatelessWidget {
  const _MainCard({
    super.key,
    required this.epubPlayerKey,
    required this.night,
    required this.onContents,
    required this.onTypography,
    required this.onListen,
    required this.onNight,
    required this.onSettings,
  });

  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final bool night;
  final VoidCallback onContents;
  final VoidCallback onTypography;
  final VoidCallback onListen;
  final VoidCallback onNight;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return ReaderCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ProgressBlock(epubPlayerKey: epubPlayerKey),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                  child: ReaderToolButton(icon: Icons.format_list_bulleted, label: l10n.readerToc, onTap: onContents)),
              Expanded(child: ReaderToolButton(icon: Icons.text_fields, label: l10n.readerStyle, onTap: onTypography)),
              Expanded(
                  child: ReaderToolButton(icon: Icons.headphones_outlined, label: l10n.readerListen, onTap: onListen)),
              Expanded(
                child: ReaderToolButton(
                  icon: night ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                  label: night ? l10n.readerDay : l10n.readerNight,
                  onTap: onNight,
                ),
              ),
              Expanded(child: ReaderToolButton(icon: Icons.tune, label: l10n.readerSettings, onTap: onSettings)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Chapter title and position over a slider between previous and next chapter.
class _ProgressBlock extends StatefulWidget {
  const _ProgressBlock({required this.epubPlayerKey});

  final GlobalKey<EpubPlayerState> epubPlayerKey;

  @override
  State<_ProgressBlock> createState() => _ProgressBlockState();
}

class _ProgressBlockState extends State<_ProgressBlock> {
  double? _dragging;
  Timer? _seek;

  @override
  void dispose() {
    _seek?.cancel();
    super.dispose();
  }

  void _drag(double value) {
    setState(() => _dragging = value);
    _seek?.cancel();
    _seek = Timer(const Duration(milliseconds: 120), () => widget.epubPlayerKey.currentState?.goToPercentage(value));
  }

  void _settle() => Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) setState(() => _dragging = null);
      });

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final player = widget.epubPlayerKey.currentState;
    final percent = (_dragging ?? player?.percentage ?? 0).clamp(0.0, 1.0);
    final chapter = player?.chapterTitle ?? '';
    final current = player?.chapterCurrentPage ?? 0;
    final total = player?.chapterTotalPages ?? 0;

    Widget step(IconData icon, VoidCallback onTap) => InkResponse(
          radius: 20,
          onTap: () {
            onTap();
            setState(() => _dragging = null);
          },
          child: SizedBox(width: 32, height: 40, child: Icon(icon, size: 26, color: scheme.onSurface)),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Text(
                chapter.isEmpty ? ' ' : chapter,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              [if (total > 0) '$current/$total', '${(percent * 100).toStringAsFixed(1)}%'].join('  ·  '),
              style: TextStyle(
                fontSize: 12,
                color: palette.secondaryLabel,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            step(Icons.chevron_left, () => widget.epubPlayerKey.currentState?.prevChapter()),
            Expanded(
              child: Slider(value: percent, onChanged: _drag, onChangeEnd: (_) => _settle()),
            ),
            step(Icons.chevron_right, () => widget.epubPlayerKey.currentState?.nextChapter()),
          ],
        ),
      ],
    );
  }
}
