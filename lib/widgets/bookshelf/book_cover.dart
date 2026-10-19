import 'dart:io';
import 'dart:math' as math;

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/book.dart';
import 'package:flutter/material.dart';

class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.book,
    this.height,
    this.width,
    this.radius,
  });

  final Book book;
  final double? height;
  final double? width;
  final double? radius;

  // Calculate text color based on background brightness
  Color _getContrastColor(Color backgroundColor) {
    final brightness = ThemeData.estimateBrightnessForColor(backgroundColor);
    return brightness == Brightness.dark ? Colors.white : Colors.black;
  }

  @override
  Widget build(BuildContext context) {
    final double effectiveRadius = radius ?? 8;
    final BorderRadius borderRadius = BorderRadius.circular(effectiveRadius);
    final File file = File(book.coverFullPath);

    Widget child;

    if (file.existsSync()) {
      // Decode at the displayed size: full-resolution covers would cost memory and frames on big shelves.
      child = LayoutBuilder(builder: (context, constraints) {
        final logical = width ?? constraints.maxWidth;
        final cacheWidth = logical.isFinite
            ? (logical * MediaQuery.devicePixelRatioOf(context)).round()
            : null;
        return Image(
          image: ResizeImage.resizeIfNeeded(cacheWidth, null, FileImage(file)),
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        );
      });
    } else {
      // Default cover with responsive text and icon
      child = LayoutBuilder(
        builder: (context, constraints) {
          final coverWidth = constraints.maxWidth;

          // Calculate responsive sizes based on width
          final titleFontSize = coverWidth * 0.12;
          final authorFontSize = coverWidth * 0.08;
          final iconSize = coverWidth * 0.8;
          final padding = coverWidth * 0.08;

          final backgroundColor = Colors
              .primaries[book.title.hashCode % Colors.primaries.length]
              .shade200;
          final textColor = _getContrastColor(backgroundColor);

          final showTitle = Prefs().showBookTitleOnDefaultCover;
          final showAuthor = Prefs().showAuthorOnDefaultCover;

          return Container(
            color: backgroundColor,
            child: Stack(
              children: [
                // Text content (title at top, author at bottom)
                if (showTitle || showAuthor)
                  Padding(
                    padding: EdgeInsets.all(padding),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title at top
                        if (showTitle)
                          Text(
                            book.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: titleFontSize,
                              fontWeight: FontWeight.bold,
                              color: textColor,
                              height: 1.2,
                            ),
                          ),
                        const Spacer(),
                        // Author at bottom
                        if (showAuthor)
                          Text(
                            book.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: authorFontSize,
                              fontWeight: FontWeight.w300,
                              color: textColor,
                            ),
                          ),
                      ],
                    ),
                  ),
                // Icon at bottom right corner with rotation
                Positioned(
                  right: -padding * 0.8,
                  bottom: -padding * 0.5,
                  child: Transform.rotate(
                    angle: 15 * math.pi / 180, // 15 degrees in radians
                    child: Icon(
                      Icons.book,
                      size: iconSize,
                      color: textColor.withValues(alpha: 0.1),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }

    final RoundedSuperellipseBorder borderShape = RoundedSuperellipseBorder(
      borderRadius: borderRadius,
      side: BorderSide(
        width: 0.5,
        color: Theme.of(context).dividerColor.withValues(alpha: .6),
      ),
    );

    return SizedBox(
      height: height,
      width: width,
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(
          shape: borderShape,
        ),
        child: ClipRSuperellipse(
          borderRadius: borderRadius,
          child: child,
        ),
      ),
    );
  }
}
