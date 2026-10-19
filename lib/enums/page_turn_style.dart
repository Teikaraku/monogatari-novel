import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:flutter/widgets.dart';

enum PageTurn {
  noAnimation,
  slide,
  scroll;

  String getLabel(BuildContext context) => switch (this) {
        PageTurn.noAnimation => L10n.of(context).noAnimation,
        PageTurn.slide => L10n.of(context).slide,
        PageTurn.scroll => L10n.of(context).scroll,
      };
}
