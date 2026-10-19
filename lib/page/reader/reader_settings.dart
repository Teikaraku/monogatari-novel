import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/code_highlight_theme.dart';
import 'package:anx_reader/enums/convert_chinese_mode.dart';
import 'package:anx_reader/enums/page_turn_mode.dart';
import 'package:anx_reader/enums/reading_info.dart';
import 'package:anx_reader/enums/text_alignment.dart';
import 'package:anx_reader/enums/translation_mode.dart';
import 'package:anx_reader/enums/writing_mode.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book_style.dart';
import 'package:anx_reader/models/reading_info.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/reader/reader_kit.dart';
import 'package:anx_reader/page/reader/reader_theme.dart';
import 'package:anx_reader/page/reading_page.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:anx_reader/utils/platform_utils.dart';
import 'package:anx_reader/utils/ui/status_bar.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/custom_css_editor.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/diagram.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/page_turn_dropdown.dart';
import 'package:anx_reader/widgets/reading_page/more_settings/page_turning/types_and_icons.dart';
import 'package:flutter/material.dart';

enum ReaderSettingsTab { content, layout, controls }

/// The full reading settings in a tall sheet, in the reader's colours.
Future<void> showReaderSettingsSheet(BuildContext context, {ReaderSettingsTab initial = ReaderSettingsTab.layout}) {
  final theme = readerChromeTheme(context, Prefs().readTheme);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    backgroundColor: theme.extension<MgPalette>()!.page,
    constraints: const BoxConstraints(maxWidth: 640),
    builder: (sheetContext) => Theme(
      data: theme,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: theme.colorScheme.onSurface),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * .88,
          child: _SettingsSheet(initial: initial),
        ),
      ),
    ),
  );
}

