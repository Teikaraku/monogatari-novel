import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Shelf layout shared by the bookstore: phones keep three columns; wide windows use one centred column
/// capped at 1120 with six columns, so every shelf lines up on both edges.
class MgShelfMetrics {
  MgShelfMetrics._(this.width);

  factory MgShelfMetrics.of(BuildContext context) =>
      MgShelfMetrics._(MediaQuery.sizeOf(context).width);

  final double width;

  bool get wide => width >= 600;
  double get content => wide ? math.min(width - 40, 1120) : math.max(width - 40, 0);
  double get inset => math.max((width - content) / 2, 20);
  int get columns => wide ? 6 : 3;
  double span(int count, [double gap = 12]) => (content - gap * (count - 1)) / count;
}

/// Section header: a short accent bar, a bold title and an optional "more" link.
class MgShelfHeader extends StatelessWidget {
  const MgShelfHeader(
      {super.key, required this.title, this.moreLabel, this.moreIcon = Icons.chevron_right, this.onMore});

  final String title;
  final String? moreLabel;
  final IconData moreIcon;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final metrics = MgShelfMetrics.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: EdgeInsets.only(
          left: metrics.inset, right: metrics.inset - 12, top: 18, bottom: 8),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 19,
            decoration: BoxDecoration(
              color: accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          ),
          if (onMore != null)
            TextButton(
              onPressed: onMore,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.only(left: 12, right: 4)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(moreLabel ?? MaterialLocalizations.of(context).moreButtonTooltip,
                      style: const TextStyle(fontSize: 14)),
                  const SizedBox(width: 2),
                  Icon(moreIcon, size: moreIcon == Icons.chevron_right ? 18 : 16),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A round-cornered tinted icon over a short label, for the bookstore's shortcut row.
class MgShortcut extends StatelessWidget {
  const MgShortcut({super.key, required this.title, required this.icon, required this.onTap});

  final String title;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, size: 23, color: accent),
            ),
            const SizedBox(height: 7),
            Text(title, maxLines: 1, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
