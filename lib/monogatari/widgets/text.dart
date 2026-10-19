import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

/// Body text clamped to [maxLines] with a "more" link that expands it in place.
class MgExpandableText extends StatefulWidget {
  const MgExpandableText(this.text, {super.key, this.maxLines = 4});

  final String text;
  final int maxLines;

  @override
  State<MgExpandableText> createState() => _MgExpandableTextState();
}

class _MgExpandableTextState extends State<MgExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(fontSize: 15, height: 1.6, color: Theme.of(context).colorScheme.onSurface);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: widget.text, style: style),
        maxLines: widget.maxLines,
        textDirection: Directionality.of(context),
      )..layout(maxWidth: constraints.maxWidth);
      final overflows = painter.didExceedMaxLines;
      return GestureDetector(
        onTap: overflows ? () => setState(() => _expanded = !_expanded) : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.text,
                style: style,
                maxLines: _expanded ? null : widget.maxLines,
                overflow: _expanded ? null : TextOverflow.ellipsis),
            if (overflows && !_expanded)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(L10n.of(context).storeMore,
                    style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.primary)),
              ),
          ],
        ),
      );
    });
  }
}

/// "3 时 20 分", or minutes alone under an hour.
String mgDuration(L10n l10n, int seconds) {
  final hours = seconds ~/ 3600;
  final minutes = seconds % 3600 ~/ 60;
  if (hours == 0) return l10n.commonMinutes(minutes);
  if (hours >= 100) return l10n.commonHours(hours);
  return '${l10n.commonHours(hours)} ${l10n.commonMinutes(minutes)}';
}

/// A figure with large bold digits and small gray units: "3 时 20 分", "12 本".
class MgFigure extends StatelessWidget {
  const MgFigure(this.text, {super.key, this.size = 22});

  final String text;
  final double size;

  @override
  Widget build(BuildContext context) {
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final unit = TextStyle(fontSize: size * .55, color: MgPalette.of(context).secondaryLabel);
    final digit = TextStyle(fontSize: size, fontWeight: FontWeight.bold, color: onSurface);
    final parts = RegExp(r'\d+(?:\.\d+)?|[^\d]+').allMatches(text).map((m) => m.group(0)!).toList();
    // Units sit a small space away from the digits on either side: "3 时 20 分", "12 本".
    return Text.rich(
      TextSpan(children: [
        for (var i = 0; i < parts.length; i++)
          RegExp(r'^\d').hasMatch(parts[i])
              ? TextSpan(text: parts[i], style: digit)
              : TextSpan(
                  text: '${i > 0 ? ' ' : ''}${parts[i].trim()}${i < parts.length - 1 ? ' ' : ''}',
                  style: unit,
                ),
      ]),
      maxLines: 1,
      overflow: TextOverflow.fade,
      softWrap: false,
    );
  }
}
