import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

/// Defines a single segment item used by [AnxSegmentedButton].
class SegmentButtonItem<T> {
  const SegmentButtonItem({
    required this.value,
    required this.label,
    this.icon,
    this.labelStyle,
    this.maxLines,
    this.overflow,
  });

  final T value;
  final String label;
  final Widget? icon;
  final TextStyle? labelStyle;
  final int? maxLines;
  final TextOverflow? overflow;
}

/// The 物语 segmented control: equal segments on a gray track, the selected ones raised as
/// white pills. Keeps the [SegmentedButton]-style API used across settings.
class AnxSegmentedButton<T> extends StatelessWidget {
  const AnxSegmentedButton({
    super.key,
    required this.segments,
    required this.selected,
    this.onSelectionChanged,
    this.multiSelectionEnabled = false,
    this.emptySelectionAllowed = false,
    this.showSelectedIcon = true,
    this.enabled = true,
    this.style,
  });

  final List<SegmentButtonItem<T>> segments;
  final Set<T> selected;
  final ValueChanged<Set<T>>? onSelectionChanged;
  final bool multiSelectionEnabled;
  final bool emptySelectionAllowed;

  /// Kept for API compatibility; the selected pill is the indicator.
  final bool showSelectedIcon;

  /// Kept for API compatibility; the control draws its own style.
  final ButtonStyle? style;
  final bool enabled;

  void _tap(T value) {
    final next = {...selected};
    if (multiSelectionEnabled) {
      if (!next.remove(value)) next.add(value);
    } else if (next.contains(value)) {
      if (!emptySelectionAllowed) return;
      next.clear();
    } else {
      next
        ..clear()
        ..add(value);
    }
    if (next.isEmpty && !emptySelectionAllowed) return;
    onSelectionChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final active = enabled && onSelectionChanged != null;
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return Opacity(
      opacity: active ? 1 : .45,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(color: palette.fill, borderRadius: BorderRadius.circular(10)),
        child: Row(
          children: [
            for (final segment in segments)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: active ? () => _tap(segment.value) : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    constraints: const BoxConstraints(minHeight: 34),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                    decoration: BoxDecoration(
                      color: selected.contains(segment.value)
                          ? (dark ? const Color(0xFF636366) : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: selected.contains(segment.value) && !dark
                          ? const [BoxShadow(color: Color(0x1F000000), blurRadius: 4, offset: Offset(0, 1))]
                          : null,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (segment.icon != null) ...[
                          IconTheme.merge(
                            data: IconThemeData(size: 16, color: onSurface.withValues(alpha: .8)),
                            child: segment.icon!,
                          ),
                          const SizedBox(width: 5),
                        ],
                        Flexible(
                          child: Text(
                            segment.label,
                            softWrap: false,
                            maxLines: segment.maxLines ?? 1,
                            overflow: segment.overflow ?? TextOverflow.fade,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: selected.contains(segment.value) ? FontWeight.w600 : FontWeight.w500,
                              color: onSurface,
                            ).merge(segment.labelStyle),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
