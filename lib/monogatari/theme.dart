import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:chinese_font_library/chinese_font_library.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// The 物语 palette, shared with the manga and anime apps: system pink on iOS system grays.
abstract final class MgColors {
  static const pink = Color(0xFFFF2D55);
  static const blue = Color(0xFF007AFF);
  static const green = Color(0xFF34C759);
  static const indigo = Color(0xFF5856D6);
  static const orange = Color(0xFFFF9500);
  static const purple = Color(0xFFAF52DE);
  static const teal = Color(0xFF30B0C7);
  static const yellow = Color(0xFFFFCC00);
  static const red = Color(0xFFFF3B30);
  static const gray = Color(0xFF8E8E93);
  static const groupGray = Color(0xFFF2F2F7);
}

/// Semantic surfaces that Material's scheme has no names for.
@immutable
class MgPalette extends ThemeExtension<MgPalette> {
  const MgPalette({
    required this.page,
    required this.grouped,
    required this.card,
    required this.fill,
    required this.secondaryLabel,
    required this.separator,
    required this.menu,
    required this.menuBand,
  });

  /// Background of plain pages (library, bookstore, history).
  final Color page;

  /// Background behind grouped cards (settings).
  final Color grouped;

  /// Rounded group cards.
  final Color card;

  /// Search fields, segmented tracks and chips.
  final Color fill;
  final Color secondaryLabel;
  final Color separator;
  final Color menu;
  final Color menuBand;

  static const light = MgPalette(
    page: Colors.white,
    grouped: MgColors.groupGray,
    card: Colors.white,
    fill: Color(0xFFEEEEF0),
    secondaryLabel: Color(0xFF8E8E93),
    separator: Color(0xFFD1D1D6),
    menu: Colors.white,
    menuBand: Color(0xFFEEEEF0),
  );

  static const dark = MgPalette(
    page: Colors.black,
    grouped: Colors.black,
    card: Color(0xFF1C1C1E),
    fill: Color(0xFF2C2C2E),
    secondaryLabel: Color(0xFFAEAEB2),
    separator: Color(0xFF48484A),
    menu: Color(0xFF2C2C2E),
    menuBand: Color(0xFF1C1C1E),
  );

  static MgPalette of(BuildContext context) =>
      Theme.of(context).extension<MgPalette>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  MgPalette copyWith({
    Color? page,
    Color? grouped,
    Color? card,
    Color? fill,
    Color? secondaryLabel,
    Color? separator,
    Color? menu,
    Color? menuBand,
  }) =>
      MgPalette(
        page: page ?? this.page,
        grouped: grouped ?? this.grouped,
        card: card ?? this.card,
        fill: fill ?? this.fill,
        secondaryLabel: secondaryLabel ?? this.secondaryLabel,
        separator: separator ?? this.separator,
        menu: menu ?? this.menu,
        menuBand: menuBand ?? this.menuBand,
      );

  @override
  MgPalette lerp(MgPalette? other, double t) {
    if (other == null) return this;
    return MgPalette(
      page: Color.lerp(page, other.page, t)!,
      grouped: Color.lerp(grouped, other.grouped, t)!,
      card: Color.lerp(card, other.card, t)!,
      fill: Color.lerp(fill, other.fill, t)!,
      secondaryLabel: Color.lerp(secondaryLabel, other.secondaryLabel, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      menu: Color.lerp(menu, other.menu, t)!,
      menuBand: Color.lerp(menuBand, other.menuBand, t)!,
    );
  }
}

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: MgColors.pink,
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFFFE5EC),
  onPrimaryContainer: Color(0xFF8F1734),
  inversePrimary: MgColors.pink,
  secondary: MgColors.pink,
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFFFFE5EC),
  onSecondaryContainer: Color(0xFF8F1734),
  tertiary: MgColors.pink,
  onTertiary: Colors.white,
  tertiaryContainer: Color(0xFFFFE5EC),
  onTertiaryContainer: Color(0xFF8F1734),
  surface: Colors.white,
  onSurface: Colors.black,
  onSurfaceVariant: Color(0xFF8E8E93),
  surfaceTint: Colors.transparent,
  inverseSurface: Color(0xFF2C2C2E),
  onInverseSurface: Colors.white,
  surfaceDim: Color(0xFFE5E5EA),
  surfaceBright: Colors.white,
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Color(0xFFF9F9FB),
  surfaceContainer: MgColors.groupGray,
  surfaceContainerHigh: MgColors.groupGray,
  surfaceContainerHighest: Color(0xFFEEEEF0),
  outline: Color(0xFFC7C7CC),
  outlineVariant: Color(0xFFD1D1D6),
  error: Color(0xFFFF3B30),
  onError: Colors.white,
  errorContainer: Color(0xFFFFDAD6),
  onErrorContainer: Color(0xFF7D1710),
  scrim: Colors.black,
  shadow: Colors.black,
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: MgColors.pink,
  onPrimary: Colors.white,
  primaryContainer: Color(0xFF4C1524),
  onPrimaryContainer: Color(0xFFFFD9E2),
  inversePrimary: MgColors.pink,
  secondary: MgColors.pink,
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFF4C1524),
  onSecondaryContainer: Color(0xFFFFD9E2),
  tertiary: MgColors.pink,
  onTertiary: Colors.white,
  tertiaryContainer: Color(0xFF4C1524),
  onTertiaryContainer: Color(0xFFFFD9E2),
  surface: Color(0xFF1C1C1E),
  onSurface: Colors.white,
  onSurfaceVariant: Color(0xFFAEAEB2),
  surfaceTint: Colors.transparent,
  inverseSurface: MgColors.groupGray,
  onInverseSurface: Colors.black,
  surfaceDim: Color(0xFF1C1C1E),
  surfaceBright: Color(0xFF3A3A3C),
  surfaceContainerLowest: Colors.black,
  surfaceContainerLow: Color(0xFF1C1C1E),
  surfaceContainer: Color(0xFF1C1C1E),
  surfaceContainerHigh: Color(0xFF2C2C2E),
  surfaceContainerHighest: Color(0xFF2C2C2E),
  outline: Color(0xFF636366),
  outlineVariant: Color(0xFF48484A),
  error: Color(0xFFFF453A),
  onError: Colors.white,
  errorContainer: Color(0xFF561D1A),
  onErrorContainer: Color(0xFFFFDAD6),
  scrim: Colors.black,
  shadow: Colors.black,
);

