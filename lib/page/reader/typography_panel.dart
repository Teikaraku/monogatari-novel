import 'dart:io';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/theme.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/models/font_model.dart';
import 'package:anx_reader/models/read_theme.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/reader/reader_kit.dart';
import 'package:anx_reader/page/reader/reader_theme.dart';
import 'package:anx_reader/page/settings_page/subpage/fonts.dart';
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/service/font.dart';
import 'package:anx_reader/utils/font_parser.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/enums/page_turn_style.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';

const _lineSpacings = [1.4, 1.8, 2.2, 2.6];
const _margins = [3.0, 6.0, 10.0];

/// Text size, font, spacing, margins, theme and page turn — the settings people change
/// while reading. Everything else lives in the full settings sheet.
class TypographyPanel extends StatefulWidget {
  const TypographyPanel({
    super.key,
    required this.epubPlayerKey,
    required this.onClose,
    required this.onMore,
    required this.onBackground,
  });

  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final VoidCallback onClose;
  final VoidCallback onMore;
  final VoidCallback onBackground;

  @override
  State<TypographyPanel> createState() => _TypographyPanelState();
}

class _TypographyPanelState extends State<TypographyPanel> {
  BookStyle _style = Prefs().bookStyle;
  List<ReadTheme> _themes = const [];

  @override
  void initState() {
    super.initState();
    _loadThemes();
  }

  Future<void> _loadThemes() async {
    final themes = await themeDao.selectThemes();
    if (mounted) setState(() => _themes = themes);
  }

  void _apply(BookStyle style) {
    Prefs().saveBookStyleToPrefs(style);
    widget.epubPlayerKey.currentState?.changeStyle(style);
    setState(() => _style = style);
  }

  void _fontSize(double delta) {
    final next = double.parse((_style.fontSize + delta).clamp(0.8, 3.0).toStringAsFixed(1));
    if (next != _style.fontSize) _apply(_style.copyWith(fontSize: next));
  }

  T? _nearest<T extends num>(List<T> options, double value) =>
      options.where((o) => (o - value).abs() < .05).firstOrNull;

  void _selectTheme(ReadTheme theme) {
    Prefs().saveReadThemeToPrefs(theme);
    widget.epubPlayerKey.currentState?.changeTheme(theme);
    setState(() {});
  }

  Future<void> _addTheme() async {
    final theme = ReadTheme(backgroundColor: 'ff121212', textColor: 'ffcccccc', backgroundImagePath: '');
    theme.id = await themeDao.insertTheme(theme);
    await _loadThemes();
    if (mounted) await _editTheme(theme);
  }

  Future<void> _editTheme(ReadTheme theme) async {
    final l10n = L10n.of(context);
    await showReaderSheet(
      context: context,
      title: l10n.readerTheme,
      builder: (context) => _ThemeEditor(
        theme: theme,
        onChanged: () async {
          await themeDao.updateTheme(theme);
          if (Prefs().readTheme.id == theme.id) _selectTheme(theme);
          await _loadThemes();
        },
        onDelete: () async {
          Navigator.of(context).pop();
          await themeDao.deleteTheme(theme.id!);
          await _loadThemes();
        },
      ),
    );
  }

  List<FontModel> _fonts(L10n l10n) {
    final fontDir = getFontDir();
    final files = fontDir.existsSync() ? fontDir.listSync().whereType<File>().toList() : const <File>[];
    return [
      FontModel(label: l10n.followBook, name: 'book', path: 'book'),
      FontModel(label: l10n.systemFont, name: 'system', path: 'system'),
      for (var i = 0; i < files.length; i++)
        FontModel(
          label: getFontNameFromFile(files[i]),
          name: 'customFont$i',
          path: 'http://127.0.0.1:${Server().port}/fonts/${files[i].path.split(Platform.pathSeparator).last}',
        ),
    ];
  }

