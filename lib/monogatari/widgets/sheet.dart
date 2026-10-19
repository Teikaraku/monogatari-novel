import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

/// Gray used for groups and chips inside a white sheet.
Color mgSheetGroupColor(BuildContext context) {
  final palette = MgPalette.of(context);
  return Theme.of(context).brightness == Brightness.dark ? palette.fill : MgColors.groupGray;
}

/// Opens the shared bottom sheet: drag handle, a title row with a round close button, scrolling content
/// and an optional button footer.
Future<T?> showMgSheet<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  List<Widget> actions = const [],
  required WidgetBuilder builder,
  WidgetBuilder? footer,
  bool scrollable = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (context) => MgSheet(
      title: title,
      subtitle: subtitle,
      actions: actions,
      footer: footer?.call(context),
      scrollable: scrollable,
      child: builder(context),
    ),
  );
}

class MgSheet extends StatelessWidget {
  const MgSheet({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
    this.footer,
    this.scrollable = true,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? footer;
  final bool scrollable;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    // The sheet rides above the keyboard so focused fields stay visible.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final maxHeight = (MediaQuery.sizeOf(context).height - keyboard) * .88;
    final content = Padding(
      padding: EdgeInsets.only(bottom: footer == null ? 20 + MediaQuery.paddingOf(context).bottom : 4),
      child: child,
    );
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 4),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: palette.separator,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 52),
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
                            ),
                            if (subtitle != null && subtitle!.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  subtitle!,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: palette.secondaryLabel),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    ...actions,
                    if (footer == null)
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Material(
                          color: mgSheetGroupColor(context),
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => Navigator.of(context).maybePop(),
                            child: SizedBox(
                              width: 30,
                              height: 30,
                              child: Icon(Icons.close, size: 17, color: palette.secondaryLabel),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Flexible(
              child: scrollable ? SingleChildScrollView(child: content) : content,
            ),
            if (footer != null)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: footer,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A titled block inside a sheet.
class MgSheetSection extends StatelessWidget {
  const MgSheetSection({super.key, required this.title, this.trailing, required this.child});

  final String title;
  final Widget? trailing;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.only(left: 20, right: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: MgPalette.of(context).secondaryLabel,
                        ),
                      ),
                    ),
                    if (trailing != null) trailing!,
                  ],
                ),
              ),
            ),
            child,
          ],
        ),
      );
}

/// Chips that wrap onto as many lines as they need.
class MgSheetChips extends StatelessWidget {
  const MgSheetChips({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Wrap(spacing: 8, runSpacing: 8, children: children),
      );
}

/// A pill choice. Selected chips use the accent tint; excluded ones (three-state filters) the error tint.
class MgChip extends StatelessWidget {
  const MgChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.excluded = false,
    this.checkmark = true,
    this.trailingIcon,
  });

  final String label;
  final bool selected;
  final bool excluded;
  final bool checkmark;
  final IconData? trailingIcon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = excluded ? scheme.error : scheme.primary;
    final active = selected || excluded;
    final enabled = onTap != null;
    final textColor = !enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : active
            ? accent
            : scheme.onSurface;
    return Material(
      color: active ? accent.withValues(alpha: .1) : mgSheetGroupColor(context),
      shape: StadiumBorder(
        side: active ? BorderSide(color: accent.withValues(alpha: .6)) : BorderSide.none,
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 56, minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (active && checkmark && trailingIcon == null) ...[
                  Icon(excluded ? Icons.close : Icons.check, size: 15, color: accent),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: active ? FontWeight.w500 : FontWeight.normal,
                      color: textColor,
                    ),
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 3),
                  Icon(trailingIcon, size: 16, color: active ? accent : MgPalette.of(context).secondaryLabel),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Rows on a rounded gray card inside a sheet, separated by hairlines.
class MgSheetGroup extends StatelessWidget {
  const MgSheetGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final separator = MgPalette.of(context).separator;
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      rows.add(children[i]);
      if (i < children.length - 1) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Divider(height: 0.5, thickness: 0.5, color: separator),
        ));
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: mgSheetGroupColor(context),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
        ),
      ),
    );
  }
}

/// One choice of a single or multiple selection inside a sheet group.
class MgSheetOption extends StatelessWidget {
  const MgSheetOption({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.multiple = false,
    this.textStyle,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final bool multiple;
  final VoidCallback? onTap;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = MgPalette.of(context);
    final enabled = onTap != null;
    final color = !enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : selected && !multiple
            ? scheme.primary
            : scheme.onSurface;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 50),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: (textStyle ?? const TextStyle()).copyWith(
                        fontSize: 16,
                        color: color,
                        fontWeight: selected && !multiple ? FontWeight.w500 : FontWeight.normal,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!, style: TextStyle(fontSize: 12, height: 1.35, color: palette.secondaryLabel)),
                  ],
                ),
              ),
              if (multiple)
                Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 22, color: selected ? scheme.primary : scheme.outline)
              else if (selected)
                Icon(Icons.check, size: 20, color: scheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}

/// One command of an action list inside a sheet group.
class MgSheetAction extends StatelessWidget {
  const MgSheetAction({
    super.key,
    required this.title,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final bool destructive;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final tint = !enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : destructive
            ? scheme.error
            : scheme.primary;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 50),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(icon, size: 22, color: tint),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        color: destructive && enabled
                            ? scheme.error
                            : scheme.onSurface.withValues(alpha: enabled ? 1 : .38),
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty)
                      Text(subtitle!, style: TextStyle(fontSize: 12, color: MgPalette.of(context).secondaryLabel)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Footer buttons of a sheet or dialog: a quiet secondary button and a filled accent button.
class MgSheetButtons extends StatelessWidget {
  const MgSheetButtons({
    super.key,
    this.secondary,
    this.onSecondary,
    required this.primary,
    required this.onPrimary,
  });

  final String? secondary;
  final VoidCallback? onSecondary;
  final String primary;
  final VoidCallback? onPrimary;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          if (secondary != null) ...[
            Expanded(
              child: OutlinedButton(onPressed: onSecondary, child: Text(secondary!)),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(child: FilledButton(onPressed: onPrimary, child: Text(primary))),
        ],
      );
}