/// E-ink screens keep a pure black-on-white scheme without tints or motion.
const _einkScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Colors.black,
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFE0E0E0),
  onPrimaryContainer: Colors.black,
  secondary: Colors.black,
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFFE0E0E0),
  onSecondaryContainer: Colors.black,
  tertiary: Colors.black,
  onTertiary: Colors.white,
  surface: Colors.white,
  onSurface: Colors.black,
  onSurfaceVariant: Color(0xFF424242),
  surfaceTint: Colors.transparent,
  surfaceContainerLowest: Colors.white,
  surfaceContainerLow: Colors.white,
  surfaceContainer: Colors.white,
  surfaceContainerHigh: Colors.white,
  surfaceContainerHighest: Color(0xFFEEEEEE),
  outline: Colors.black,
  outlineVariant: Color(0xFF9E9E9E),
  error: Colors.black,
  onError: Colors.white,
);

const _einkPalette = MgPalette(
  page: Colors.white,
  grouped: Colors.white,
  card: Colors.white,
  fill: Color(0xFFEEEEEE),
  secondaryLabel: Color(0xFF424242),
  separator: Color(0xFF9E9E9E),
  menu: Colors.white,
  menuBand: Color(0xFFE0E0E0),
);

ThemeData monogatariTheme(
  Prefs prefs,
  BuildContext context,
  Brightness requested,
) {
  final eink = prefs.eInkMode;
  final brightness = eink
      ? Brightness.light
      : switch (prefs.themeMode) {
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
          ThemeMode.system => MediaQuery.platformBrightnessOf(context),
        };
  final dark = brightness == Brightness.dark;
  final scheme = eink ? _einkScheme : (dark ? _darkScheme : _lightScheme);
  final palette = eink ? _einkPalette : (dark ? MgPalette.dark : MgPalette.light);
  final accent = scheme.primary;
  const pageTransitions = PageTransitionsTheme(builders: {
    TargetPlatform.android: CupertinoPageTransitionsBuilder(),
    TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
    TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
    TargetPlatform.fuchsia: CupertinoPageTransitionsBuilder(),
  });
  final rounded12 = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));

  final theme = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    extensions: [palette],
    scaffoldBackgroundColor: palette.page,
    canvasColor: palette.page,
    dividerColor: palette.separator,
    splashFactory: eink ? NoSplash.splashFactory : InkRipple.splashFactory,
    highlightColor: eink ? Colors.transparent : null,
    pageTransitionsTheme: eink
        ? PageTransitionsTheme(builders: {
            for (final platform in TargetPlatform.values)
              platform: const _NoAnimationPageTransitionsBuilder(),
          })
        : pageTransitions,
    appBarTheme: AppBarTheme(
      backgroundColor: palette.page,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(color: accent),
      actionsIconTheme: IconThemeData(color: accent),
      titleTextStyle: TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    dividerTheme: DividerThemeData(
      thickness: 0.5,
      space: 0.5,
      color: palette.separator,
    ),
    iconTheme: IconThemeData(color: scheme.onSurface),
    listTileTheme: ListTileThemeData(
      iconColor: accent,
      selectedColor: accent,
      selectedTileColor: accent.withValues(alpha: .08),
      titleTextStyle: TextStyle(fontSize: 16, color: scheme.onSurface),
      subtitleTextStyle:
          TextStyle(fontSize: 12, color: palette.secondaryLabel, height: 1.5),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: scheme.onPrimary,
        minimumSize: const Size(64, 46),
        shape: rounded12,
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: scheme.onPrimary,
        elevation: 0,
        minimumSize: const Size(64, 46),
        shape: rounded12,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: scheme.onSurface,
        minimumSize: const Size(64, 46),
        side: BorderSide(color: palette.separator),
        shape: rounded12,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(highlightColor: accent.withValues(alpha: .08)),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: scheme.onPrimary,
      elevation: 2,
      shape: const CircleBorder(),
    ),
    // iOS-style switch: a full-size white thumb in both states on an accent or gray track.
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.disabled) ? Colors.white.withValues(alpha: .8) : Colors.white),
      thumbIcon: WidgetStateProperty.all(const Icon(Icons.circle, color: Colors.transparent)),
      trackColor: WidgetStateProperty.resolveWith((states) => states.contains(WidgetState.selected)
          ? accent
          : (dark ? const Color(0xFF39393D) : const Color(0xFFE9E9EA))),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      overlayColor: WidgetStateProperty.all(Colors.transparent),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    sliderTheme: SliderThemeData(
      // iOS-style slider: thin track, white round thumb, no tick marks or value gap.
      // ignore: deprecated_member_use
      year2023: true,
      trackHeight: 4,
      activeTrackColor: accent,
      inactiveTrackColor: dark ? const Color(0xFF39393D) : const Color(0xFFE5E5EA),
      thumbColor: Colors.white,
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12, elevation: 2, pressedElevation: 4),
      overlayShape: SliderComponentShape.noOverlay,
      tickMarkShape: SliderTickMarkShape.noTickMark,
      trackShape: const RoundedRectSliderTrackShape(),
      showValueIndicator: ShowValueIndicator.never,
    ),
    // ignore: deprecated_member_use
    progressIndicatorTheme: ProgressIndicatorThemeData(
      // ignore: deprecated_member_use
      year2023: false,
      color: accent,
      linearTrackColor: palette.fill,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? (dark ? const Color(0xFF636366) : Colors.white)
                : palette.fill),
        foregroundColor: WidgetStateProperty.all(scheme.onSurface),
        side: WidgetStateProperty.all(BorderSide(color: palette.fill, width: 2)),
        shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(9))),
        textStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
        visualDensity: VisualDensity.compact,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: palette.fill,
      selectedColor: accent.withValues(alpha: .1),
      checkmarkColor: accent,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: TextStyle(fontSize: 14, color: scheme.onSurface),
      secondaryLabelStyle: TextStyle(fontSize: 14, color: accent),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.fill,
      hintStyle: TextStyle(color: palette.secondaryLabel),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 1),
      ),
    ),
    cardTheme: CardThemeData(
      color: palette.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: rounded12,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.menu,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      titleTextStyle: TextStyle(
          fontSize: 17, fontWeight: FontWeight.w600, color: scheme.onSurface),
      contentTextStyle: TextStyle(
          fontSize: 14, height: 1.45, color: scheme.onSurface),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: dark ? const Color(0xFF1C1C1E) : Colors.white,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: dark ? const Color(0xFF1C1C1E) : Colors.white,
      showDragHandle: true,
      dragHandleColor: palette.separator,
      dragHandleSize: const Size(36, 4),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(14))),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.menu,
      surfaceTintColor: Colors.transparent,
      elevation: 12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      textStyle: TextStyle(fontSize: 16, color: scheme.onSurface),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(palette.menu),
        surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
        elevation: WidgetStateProperty.all(12),
        shape: WidgetStateProperty.all(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        padding: WidgetStateProperty.all(EdgeInsets.zero),
      ),
    ),
    drawerTheme: DrawerThemeData(backgroundColor: palette.grouped),
    tabBarTheme: TabBarThemeData(
      labelColor: accent,
      unselectedLabelColor: palette.secondaryLabel,
      indicatorColor: accent,
      dividerColor: Colors.transparent,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: rounded12,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface.withValues(alpha: .92),
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );
  return theme.useSystemChineseFont(brightness);
}

class _NoAnimationPageTransitionsBuilder extends PageTransitionsBuilder {
  const _NoAnimationPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) =>
      child;
}