  Future<void> _pickFont() async {
    final l10n = L10n.of(context);
    final fonts = _fonts(l10n);
    final current = Prefs().font.path;
    await showReaderSheet(
      context: context,
      title: l10n.readerFont,
      builder: (context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MgSheetGroup(children: [
            for (final font in fonts)
              MgSheetOption(
                title: font.label,
                selected: font.path == current,
                onTap: () {
                  Navigator.of(context).pop();
                  widget.epubPlayerKey.currentState?.changeFont(font);
                  Prefs().font = font;
                  setState(() {});
                },
              ),
          ]),
          const SizedBox(height: 12),
          MgSheetGroup(children: [
            MgSheetAction(
              title: l10n.downloadFonts,
              icon: Icons.download_outlined,
              onTap: () {
                Navigator.of(context).pop();
                navigatorKey.currentState?.push(CupertinoPageRoute(builder: (_) => const FontsSettingPage()));
              },
            ),
            MgSheetAction(
              title: l10n.addNewFont,
              icon: Icons.add,
              onTap: () {
                Navigator.of(context).pop();
                importFont();
              },
            ),
          ]),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final custom = !Prefs().useBookStyles;
    final fontLabel = _fonts(l10n).where((f) => f.path == Prefs().font.path).firstOrNull?.label ?? l10n.followBook;
    final currentTheme = Prefs().readTheme.id;

    return ReaderCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ReaderPanelHeader(title: l10n.readerTypography, onClose: widget.onClose),
          const SizedBox(height: 14),
          Opacity(
            opacity: custom ? 1 : .4,
            child: Container(
              height: 52,
              decoration: BoxDecoration(color: palette.fill, borderRadius: BorderRadius.circular(14)),
              child: Row(
                children: [
                  _SizeStep(label: 'A', size: 15, onTap: custom ? () => _fontSize(-.1) : null),
                  Container(width: .5, height: 24, color: palette.separator),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${(_style.fontSize * 10).round()}',
                          style: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                        ),
                        Text(l10n.readerFontSize, style: TextStyle(fontSize: 10, color: palette.secondaryLabel)),
                      ],
                    ),
                  ),
                  Container(width: .5, height: 24, color: palette.separator),
                  _SizeStep(label: 'A', size: 24, onTap: custom ? () => _fontSize(.1) : null),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          ReaderLinkRow(icon: Icons.font_download_outlined, title: l10n.readerFont, value: fontLabel, onTap: _pickFont),
          const SizedBox(height: 16),
          Opacity(
            opacity: custom ? 1 : .4,
            child: IgnorePointer(
              ignoring: !custom,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ReaderLabel(l10n.readerLineSpacing),
                  ReaderChoiceRow<double>(
                    selected: _nearest(_lineSpacings, _style.lineHeight),
                    onSelected: (value) => _apply(_style.copyWith(lineHeight: value)),
                    options: [
                      for (final (value, label) in [
                        (_lineSpacings[0], l10n.readerSpacingCompact),
                        (_lineSpacings[1], l10n.readerSpacingStandard),
                        (_lineSpacings[2], l10n.readerSpacingLoose),
                        (_lineSpacings[3], l10n.readerSpacingExtra),
                      ])
                        (value, Text(label)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          ReaderLabel(l10n.readerMargins),
          ReaderChoiceRow<double>(
            selected: _nearest(_margins, _style.sideMargin),
            onSelected: (value) => _apply(_style.copyWith(sideMargin: value)),
            options: [
              (_margins[0], Text(l10n.readerMarginNarrow)),
              (_margins[1], Text(l10n.readerSpacingStandard)),
              (_margins[2], Text(l10n.readerMarginWide)),
            ],
          ),
          const SizedBox(height: 14),
          ReaderLabel(
            l10n.readerTheme,
            trailing: GestureDetector(
              onTap: widget.onBackground,
              child: Text(l10n.readerBackground, style: TextStyle(fontSize: 12, color: scheme.primary)),
            ),
          ),
          SizedBox(
            height: 46,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final theme in _themes)
                  _ThemeTile(
                    theme: theme,
                    selected: theme.id == currentTheme,
                    onTap: () => _selectTheme(theme),
                    onLongPress: () => _editTheme(theme),
                  ),
                _AddThemeTile(onTap: _addTheme),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ReaderLabel(l10n.readerPageTurn),
          ReaderChoiceRow<PageTurn>(
            selected: Prefs().pageTurnStyle,
            onSelected: (value) {
              Prefs().pageTurnStyle = value;
              widget.epubPlayerKey.currentState?.changePageTurnStyle(value);
              setState(() {});
            },
            options: [for (final turn in PageTurn.values) (turn, Text(turn.getLabel(context)))],
          ),
          const SizedBox(height: 6),
          Align(
            child: TextButton(
              onPressed: widget.onMore,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.readerMoreSettings),
                  const Icon(Icons.chevron_right, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SizeStep extends StatelessWidget {
  const _SizeStep({required this.label, required this.size, required this.onTap});

  final String label;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: SizedBox(
          width: 76,
          height: 52,
          child: Center(child: Text(label, style: TextStyle(fontSize: size, fontWeight: FontWeight.w600))),
        ),
      );
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile({required this.theme, required this.selected, required this.onTap, required this.onLongPress});

  final ReadTheme theme;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final background = readerHex(theme.backgroundColor, Colors.white);
    final text = readerHex(theme.textColor, Colors.black);
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(right: 10),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        onSecondaryTap: onLongPress,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 58,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? accent : MgPalette.of(context).separator,
              width: selected ? 2 : .5,
            ),
          ),
          alignment: Alignment.center,
          child: Text('文', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: text)),
        ),
      ),
    );
  }
}

class _AddThemeTile extends StatelessWidget {
  const _AddThemeTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        decoration: BoxDecoration(color: palette.fill, borderRadius: BorderRadius.circular(12)),
        child: Icon(Icons.add, color: palette.secondaryLabel),
      ),
    );
  }
}

