import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/reader/reader_theme.dart';
import 'package:flutter/material.dart';

/// Building blocks of the reader overlay. They read their colours from the reader theme
/// (see `readerChromeTheme`), so they match the page underneath.

/// A floating rounded card with a soft shadow.
class ReaderCard extends StatelessWidget {
  const ReaderCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 560),
      padding: padding,
      decoration: BoxDecoration(
        color: MgPalette.of(context).page,
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(color: Color(0x24000000), blurRadius: 28, offset: Offset(0, 8)),
          BoxShadow(color: Color(0x0F000000), blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
        child: child,
      ),
    );
  }
}

/// A round floating button, used for back.
class ReaderRoundButton extends StatelessWidget {
  const ReaderRoundButton({super.key, required this.icon, required this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = Material(
      color: MgPalette.of(context).page,
      shape: const CircleBorder(),
      elevation: 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, size: 22, color: Theme.of(context).colorScheme.onSurface),
        ),
      ),
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: Color(0x1F000000), blurRadius: 16, offset: Offset(0, 4))],
      ),
      child: tooltip == null ? button : Tooltip(message: tooltip!, child: button),
    );
  }
}

/// A floating capsule holding a few icon buttons.
class ReaderCapsule extends StatelessWidget {
  const ReaderCapsule({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: MgPalette.of(context).page,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x1F000000), blurRadius: 16, offset: Offset(0, 4))],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

class ReaderCapsuleButton extends StatelessWidget {
  const ReaderCapsuleButton({super.key, required this.icon, required this.onTap, this.active = false});

  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: SizedBox(
        width: 40,
        height: 44,
        child: Icon(icon, size: 22, color: active ? scheme.primary : scheme.onSurface),
      ),
    );
  }
}

/// A labelled tool in the bottom card.
class ReaderToolButton extends StatelessWidget {
  const ReaderToolButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final palette = MgPalette.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: active ? scheme.primary : scheme.onSurface),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(fontSize: 11, color: active ? scheme.primary : palette.secondaryLabel)),
          ],
        ),
      ),
    );
  }
}

/// Panel header: a title and a close button.
class ReaderPanelHeader extends StatelessWidget {
  const ReaderPanelHeader({super.key, required this.title, required this.onClose, this.trailing});

  final String title;
  final VoidCallback onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return Row(
      children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
        if (trailing != null) trailing!,
        const SizedBox(width: 6),
        Material(
          color: palette.fill,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onClose,
            child: SizedBox(
              width: 30,
              height: 30,
              child: Icon(Icons.keyboard_arrow_down, size: 20, color: palette.secondaryLabel),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small gray caption above a control.
class ReaderLabel extends StatelessWidget {
  const ReaderLabel(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(text, style: TextStyle(fontSize: 12, color: MgPalette.of(context).secondaryLabel)),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      );
}

/// A row of equal options; the selected one is raised. [selected] may be null when the
/// current value matches none of them.
class ReaderChoiceRow<T> extends StatelessWidget {
  const ReaderChoiceRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.height = 40,
  });

  final List<(T, Widget)> options;
  final T? selected;
  final ValueChanged<T> onSelected;
  final double height;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: palette.fill, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          for (final (value, child) in options)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelected(value),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: value == selected
                        ? (dark ? Color.alphaBlend(Colors.white.withValues(alpha: .14), palette.fill) : palette.card)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(9),
                    boxShadow: value == selected && !dark
                        ? const [BoxShadow(color: Color(0x1A000000), blurRadius: 4, offset: Offset(0, 1))]
                        : null,
                  ),
                  child: IconTheme.merge(
                    data: IconThemeData(
                      size: 20,
                      color: value == selected ? scheme.primary : scheme.onSurface.withValues(alpha: .75),
                    ),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: value == selected ? FontWeight.w600 : FontWeight.w500,
                        color: value == selected ? scheme.primary : scheme.onSurface,
                      ),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A row in a reader panel that opens something: label, current value, chevron.
class ReaderLinkRow extends StatelessWidget {
  const ReaderLinkRow({super.key, required this.icon, required this.title, required this.onTap, this.value});

  final IconData icon;
  final String title;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return Material(
      color: palette.fill,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .8)),
                const SizedBox(width: 10),
                Text(title, style: const TextStyle(fontSize: 14)),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    value ?? '',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                  ),
                ),
                Icon(Icons.chevron_right, size: 20, color: palette.secondaryLabel),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A bottom sheet in the reader's colours.
Future<T?> showReaderSheet<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  WidgetBuilder? footer,
  bool scrollable = true,
  double? height,
}) {
  final theme = readerChromeTheme(context, Prefs().readTheme);
  final palette = theme.extension<MgPalette>()!;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: palette.page,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (_) => Theme(
      data: theme,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: Builder(builder: (context) {
          final sheet = MgSheet(
            title: title,
            footer: footer?.call(context),
            scrollable: scrollable,
            child: builder(context),
          );
          return height == null ? sheet : SizedBox(height: height, child: sheet);
        }),
      ),
    ),
  );
}
