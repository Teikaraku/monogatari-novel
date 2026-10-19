import 'package:flutter/widgets.dart';

/// Product names in one place: 物语 in Chinese UI, Monogatari elsewhere.
abstract final class MgBrand {
  static const zh = '物语';
  static const en = 'Monogatari';

  static String name(BuildContext context) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
}