class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({required this.initial});

  final ReaderSettingsTab initial;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late ReaderSettingsTab _tab = widget.initial;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 36,
            height: 4,
            decoration: BoxDecoration(color: palette.separator, borderRadius: BorderRadius.circular(2)),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
          child: ReaderPanelHeader(title: l10n.readerSettings, onClose: () => Navigator.of(context).pop()),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: ReaderChoiceRow<ReaderSettingsTab>(
            selected: _tab,
            onSelected: (tab) => setState(() => _tab = tab),
            options: [
              (ReaderSettingsTab.content, Text(l10n.readerSettingsContent)),
              (ReaderSettingsTab.layout, Text(l10n.readerSettingsLayout)),
              (ReaderSettingsTab.controls, Text(l10n.readerSettingsControls)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.only(top: 6, bottom: 24 + MediaQuery.paddingOf(context).bottom),
            child: switch (_tab) {
              ReaderSettingsTab.content => const ReaderContentSettings(),
              ReaderSettingsTab.layout => const ReaderLayoutSettings(),
              ReaderSettingsTab.controls => const ReaderControlSettings(),
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Rows

/// A titled card of setting rows, separated by hairlines.
class RsGroup extends StatelessWidget {
  const RsGroup({super.key, this.title, required this.children});

  final String? title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(Padding(
          padding: const EdgeInsets.only(left: 16),
          child: Container(height: .5, color: palette.separator),
        ));
      }
      rows.add(children[i]);
    }
    return MgReadable(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 7),
                child: Text(title!, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
              ),
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: Material(
                color: palette.card,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Title with an optional value or control on the right and an optional control below.
class RsRow extends StatelessWidget {
  const RsRow({super.key, required this.title, this.trailing, this.below, this.onTap, this.enabled = true});

  final String title;
  final Widget? trailing;
  final Widget? below;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: EdgeInsets.fromLTRB(16, below == null ? 4 : 12, 12, below == null ? 4 : 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(minHeight: below == null ? 44 : 24),
            child: Row(
              children: [
                Expanded(child: Text(title, style: const TextStyle(fontSize: 15))),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          if (below != null) ...[const SizedBox(height: 10), below!],
        ],
      ),
    );
    return Opacity(
      opacity: enabled ? 1 : .45,
      child: IgnorePointer(
        ignoring: !enabled,
        child: onTap == null ? content : InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

class RsSwitch extends StatelessWidget {
  const RsSwitch({super.key, required this.title, required this.value, required this.onChanged});

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) =>
      RsRow(title: title, trailing: Switch(value: value, onChanged: onChanged), onTap: () => onChanged(!value));
}

class RsSlider extends StatelessWidget {
  const RsSlider({
    super.key,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    required this.label,
    this.divisions,
    this.onChangeEnd,
    this.enabled = true,
  });

  final String title;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String label;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;
  final bool enabled;

  @override
  Widget build(BuildContext context) => RsRow(
        title: title,
        enabled: enabled,
        trailing: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: MgPalette.of(context).secondaryLabel,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        below: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      );
}

class RsChoice<T> extends StatelessWidget {
  const RsChoice({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.enabled = true,
  });

  final String title;
  final List<(T, String)> options;
  final T? selected;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) => RsRow(
        title: title,
        enabled: enabled,
        below: ReaderChoiceRow<T>(
          height: 36,
          selected: selected,
          onSelected: onSelected,
          options: [for (final (value, label) in options) (value, Text(label, maxLines: 1, softWrap: false))],
        ),
      );
}

/// A row showing the current choice; tapping opens the options in a sheet.
class RsPicker<T> extends StatelessWidget {
  const RsPicker({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.onSelected,
  });

  final String title;
  final List<(T, String)> options;
  final T selected;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final current = options.where((o) => o.$1 == selected).firstOrNull?.$2 ?? '';
    return RsRow(
      title: title,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(current, style: TextStyle(fontSize: 14, color: palette.secondaryLabel)),
          Icon(Icons.chevron_right, size: 20, color: palette.secondaryLabel),
        ],
      ),
      onTap: () => showReaderSheet(
        context: context,
        title: title,
        builder: (sheet) => MgSheetGroup(children: [
          for (final (value, label) in options)
            MgSheetOption(
              title: label,
              selected: value == selected,
              onTap: () {
                Navigator.of(sheet).pop();
                onSelected(value);
              },
            ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Content: direction, columns, conversion, translation, code, header and footer.

class ReaderContentSettings extends StatefulWidget {
  const ReaderContentSettings({super.key});

  @override
  State<ReaderContentSettings> createState() => _ReaderContentSettingsState();
}

class _ReaderContentSettingsState extends State<ReaderContentSettings> {
  bool get _reading => epubPlayerKey.currentState?.mounted ?? false;

  void _style(BookStyle style) {
    Prefs().saveBookStyleToPrefs(style);
    epubPlayerKey.currentState?.changeStyle(style);
    setState(() {});
  }

  void _info(ReadingInfoModel info) {
    Prefs().readingInfo = info;
    epubPlayerKey.currentState?.changeReadingInfo();
    setState(() {});
  }

  Widget _section(String title, ReadingInfoSectionModel section, ValueChanged<ReadingInfoSectionModel> onChanged) {
    final l10n = L10n.of(context);
    final options = [for (final info in ReadingInfoEnum.values) (info, info.getL10n(context))];
    return RsGroup(title: title, children: [
      RsPicker<ReadingInfoEnum>(
        title: l10n.readingPageLeft,
        options: options,
        selected: section.left,
        onSelected: (v) => onChanged(section.copyWith(left: v)),
      ),
      RsPicker<ReadingInfoEnum>(
        title: l10n.readingPageCenter,
        options: options,
        selected: section.center,
        onSelected: (v) => onChanged(section.copyWith(center: v)),
      ),
      RsPicker<ReadingInfoEnum>(
        title: l10n.readingPageRight,
        options: options,
        selected: section.right,
        onSelected: (v) => onChanged(section.copyWith(right: v)),
      ),
      RsSlider(
        title: l10n.readingSettingsMargin,
        value: section.verticalMargin,
        min: 0,
        max: 80,
        divisions: 40,
        label: section.verticalMargin.toStringAsFixed(0),
        onChanged: (v) => onChanged(section.copyWith(verticalMargin: v)),
      ),
      RsSlider(
        title: l10n.readingPageLeftMargin,
        value: section.leftMargin,
        min: 0,
        max: 80,
        divisions: 40,
        label: section.leftMargin.toStringAsFixed(0),
        onChanged: (v) => onChanged(section.copyWith(leftMargin: v)),
      ),
      RsSlider(
        title: l10n.readingPageRightMargin,
        value: section.rightMargin,
        min: 0,
        max: 80,
        divisions: 40,
        label: section.rightMargin.toStringAsFixed(0),
        onChanged: (v) => onChanged(section.copyWith(rightMargin: v)),
      ),
      RsSlider(
        title: l10n.readingPageFontSize,
        value: section.fontSize,
        min: 8,
        max: 24,
        divisions: 16,
        label: section.fontSize.toStringAsFixed(0),
        onChanged: (v) => onChanged(section.copyWith(fontSize: v)),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final style = Prefs().bookStyle;
    final info = Prefs().readingInfo;
    final code = Prefs().codeHighlightTheme;
    final player = epubPlayerKey.currentState;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RsGroup(title: l10n.readerGroupTypesetting, children: [
          RsChoice<WritingModeEnum>(
            title: l10n.readingPageWritingDirection,
            selected: Prefs().writingMode,
            onSelected: (value) {
              Prefs().writingMode = value;
              _style(Prefs().bookStyle.copyWith(maxColumnCount: 1));
            },
            options: [
              (WritingModeEnum.auto, l10n.readingPageWritingDirectionAuto),
              (WritingModeEnum.verticalRl, l10n.readingPageWritingDirectionVertical),
              (WritingModeEnum.horizontalTb, l10n.readingPageWritingDirectionHorizontal),
            ],
          ),
          RsChoice<int>(
            title: l10n.readingPageColumnCount,
            selected: style.maxColumnCount,
            onSelected: (value) => _style(style.copyWith(maxColumnCount: value)),
            options: [(0, l10n.readingPageAuto), (1, l10n.readingPageSingle), (2, l10n.readingPageDouble)],
          ),
          if (style.maxColumnCount == 0)
            RsSlider(
              title: l10n.readingPageColumnThreshold,
              value: style.columnThreshold,
              min: 400,
              max: 1200,
              divisions: 40,
              label: '${style.columnThreshold.toInt()}px',
              onChanged: (value) => _style(style.copyWith(columnThreshold: value)),
            ),
        ]),
        RsGroup(title: l10n.readerGroupText, children: [
          RsChoice<ConvertChineseMode>(
            title: l10n.readingPageConvertChinese,
            selected: Prefs().readingRules.convertChineseMode,
            onSelected: (value) {
              Prefs().readingRules = Prefs().readingRules.copyWith(convertChineseMode: value);
              epubPlayerKey.currentState?.changeReadingRules(Prefs().readingRules);
              setState(() {});
            },
            options: [
              (ConvertChineseMode.none, l10n.readingPageOriginal),
              (ConvertChineseMode.t2s, l10n.readingPageSimplified),
              (ConvertChineseMode.s2t, l10n.readingPageTraditional),
            ],
          ),
          if (_reading && player != null)
            RsChoice<TranslationModeEnum>(
              title: l10n.translationMode,
              selected: Prefs().getBookTranslationMode(player.widget.book.id),
              onSelected: (value) {
                Prefs().setBookTranslationMode(player.widget.book.id, value);
                player.setTranslationMode(value);
                setState(() {});
              },
              options: [
                (TranslationModeEnum.off, l10n.readingPageOriginal),
                (TranslationModeEnum.translationOnly, l10n.translationOnly),
                (TranslationModeEnum.bilingual, l10n.bilingual),
              ],
            ),
        ]),
        RsGroup(title: l10n.codeHighlightTheme, children: [
          RsChoice<String>(
            title: l10n.readerTheme,
            selected: code == CodeHighlightThemeEnum.off
                ? 'off'
                : code.isLight
                    ? 'light'
                    : 'dark',
            onSelected: (value) {
              Prefs().codeHighlightTheme = switch (value) {
                'off' => CodeHighlightThemeEnum.off,
                'light' => CodeHighlightThemeEnum.defaultTheme,
                _ => CodeHighlightThemeEnum.vsDark,
              };
              epubPlayerKey.currentState?.changeStyle(null);
              setState(() {});
            },
            options: [
              ('off', l10n.codeHighlightOff),
              ('light', l10n.codeHighlightLight),
              ('dark', l10n.codeHighlightDark),
            ],
          ),
          if (code != CodeHighlightThemeEnum.off)
            RsPicker<CodeHighlightThemeEnum>(
              title: code.isLight ? l10n.codeHighlightLightThemes : l10n.codeHighlightDarkThemes,
              selected: code,
              options: [
                for (final theme in CodeHighlightThemeEnum.values)
                  if (theme != CodeHighlightThemeEnum.off && theme.isLight == code.isLight) (theme, theme.displayName),
              ],
              onSelected: (theme) {
                Prefs().codeHighlightTheme = theme;
                epubPlayerKey.currentState?.changeStyle(null);
                setState(() {});
              },
            ),
        ]),
        _section(l10n.readingPageHeaderSettings, info.header, (s) => _info(info.copyWith(header: s))),
        _section(l10n.readingPageFooterSettings, info.footer, (s) => _info(info.copyWith(footer: s))),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Layout: book styles, text, paragraph, page and custom CSS.

class ReaderLayoutSettings extends StatefulWidget {
  const ReaderLayoutSettings({super.key});

  @override
  State<ReaderLayoutSettings> createState() => _ReaderLayoutSettingsState();
}

class _ReaderLayoutSettingsState extends State<ReaderLayoutSettings> {
  BookStyle _book = Prefs().bookStyle;

  void _apply(BookStyle style) {
    Prefs().saveBookStyleToPrefs(style);
    epubPlayerKey.currentState?.changeStyle(style);
    setState(() => _book = style);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final custom = !Prefs().useBookStyles;
    final vertical = Prefs().writingMode == WritingModeEnum.verticalRl;
    final alignments = [
      (TextAlignmentEnum.auto, l10n.textAlignmentAuto),
      (TextAlignmentEnum.left, l10n.textAlignmentLeft),
      (TextAlignmentEnum.center, l10n.textAlignmentCenter),
      (TextAlignmentEnum.right, l10n.textAlignmentRight),
      (TextAlignmentEnum.justify, l10n.textAlignmentJustify),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RsGroup(children: [
          RsSwitch(
            title: l10n.useBookStyles,
            value: Prefs().useBookStyles,
            onChanged: (value) {
              Prefs().useBookStyles = value;
              epubPlayerKey.currentState?.changeStyle(Prefs().bookStyle);
              setState(() {});
            },
          ),
        ]),
        RsGroup(title: l10n.readerGroupText, children: [
          RsSlider(
            title: l10n.readerFontSize,
            enabled: custom,
            value: _book.fontSize,
            min: .8,
            max: 3,
            divisions: 22,
            label: '${(_book.fontSize * 10).round()}',
            onChanged: (v) => _apply(_book.copyWith(fontSize: double.parse(v.toStringAsFixed(1)))),
          ),
          RsSlider(
            title: l10n.readingPageFontWeight,
            enabled: custom,
            value: _book.fontWeight,
            min: 100,
            max: 900,
            divisions: 8,
            label: _book.fontWeight.toStringAsFixed(0),
            onChanged: (v) => _apply(_book.copyWith(fontWeight: v)),
          ),
          RsSlider(
            title: l10n.readingPageLetterSpacing,
            enabled: custom,
            value: _book.letterSpacing,
            min: -3,
            max: 7,
            divisions: 10,
            label: _book.letterSpacing.toStringAsFixed(0),
            onChanged: (v) => _apply(_book.copyWith(letterSpacing: v)),
          ),
          RsSlider(
            title: l10n.readerHeadingSize,
            enabled: custom,
            value: _book.headingFontSize,
            min: .5,
            max: 2,
            divisions: 15,
            label: '${(_book.headingFontSize * 100).round()}%',
            onChanged: (v) => _apply(_book.copyWith(headingFontSize: v)),
          ),
        ]),
        RsGroup(title: l10n.readerGroupParagraph, children: [
          RsSlider(
            title: l10n.readingPageLineSpacing,
            enabled: custom,
            value: _book.lineHeight,
            min: 0,
            max: 3,
            divisions: 30,
            label: _book.lineHeight.toStringAsFixed(1),
            onChanged: (v) => _apply(_book.copyWith(lineHeight: double.parse(v.toStringAsFixed(1)))),
          ),
          RsSlider(
            title: l10n.readingPageParagraphSpacing,
            enabled: custom,
            value: _book.paragraphSpacing,
            min: 0,
            max: 5,
            divisions: 10,
            label: _book.paragraphSpacing.toStringAsFixed(1),
            onChanged: (v) => _apply(_book.copyWith(paragraphSpacing: v)),
          ),
          RsSlider(
            title: l10n.readingPageIndent,
            enabled: custom,
            value: _book.indent,
            min: -.5,
            max: 8,
            divisions: 17,
            label: _book.indent < 0 ? l10n.readingPageIndentNoChange : _book.indent.toStringAsFixed(1),
            onChanged: (v) => _apply(_book.copyWith(indent: v)),
          ),
          RsPicker<TextAlignmentEnum>(
            title: l10n.textAlignment,
            options: alignments,
            selected: Prefs().textAlignment,
            onSelected: (value) {
              Prefs().textAlignment = value;
              epubPlayerKey.currentState?.changeStyle(Prefs().bookStyle);
              setState(() {});
            },
          ),
        ]),
        RsGroup(title: l10n.readerGroupPage, children: [
          RsSlider(
            title: vertical ? l10n.readingPageVerticleMargin : l10n.readingPageSideMargin,
            value: _book.sideMargin,
            min: 0,
            max: 20,
            divisions: 20,
            label: _book.sideMargin.toStringAsFixed(0),
            onChanged: (v) => _apply(_book.copyWith(sideMargin: v)),
          ),
          RsSlider(
            title: vertical ? l10n.readingPageRightMargin : l10n.readingPageTopMargin,
            value: _book.topMargin,
            min: 0,
            max: 200,
            divisions: 10,
            label: (_book.topMargin / 20).toStringAsFixed(0),
            onChanged: (v) => _apply(_book.copyWith(topMargin: v)),
          ),
          RsSlider(
            title: vertical ? l10n.readingPageLeftMargin : l10n.readingPageBottomMargin,
            value: _book.bottomMargin,
            min: 0,
            max: 200,
            divisions: 10,
            label: (_book.bottomMargin / 20).toStringAsFixed(0),
            onChanged: (v) => _apply(_book.copyWith(bottomMargin: v)),
          ),
        ]),
        const RsGroup(children: [Padding(padding: EdgeInsets.symmetric(horizontal: 4), child: CustomCSSEditor())]),
      ],
    );
  }
}

// ---------------------------------------------------------------------------------------------
// Controls: page turning, display, selection and AI.

class ReaderControlSettings extends StatefulWidget {
  const ReaderControlSettings({super.key});

  @override
  State<ReaderControlSettings> createState() => _ReaderControlSettingsState();
}

class _ReaderControlSettingsState extends State<ReaderControlSettings> {
  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final mode = PageTurnMode.fromCode(Prefs().pageTurnMode);
    final delays = [
      l10n.readingPageAutoSummaryDelayEveryTime,
      l10n.readingPageAutoSummaryDelay30Minutes,
      l10n.readingPageAutoSummaryDelay3Hours,
      l10n.readingPageAutoSummaryDelayNextDay,
      l10n.readingPageAutoSummaryDelay3Days,
      l10n.readingPageAutoSummaryDelay1Week,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        RsGroup(title: l10n.readingPagePageTurningMethod, children: [
          RsChoice<PageTurnMode>(
            title: l10n.readerTapZones,
            selected: mode,
            onSelected: (value) => setState(() => Prefs().pageTurnMode = value.code),
            options: [(PageTurnMode.simple, l10n.pageTurnModeSimple), (PageTurnMode.custom, l10n.pageTurnModeCustom)],
          ),
          if (mode == PageTurnMode.simple)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
              child: SizedBox(
                height: 116,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: pageTurningTypes.length,
                  itemBuilder: (context, index) => Padding(
                    padding: const EdgeInsets.all(6),
                    child: getPageTurningDiagram(
                      context,
                      pageTurningTypes[index],
                      pageTurningIcons[index],
                      Prefs().pageTurningType == index,
                      () => setState(() => Prefs().pageTurningType = index),
                    ),
                  ),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  for (var row = 0; row < 3; row++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          for (var col = 0; col < 3; col++)
                            Expanded(
                              child: Padding(
                                padding: EdgeInsets.only(right: col < 2 ? 8 : 0),
                                child: PageTurnDropdown(
                                  value: PageTurningType.values[Prefs().customPageTurnConfig[row * 3 + col]],
                                  onChanged: (type) {
                                    if (type == null) return;
                                    final config = Prefs().customPageTurnConfig;
                                    config[row * 3 + col] = type.index;
                                    setState(() => Prefs().customPageTurnConfig = config);
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          if (AnxPlatform.isAndroid)
            RsSwitch(
              title: l10n.readingPageVolumeKeyTurnPage,
              value: Prefs().volumeKeyTurnPage,
              onChanged: (v) => setState(() => Prefs().volumeKeyTurnPage = v),
            ),
          RsSwitch(
            title: l10n.readingPageSwapPageTurnArea,
            value: Prefs().swapPageTurnArea,
            onChanged: (v) => setState(() => Prefs().swapPageTurnArea = v),
          ),
          if (AnxPlatform.isDesktop) ...[
            RsSwitch(
              title: l10n.readingPageKeyboardShortcutTurnPage,
              value: Prefs().keyboardShortcutTurnPage,
              onChanged: (v) => setState(() => Prefs().keyboardShortcutTurnPage = v),
            ),
            RsSwitch(
              title: l10n.readingPageShowMenuOnHover,
              value: Prefs().showMenuOnHover,
              onChanged: (v) => setState(() => Prefs().showMenuOnHover = v),
            ),
          ],
        ]),
        RsGroup(title: l10n.readerGroupDisplay, children: [
          RsSwitch(
            title: l10n.readingPageFullScreen,
            value: Prefs().hideStatusBar,
            onChanged: (v) => setState(() {
              Prefs().saveHideStatusBar(v);
              v ? hideStatusBar() : showStatusBar();
            }),
          ),
          RsSwitch(
            title: l10n.readingPageAutoAdjustReadingTheme,
            value: Prefs().autoAdjustReadingTheme,
            onChanged: (v) => setState(() => Prefs().autoAdjustReadingTheme = v),
          ),
          RsSlider(
            title: l10n.readerKeepAwake,
            value: Prefs().awakeTime.toDouble(),
            min: 0,
            max: 60,
            divisions: 12,
            label: l10n.commonMinutes(Prefs().awakeTime),
            onChanged: (v) => setState(() => Prefs().awakeTime = v.toInt()),
            onChangeEnd: (v) => readingPageKey.currentState?.setAwakeTimer(v.toInt()),
          ),
        ]),
        RsGroup(title: l10n.readerGroupSelection, children: [
          RsSwitch(
            title: l10n.readingPageAutoMarkSelection,
            value: Prefs().autoMarkSelection,
            onChanged: (v) => setState(() => Prefs().autoMarkSelection = v),
          ),
          RsSwitch(
            title: l10n.readingPageAutoTranslateSelection,
            value: Prefs().autoTranslateSelection,
            onChanged: (v) => setState(() => Prefs().autoTranslateSelection = v),
          ),
        ]),
        if (EnvVar.enableAIFeature)
          RsGroup(title: 'AI', children: [
            RsSwitch(
              title: l10n.readingPageAutoSummaryPreviousContent,
              value: Prefs().autoSummaryPreviousContent,
              onChanged: (v) => setState(() => Prefs().autoSummaryPreviousContent = v),
            ),
            if (Prefs().autoSummaryPreviousContent)
              RsPicker<int>(
                title: l10n.readerSummaryFrequency,
                options: [for (var i = 0; i < delays.length; i++) (i, delays[i])],
                selected: Prefs().autoSummaryDelayLevel,
                onSelected: (v) => setState(() => Prefs().autoSummaryDelayLevel = v),
              ),
          ]),
      ],
    );
  }
}
