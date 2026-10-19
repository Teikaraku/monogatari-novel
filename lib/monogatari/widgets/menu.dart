import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

sealed class MgMenuEntry {
  const MgMenuEntry();
}

/// A small caption above the rows of a section.
class MgMenuHeader extends MgMenuEntry {
  const MgMenuHeader(this.title);

  final String title;
}

/// A command. A non-null [checked] turns its section into a picker with a leading checkmark column.
class MgMenuAction extends MgMenuEntry {
  const MgMenuAction({
    required this.title,
    required this.onTap,
    this.icon,
    this.checked,
    this.destructive = false,
    this.enabled = true,
  });

  final String title;
  final IconData? icon;
  final bool? checked;
  final bool destructive;
  final bool enabled;
  final VoidCallback onTap;
}

/// Replaces the menu's content with its own sections and a back row, instead of opening a second popup.
class MgMenuSubmenu extends MgMenuEntry {
  const MgMenuSubmenu({required this.title, required this.sections, this.value, this.icon});

  final String title;
  final String? value;
  final IconData? icon;
  final List<List<MgMenuEntry>> sections;
}

typedef MgMenuOpener = void Function([Offset? position]);

/// iOS-style pull-down menu: grouped sections divided by a thick band, symbols on the trailing edge,
/// red destructive items and in-place submenus. [sections] is built only when the menu opens.
class MgMenu extends StatefulWidget {
  const MgMenu({super.key, required this.sections, required this.builder});

  final List<List<MgMenuEntry>> Function() sections;
  final Widget Function(BuildContext context, MgMenuOpener open) builder;

  @override
  State<MgMenu> createState() => _MgMenuState();
}

const _menuWidth = 250.0;

class _MgMenuState extends State<MgMenu> {
  final _controller = MenuController();

  /// Menus opened from the right half hang from the anchor's right edge instead of overflowing.
  bool _alignEnd = false;

  /// While open, the system back gesture closes the menu instead of leaving the page.
  bool _isOpen = false;

  void _open([Offset? position]) {
    if (_controller.isOpen) {
      _controller.close();
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final alignEnd = position == null &&
        box != null &&
        box.localToGlobal(box.size.center(Offset.zero)).dx > MediaQuery.sizeOf(context).width / 2;
    if (alignEnd != _alignEnd) setState(() => _alignEnd = alignEnd);
    _controller.open(position: position);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !_isOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _controller.close();
        },
        child: MenuAnchor(
          controller: _controller,
          style: _alignEnd ? const MenuStyle(alignment: AlignmentDirectional.bottomEnd) : null,
          alignmentOffset: _alignEnd ? const Offset(-_menuWidth, 4) : const Offset(0, 4),
          consumeOutsideTap: true,
          onOpen: () => setState(() => _isOpen = true),
          onClose: () {
            if (mounted) setState(() => _isOpen = false);
          },
          menuChildren: [
            _MenuBody(sections: widget.sections, close: _controller.close),
          ],
          builder: (context, controller, _) => widget.builder(context, _open),
        ),
      );
}

/// An icon button that opens an [MgMenu].
class MgMenuButton extends StatelessWidget {
  const MgMenuButton({
    super.key,
    required this.sections,
    this.icon = Icons.more_horiz,
    this.tooltip,
  });

  final List<List<MgMenuEntry>> Function() sections;
  final IconData icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) => MgMenu(
        sections: sections,
        builder: (context, open) => IconButton(
          icon: Icon(icon, color: Theme.of(context).colorScheme.primary),
          tooltip: tooltip,
          onPressed: () => open(),
        ),
      );
}

class _MenuBody extends StatefulWidget {
  const _MenuBody({required this.sections, required this.close});

  final List<List<MgMenuEntry>> Function() sections;
  final VoidCallback close;

  @override
  State<_MenuBody> createState() => _MenuBodyState();
}

class _MenuBodyState extends State<_MenuBody> {
  late final List<List<MgMenuEntry>> _root = widget.sections();
  final _path = <MgMenuSubmenu>[];

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final current = _path.isEmpty ? null : _path.last;
    final sections =
        (current?.sections ?? _root).where((section) => section.isNotEmpty).toList();
    final children = <Widget>[];
    if (current != null) {
      children.add(InkWell(
        onTap: () => setState(_path.removeLast),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Icon(Icons.chevron_left, size: 20, color: palette.secondaryLabel),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    current.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ));
      children.add(_band(palette));
    }
    for (var s = 0; s < sections.length; s++) {
      if (s > 0) children.add(_band(palette));
      final section = sections[s];
      final picker = section.any((entry) => entry is MgMenuAction && entry.checked != null);
      for (var r = 0; r < section.length; r++) {
        final entry = section[r];
        if (r > 0 && section[r - 1] is! MgMenuHeader) {
          children.add(Divider(
              height: 0.5, thickness: 0.5, color: palette.separator.withValues(alpha: .7)));
        }
        children.add(switch (entry) {
          MgMenuHeader() => Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 6),
              child: Text(entry.title,
                  style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
            ),
          MgMenuAction() => _actionRow(entry, picker, scheme),
          MgMenuSubmenu() => _submenuRow(entry, palette),
        });
      }
    }
    return SizedBox(
      width: _menuWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _band(MgPalette palette) => Container(height: 8, color: palette.menuBand);

  Widget _actionRow(MgMenuAction action, bool picker, ColorScheme scheme) {
    final color = !action.enabled
        ? scheme.onSurface.withValues(alpha: .38)
        : action.destructive
            ? scheme.error
            : scheme.onSurface;
    return InkWell(
      onTap: action.enabled
          ? () {
              widget.close();
              action.onTap();
            }
          : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: EdgeInsets.only(left: picker ? 10 : 16, right: 16),
          child: Row(
            children: [
              if (picker)
                SizedBox(
                  width: 26,
                  child: action.checked == true
                      ? Icon(Icons.check, size: 18, color: color)
                      : null,
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(action.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: color)),
                ),
              ),
              if (action.icon != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Icon(action.icon, size: 20, color: color),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _submenuRow(MgMenuSubmenu menu, MgPalette palette) => InkWell(
        onTap: () => setState(() => _path.add(menu)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.only(left: 16, right: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(menu.title, style: const TextStyle(fontSize: 16)),
                      if (menu.value != null)
                        Text(menu.value!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
                    ],
                  ),
                ),
                if (menu.icon != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(menu.icon, size: 20),
                  ),
                Icon(Icons.chevron_right, size: 20, color: palette.secondaryLabel),
              ],
            ),
          ),
        ),
      );
}
