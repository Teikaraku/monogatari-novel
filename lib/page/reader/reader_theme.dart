import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:flutter/material.dart';

Color readerHex(String value, Color fallback) => Color(int.tryParse(value, radix: 16) ?? fallback.toARGB32());

/// The reader's controls take their colours from the reading theme, so a sepia page gets a
/// sepia toolbar and a dark page a dark one. The accent stays the app's.
ThemeData readerChromeTheme(BuildContext context, ReadTheme readTheme) {
  final base = Theme.of(context);
  final background = readerHex(readTheme.backgroundColor, const Color(0xFFFBFBF3));
  final text = readerHex(readTheme.textColor, const Color(0xFF343434));
  final dark = ThemeData.estimateBrightnessForColor(background) == Brightness.dark;
  final tint = dark ? Colors.white : Colors.black;
  Color shade(double alpha) => Color.alphaBlend(tint.withValues(alpha: alpha), background);

  final panel = shade(.03);
  final palette = MgPalette.of(context).copyWith(
    page: panel,
    grouped: panel,
    card: shade(dark ? .08 : .0),
    fill: shade(.07),
    secondaryLabel: text.withValues(alpha: .55),
    separator: text.withValues(alpha: .12),
    menu: shade(dark ? .1 : .0),
    menuBand: shade(.06),
  );
  return base.copyWith(
    brightness: dark ? Brightness.dark : Brightness.light,
    colorScheme: base.colorScheme.copyWith(
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: panel,
      onSurface: text,
      surfaceContainerHighest: shade(.07),
    ),
    scaffoldBackgroundColor: panel,
    canvasColor: panel,
    drawerTheme: base.drawerTheme.copyWith(backgroundColor: panel, surfaceTintColor: Colors.transparent),
    tabBarTheme: base.tabBarTheme.copyWith(
      labelColor: base.colorScheme.primary,
      unselectedLabelColor: text.withValues(alpha: .55),
      dividerColor: Colors.transparent,
    ),
    dividerColor: text.withValues(alpha: .12),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      fillColor: shade(.07),
      hintStyle: TextStyle(color: text.withValues(alpha: .45)),
    ),
    sliderTheme: base.sliderTheme.copyWith(inactiveTrackColor: text.withValues(alpha: .15)),
    textSelectionTheme: base.textSelectionTheme.copyWith(cursorColor: base.colorScheme.primary),
    iconTheme: IconThemeData(color: text),
    textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
    extensions: [
      ...base.extensions.values.where((e) => e is! MgPalette),
      palette,
    ],
  );
}

/// Whether a reading theme has a dark page.
bool isDarkReadTheme(ReadTheme theme) =>
    ThemeData.estimateBrightnessForColor(readerHex(theme.backgroundColor, Colors.white)) == Brightness.dark;
