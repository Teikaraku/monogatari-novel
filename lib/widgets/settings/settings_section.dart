import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/widgets/settings/settings_tile.dart';
import 'package:flutter/material.dart';

abstract class AbstractSettingsSection extends StatelessWidget {
  const AbstractSettingsSection({super.key});
}

/// A grouped card of settings rows with a gray caption, in the 物语 grouped-list style.
class SettingsSection extends AbstractSettingsSection {
  const SettingsSection({
    super.key,
    required this.tiles,
    this.margin,
    this.title,
  });

  final List<AbstractSettingsTile> tiles;
  final EdgeInsetsDirectional? margin;
  final Widget? title;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < tiles.length; i++) {
      rows.add(tiles[i]);
      if (i < tiles.length - 1) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Divider(height: 0.5, thickness: 0.5, color: palette.separator),
        ));
      }
    }
    return MgReadable(
      child: Padding(
        padding: margin ?? const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 7),
                child: DefaultTextStyle.merge(
                  style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                  child: title!,
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Material(
                color: palette.card,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CustomSettingsSection extends AbstractSettingsSection {
  const CustomSettingsSection({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
