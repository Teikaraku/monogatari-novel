import 'package:anx_reader/constants/note_annotations.dart';
import 'package:anx_reader/models/book_note.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/utils/time_to_human.dart';
import 'package:flutter/material.dart';

/// A note or highlight: the excerpt behind a bar in the note's colour, the reader's own
/// comment in an inset bubble, then type, chapter and time.
class BookNoteTile extends StatelessWidget {
  const BookNoteTile({
    super.key,
    required this.note,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.backgroundColor,
    this.margin = const EdgeInsets.only(bottom: 10),
  });

  final BookNote note;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final Widget? trailing;
  final Color? backgroundColor;
  final EdgeInsetsGeometry margin;

  IconData get _icon {
    final match = notesType.where((option) => option.type == note.type);
    return match.isNotEmpty ? match.first.icon : Icons.bookmark;
  }

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final color = Color(int.tryParse('0xff${note.color}') ?? 0xff8e8e93);
    final comment = note.readerNote?.trim() ?? '';
    final meta = TextStyle(fontSize: 12, color: palette.secondaryLabel);

    return Padding(
      padding: margin,
      child: Material(
        color: backgroundColor ?? mgSheetGroupColor(context),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              width: 3,
                              decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                note.content,
                                style: TextStyle(
                                  fontSize: 15,
                                  height: 1.6,
                                  color: Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (comment.isNotEmpty)
                        Container(
                          margin: const EdgeInsets.only(top: 10),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                          decoration: BoxDecoration(
                            color: palette.card,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(comment, style: const TextStyle(fontSize: 14, height: 1.5)),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Icon(_icon, size: 14, color: color),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              note.chapter,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: meta,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(timeToHuman(note.createTime), style: meta),
                        ],
                      ),
                    ],
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
