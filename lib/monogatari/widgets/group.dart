import 'package:anx_reader/monogatari/theme.dart';
import 'package:anx_reader/monogatari/widgets/page.dart';
import 'package:flutter/material.dart';

/// Rows on a rounded card with an optional caption above and footnote below, like iOS grouped lists.
class MgGroup extends StatelessWidget {
  const MgGroup({
    super.key,
    this.title,
    this.footer,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.color,
  });

  final String? title;
  final String? footer;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) rows.add(const _RowSeparator());
    }
    return MgReadable(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null && title!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 7),
                child: Text(
                  title!,
                  style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                ),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Material(
                color: color ?? palette.card,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: rows,
                ),
              ),
            ),
            if (footer != null && footer!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, top: 7),
                child: Text(
                  footer!,
                  style: TextStyle(
                      fontSize: 13, height: 1.4, color: palette.secondaryLabel),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RowSeparator extends StatelessWidget {
  const _RowSeparator();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Divider(height: 0.5, thickness: 0.5, color: MgPalette.of(context).separator),
      );
}

/// The colored rounded square that carries a settings icon.
class MgIconTile extends StatelessWidget {
  const MgIconTile({super.key, required this.icon, this.color = MgColors.pink, this.size = 29});

  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(size * 7 / 29),
        ),
        alignment: Alignment.center,
        child: Icon(icon, size: size * 20 / 29, color: Colors.white),
      );
}

/// One row of a group: optional icon tile, title, subtitle, a trailing value and a chevron when tappable.
class MgRow extends StatelessWidget {
  const MgRow({
    super.key,
    required this.title,
    this.icon,
    this.iconColor = MgColors.pink,
    this.leading,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.enabled = true,
    this.destructive = false,
    this.showChevron,
    this.titleColor,
  });

  final String title;
  final IconData? icon;
  final Color iconColor;
  final Widget? leading;
  final String? subtitle;
  final String? value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool enabled;
  final bool destructive;
  final bool? showChevron;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final alpha = enabled ? 1.0 : .5;
    final chevron = showChevron ?? (onTap != null && trailing == null);
    final lead = leading ?? (icon == null ? null : MgIconTile(icon: icon!, color: iconColor));
    return InkWell(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 50),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: Row(
            children: [
              if (lead != null) ...[
                Opacity(opacity: alpha, child: lead),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        color: (destructive ? scheme.error : titleColor ?? scheme.onSurface)
                            .withValues(alpha: alpha),
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.45,
                            color: palette.secondaryLabel.withValues(alpha: alpha),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (value != null && value!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      value!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: palette.secondaryLabel.withValues(alpha: alpha),
                      ),
                    ),
                  ),
                ),
              if (trailing != null)
                Padding(padding: const EdgeInsets.only(left: 8), child: trailing!),
              if (chevron)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Icon(Icons.chevron_right, color: palette.secondaryLabel.withValues(alpha: .7)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A row whose trailing control is a switch; tapping anywhere on the row toggles it.
class MgSwitchRow extends StatelessWidget {
  const MgSwitchRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.icon,
    this.iconColor = MgColors.pink,
    this.subtitle,
    this.enabled = true,
  });

  final String title;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final IconData? icon;
  final Color iconColor;
  final String? subtitle;
  final bool enabled;

  @override
  Widget build(BuildContext context) => MgRow(
        title: title,
        icon: icon,
        iconColor: iconColor,
        subtitle: subtitle,
        enabled: enabled && onChanged != null,
        onTap: onChanged == null ? null : () => onChanged!(!value),
        trailing: Switch(value: value, onChanged: enabled ? onChanged : null),
      );
}
