import 'package:anx_reader/monogatari/ui.dart';
import 'package:flutter/material.dart';

/// A settings category page: the large title over its grouped sections.
/// On the wide two-pane layout ([isMobile] false) only the sections are shown.
class SettingsPageBody extends StatelessWidget {
  const SettingsPageBody({
    super.key,
    required this.title,
    required this.isMobile,
    required this.sections,
  });

  final String title;
  final bool isMobile;
  final Widget sections;

  @override
  Widget build(BuildContext context) {
    if (!isMobile) {
      return ColoredBox(color: MgPalette.of(context).grouped, child: sections);
    }
    return MgPage(
      title: title,
      grouped: true,
      contentWidth: mgReadableWidth,
      body: sections,
    );
  }
}
