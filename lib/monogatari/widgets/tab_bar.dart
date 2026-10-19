import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

class MgTabItem {
  const MgTabItem({required this.icon, required this.activeIcon, required this.label});

  final IconData icon;
  final IconData activeIcon;
  final String label;
}

/// The bottom tab bar: a hairline over equal-width icon-and-label items, the current one in the accent.
class MgTabBar extends StatelessWidget {
  const MgTabBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
  });

  final List<MgTabItem> items;
  final int currentIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: palette.page,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Divider(height: 0.5, thickness: 0.5, color: palette.separator),
            SizedBox(
              height: 56,
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: Semantics(
                        selected: i == currentIndex,
                        button: true,
                        label: items[i].label,
                        child: InkResponse(
                          onTap: () => onTap(i),
                          containedInkWell: true,
                          highlightShape: BoxShape.rectangle,
                          child: ExcludeSemantics(
                            child: _TabItem(
                              item: items[i],
                              selected: i == currentIndex,
                              color: i == currentIndex ? accent : palette.secondaryLabel,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({required this.item, required this.selected, required this.color});

  final MgTabItem item;
  final bool selected;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(selected ? item.activeIcon : item.icon, size: 25, color: color),
          const SizedBox(height: 3),
          Text(
            item.label,
            maxLines: 1,
            style: TextStyle(fontSize: 10, color: color, height: 1.1),
          ),
        ],
      );
}