/// Background and text colour of a custom theme, with delete.
class _ThemeEditor extends StatefulWidget {
  const _ThemeEditor({required this.theme, required this.onChanged, required this.onDelete});

  final ReadTheme theme;
  final Future<void> Function() onChanged;
  final VoidCallback onDelete;

  @override
  State<_ThemeEditor> createState() => _ThemeEditorState();
}

class _ThemeEditorState extends State<_ThemeEditor> {
  Future<String?> _pick(String current) async {
    var picked = readerHex(current, Colors.white);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: SingleChildScrollView(
          child: ColorPicker(
            hexInputBar: true,
            enableAlpha: false,
            pickerColor: picked,
            onColorChanged: (color) => picked = color,
            pickerAreaHeightPercent: .7,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(L10n.of(context).commonCancel)),
          TextButton(onPressed: () => Navigator.of(context).pop(true), child: Text(L10n.of(context).commonOk)),
        ],
      ),
    );
    return ok == true ? picked.toARGB32().toRadixString(16).padLeft(8, '0') : null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = widget.theme;
    Widget swatch(String hex) => Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: readerHex(hex, Colors.white),
            shape: BoxShape.circle,
            border: Border.all(color: MgPalette.of(context).separator),
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            width: 120,
            height: 72,
            decoration: BoxDecoration(
              color: readerHex(theme.backgroundColor, Colors.white),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: MgPalette.of(context).separator),
            ),
            alignment: Alignment.center,
            child: Text('物语',
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.w600, color: readerHex(theme.textColor, Colors.black))),
          ),
        ),
        const SizedBox(height: 16),
        MgSheetGroup(children: [
          MgRow(
            title: l10n.readerBackgroundColor,
            trailing: swatch(theme.backgroundColor),
            onTap: () async {
              final color = await _pick(theme.backgroundColor);
              if (color == null) return;
              setState(() => theme.backgroundColor = color);
              await widget.onChanged();
            },
          ),
          MgRow(
            title: l10n.readerTextColor,
            trailing: swatch(theme.textColor),
            onTap: () async {
              final color = await _pick(theme.textColor);
              if (color == null) return;
              setState(() => theme.textColor = color);
              await widget.onChanged();
            },
          ),
        ]),
        const SizedBox(height: 12),
        MgSheetGroup(children: [
          MgSheetAction(
              title: l10n.commonDelete, icon: Icons.delete_outline, destructive: true, onTap: widget.onDelete),
        ]),
      ],
    );
  }
}
