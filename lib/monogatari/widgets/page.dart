import 'dart:math' as math;

import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

/// Width of grouped (settings-style) pages on tablets and desktops, including the groups' side padding.
const double mgReadableWidth = 752;

/// Width of detail pages on tablets; wide enough for a cover header and volume rows.
const double mgDetailWidth = 840;

/// Side inset that centres content no wider than [max]. Phones get zero and keep their layout.
double mgCenteredInset(BuildContext context, double max) =>
    math.max(0, (MediaQuery.sizeOf(context).width - max) / 2);

/// Centres [child] and caps its width; on phones the child keeps the full width.
class MgReadable extends StatelessWidget {
  const MgReadable({super.key, required this.child, this.maxWidth = mgReadableWidth});

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      );
}

/// The large title bar of root and detail pages: a 48dp action row above a 34sp bold title.
class MgPageTitle extends StatelessWidget {
  const MgPageTitle({
    super.key,
    required this.title,
    this.onBack,
    this.actions = const [],
    this.contentWidth,
    this.bottom,
  });

  final String title;
  final VoidCallback? onBack;
  final List<Widget> actions;

  /// Pages that centre their content on wide screens align the title with it.
  final double? contentWidth;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final inset = contentWidth == null ? 0.0 : mgCenteredInset(context, contentWidth!);
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: palette.page,
      child: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 48,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: IconTheme.merge(
                  data: IconThemeData(color: accent),
                  child: Row(
                    children: [
                      if (onBack != null)
                        IconButton(
                          icon: const Icon(Icons.arrow_back),
                          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                          onPressed: onBack,
                        ),
                      const Spacer(),
                      ...actions,
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20 + inset, 0, 20 + inset, 12),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 34,
                  height: 1.2,
                  fontWeight: FontWeight.bold,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            if (bottom != null) bottom!,
          ],
        ),
      ),
    );
  }
}

/// A page with the large title fixed on top. [grouped] pages sit on the gray grouped background.
class MgPage extends StatelessWidget {
  const MgPage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.grouped = false,
    this.showBack,
    this.contentWidth,
    this.header,
    this.floatingActionButton,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool grouped;

  /// Defaults to whether the route can pop.
  final bool? showBack;
  final double? contentWidth;

  /// Shown under the title on the title's background, e.g. a search field.
  final Widget? header;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final back = showBack ?? Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: grouped ? palette.grouped : palette.page,
      floatingActionButton: floatingActionButton,
      body: Column(
        children: [
          MgPageTitle(
            title: title,
            actions: actions,
            contentWidth: contentWidth,
            onBack: back ? () => Navigator.of(context).maybePop() : null,
            bottom: header,
          ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}

/// A pushed sub-page with a compact centred title, used for settings detail pages.
class MgSubPage extends StatelessWidget {
  const MgSubPage({
    super.key,
    required this.title,
    required this.body,
    this.actions = const [],
    this.grouped = true,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;
  final bool grouped;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final background = grouped ? palette.grouped : palette.page;
    return Scaffold(
      backgroundColor: background,
      appBar: AppBar(
        backgroundColor: background,
        title: Text(title),
        actions: actions,
      ),
      body: body,
    );
  }
}
