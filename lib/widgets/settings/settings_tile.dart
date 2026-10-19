import 'package:anx_reader/monogatari/ui.dart';
import 'package:flutter/material.dart';

abstract class AbstractSettingsTile extends StatelessWidget {
  const AbstractSettingsTile({super.key});
}

enum SettingsTileType { simpleTile, switchTile, navigationTile }

class SettingsTile extends AbstractSettingsTile {
  SettingsTile({
    this.leading,
    this.trailing,
    this.value,
    required this.title,
    this.description,
    this.onPressed,
    this.enabled = true,
    super.key,
  }) {
    onToggle = null;
    initialValue = null;
    activeSwitchColor = null;
    tileType = SettingsTileType.simpleTile;
  }

  SettingsTile.navigation({
    this.leading,
    this.trailing,
    this.value,
    required this.title,
    this.description,
    this.onPressed,
    this.enabled = true,
    super.key,
  }) {
    onToggle = null;
    initialValue = null;
    activeSwitchColor = null;
    tileType = SettingsTileType.navigationTile;
  }

  SettingsTile.switchTile({
    required this.initialValue,
    required this.onToggle,
    this.activeSwitchColor,
    this.leading,
    this.trailing,
    required this.title,
    this.description,
    this.onPressed,
    this.enabled = true,
    super.key,
  }) {
    value = null;
    tileType = SettingsTileType.switchTile;
  }

  /// The widget at the beginning of the tile
  final Widget? leading;

  /// The Widget at the end of the tile
  final Widget? trailing;

  /// The widget at the center of the tile
  final Widget title;

  /// The widget at the bottom of the [title]
  final Widget? description;

  /// A function that is called by tap on a tile
  final Function(BuildContext context)? onPressed;

  late final Color? activeSwitchColor;
  late final Widget? value;
  late final Function(bool value)? onToggle;
  late final SettingsTileType tileType;
  late final bool? initialValue;
  late final bool enabled;

  @override
  Widget build(BuildContext context) {
    return AndroidSettingsTile(
      description: description,
      onPressed: onPressed,
      onToggle: onToggle,
      tileType: tileType,
      value: value,
      leading: leading,
      title: title,
      enabled: enabled,
      activeSwitchColor: activeSwitchColor,
      initialValue: initialValue ?? false,
      trailing: trailing,
    );
  }
}

/// Settings row in the 物语 grouped-list style: accent leading icon, 16sp title, gray description,
/// the value on the trailing edge and a chevron for navigation rows.
class AndroidSettingsTile extends StatelessWidget {
  const AndroidSettingsTile({
    required this.tileType,
    required this.leading,
    required this.title,
    required this.description,
    required this.onPressed,
    required this.onToggle,
    required this.value,
    required this.initialValue,
    required this.activeSwitchColor,
    required this.enabled,
    required this.trailing,
    super.key,
  });

  final SettingsTileType tileType;
  final Widget? leading;
  final Widget? title;
  final Widget? description;
  final Function(BuildContext context)? onPressed;
  final Function(bool value)? onToggle;
  final Widget? value;
  final bool initialValue;
  final bool enabled;
  final Color? activeSwitchColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final isSwitch = tileType == SettingsTileType.switchTile;
    final tappable = isSwitch ? onToggle != null || onPressed != null : onPressed != null;
    final alpha = enabled ? 1.0 : .45;
    final secondary = TextStyle(
      fontSize: 12,
      height: 1.45,
      color: palette.secondaryLabel.withValues(alpha: alpha),
    );
    final detail = value ?? description;

    return IgnorePointer(
      ignoring: !enabled,
      child: InkWell(
        onTap: tappable
            ? () {
                if (isSwitch) {
                  onToggle?.call(!initialValue);
                } else {
                  onPressed?.call(context);
                }
              }
            : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 50),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                if (leading != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(
                      size: 22,
                      color: scheme.primary.withValues(alpha: alpha),
                    ),
                    child: leading!,
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      DefaultTextStyle.merge(
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w400,
                          color: scheme.onSurface.withValues(alpha: alpha),
                        ),
                        child: title ?? const SizedBox.shrink(),
                      ),
                      if (detail != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: DefaultTextStyle.merge(style: secondary, child: detail),
                        ),
                    ],
                  ),
                ),
                if (trailing != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: trailing!,
                  ),
                if (isSwitch)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Switch(
                      value: initialValue,
                      onChanged: onToggle,
                      activeTrackColor: enabled ? activeSwitchColor : null,
                    ),
                  )
                else if (tileType == SettingsTileType.navigationTile &&
                    trailing == null)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.chevron_right,
                      color: palette.secondaryLabel.withValues(alpha: .7 * alpha),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CustomSettingsTile extends AbstractSettingsTile {
  const CustomSettingsTile({
    required this.child,
    super.key,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
