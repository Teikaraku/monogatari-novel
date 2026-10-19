import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/widgets/common/anx_segmented_button.dart';
import 'package:anx_reader/widgets/settings/settings_title.dart';
import 'package:anx_reader/widgets/settings/theme_mode.dart';
import 'package:flutter/material.dart';
import 'package:anx_reader/widgets/settings/settings_section.dart';
import 'package:anx_reader/widgets/settings/settings_tile.dart';
import 'package:anx_reader/enums/bookshelf_folder_style.dart';

/// Languages with a complete translation of the app.
const List<Map<String, String>> languageOptions = [
  {'system': 'System'},
  {'简体中文': 'zh-CN'},
  {'繁體中文': 'zh-TW'},
  {'English': 'en'},
];

String _localeCode() {
  final locale = Prefs().locale;
  if (locale == null) return 'System';
  return locale.languageCode + (locale.countryCode != null ? '-${locale.countryCode}' : '');
}

class AppearanceSetting extends StatefulWidget {
  const AppearanceSetting({super.key});

  @override
  State<AppearanceSetting> createState() => _AppearanceSettingState();
}

class _AppearanceSettingState extends State<AppearanceSetting> {
  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final code = _localeCode();
    final languageEntry = languageOptions.firstWhere((e) => e.values.first == code, orElse: () => languageOptions[0]);
    final languageName = languageEntry.values.first == 'System' ? l10n.settingsSystemMode : languageEntry.keys.first;

    return settingsSections(
      sections: [
        SettingsSection(
          title: Text(l10n.settingsAppearanceTheme),
          tiles: [
            const CustomSettingsTile(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: ChangeThemeMode(),
              ),
            ),
            SettingsTile.switchTile(
              title: Text(l10n.eInkMode),
              leading: const Icon(Icons.contrast),
              initialValue: Prefs().eInkMode,
              onToggle: (bool value) {
                setState(() {
                  Prefs().saveThemeModeToPrefs('light');
                  Prefs().eInkMode = value;
                });
              },
            ),
          ],
        ),
        SettingsSection(
          title: Text(l10n.settingsAppearanceDisplay),
          tiles: [
            SettingsTile.navigation(
              title: Text(l10n.settingsAppearanceLanguage),
              value: Text(languageName),
              leading: const Icon(Icons.language),
              onPressed: (context) => showLanguagePickerDialog(context),
            ),
            SettingsTile.switchTile(
              title: Text(l10n.settingsAppearanceOpenBookAnimation),
              leading: const Icon(Icons.animation),
              initialValue: Prefs().openBookAnimation,
              onToggle: (bool value) => setState(() => Prefs().openBookAnimation = value),
            ),
            SettingsTile.switchTile(
              title: Text(l10n.reduceVibrationFeedback),
              leading: const Icon(Icons.vibration),
              initialValue: Prefs().reduceVibrationFeedback,
              onToggle: (bool value) => setState(() => Prefs().reduceVibrationFeedback = value),
            ),
            SettingsTile.switchTile(
              title: Text(l10n.readingPageShowActionLabels),
              leading: const Icon(Icons.subtitles_outlined),
              initialValue: Prefs().showActionLabels,
              onToggle: (bool value) => setState(() => Prefs().showActionLabels = value),
            ),
          ],
        ),
        SettingsSection(
          title: Text(l10n.settingsBookshelfCover),
          tiles: [
            CustomSettingsTile(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text(l10n.settingsBookshelfCoverWidth, style: const TextStyle(fontSize: 16))),
                        Text(Prefs().bookCoverWidth.toStringAsFixed(0),
                            style: TextStyle(fontSize: 15, color: palette.secondaryLabel)),
                      ],
                    ),
                    Slider(
                      value: Prefs().bookCoverWidth,
                      onChanged: (value) => setState(() => Prefs().bookCoverWidth = value),
                      max: 260,
                      min: 80,
                      divisions: 18,
                    ),
                  ],
                ),
              ),
            ),
            CustomSettingsTile(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.settingsBookshelfFolderStyle, style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 10),
                    AnxSegmentedButton<BookshelfFolderStyle>(
                      segments: [
                        SegmentButtonItem(
                          label: l10n.settingsBookshelfFolderStyleOverlap,
                          value: BookshelfFolderStyle.stacked,
                          icon: const Icon(Icons.layers_outlined),
                        ),
                        SegmentButtonItem(
                          label: l10n.settingsBookshelfFolderStyleGrid,
                          value: BookshelfFolderStyle.grid2x2,
                          icon: const Icon(Icons.grid_view),
                        ),
                      ],
                      selected: {Prefs().bookshelfFolderStyle},
                      onSelectionChanged: (value) => setState(() => Prefs().bookshelfFolderStyle = value.first),
                    ),
                  ],
                ),
              ),
            ),
            SettingsTile.switchTile(
              title: Text(l10n.settingsBookshelfDefaultCoverShowTitle),
              leading: const Icon(Icons.title),
              initialValue: Prefs().showBookTitleOnDefaultCover,
              onToggle: (bool value) => setState(() => Prefs().showBookTitleOnDefaultCover = value),
            ),
            SettingsTile.switchTile(
              title: Text(l10n.settingsBookshelfDefaultCoverShowAuthor),
              leading: const Icon(Icons.person_outline),
              initialValue: Prefs().showAuthorOnDefaultCover,
              onToggle: (bool value) => setState(() => Prefs().showAuthorOnDefaultCover = value),
            ),
          ],
        ),
      ],
    );
  }
}

/// Language choice in a sheet; the locale switches immediately.
void showLanguagePickerDialog(BuildContext context) {
  final l10n = L10n.of(context);
  final current = _localeCode();
  showMgSheet(
    context: context,
    title: l10n.settingsAppearanceLanguage,
    builder: (context) => MgSheetGroup(children: [
      for (final option in languageOptions)
        MgSheetOption(
          title: option.values.first == 'System' ? l10n.settingsSystemMode : option.keys.first,
          selected: option.values.first == current,
          onTap: () {
            Navigator.of(context).pop();
            Prefs().saveLocaleToPrefs(option.values.first);
          },
        ),
    ]),
  );
}
