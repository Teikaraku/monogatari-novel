import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:anx_reader/widgets/settings/service_config_form.dart';
import 'package:anx_reader/widgets/settings/settings_section.dart';
import 'package:anx_reader/widgets/settings/settings_tile.dart';
import 'package:anx_reader/widgets/settings/settings_title.dart';
import 'package:flutter/material.dart';

class TranslateSetting extends StatefulWidget {
  const TranslateSetting({super.key});

  @override
  State<TranslateSetting> createState() => _TranslateSettingState();
}

class _TranslateSettingState extends State<TranslateSetting> {
  Future<void> _pick<T>(String title, List<(T, String)> options, T selected, ValueChanged<T> onPicked) async {
    await showMgSheet(
      context: context,
      title: title,
      builder: (sheet) => MgSheetGroup(children: [
        for (final (value, label) in options)
          MgSheetOption(
            title: label,
            selected: value == selected,
            onTap: () {
              Navigator.of(sheet).pop();
              onPicked(value);
            },
          ),
      ]),
    );
    if (mounted) setState(() {});
  }

  /// A service's settings in a sheet.
  Future<void> _configure(TranslateService service) => showMgSheet(
        context: context,
        title: service.getLabel(context),
        builder: (_) => _ServiceConfigSheet(service: service),
      );

  List<(LangListEnum, String)> _languages(BuildContext context) =>
      [for (final lang in LangListEnum.values) (lang, lang.getNative(context))];

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final services = [for (final s in TranslateService.activeValues) (s, s.getLabel(context))];
    // Only services with something to set up (keys, endpoints); the free ones work as they are.
    final configurable = [
      for (final s in TranslateService.activeValues)
        if (getTranslateServiceConfigItems(context, s).isNotEmpty) s,
    ];
    final fullTextServices = [
      for (final s in TranslateService.activeValues.where((s) => !s.isWebView)) (s, s.getLabel(context)),
    ];
    return settingsSections(
      sections: [
        SettingsSection(
          title: Text(l10n.underlineTranslation),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.translate),
              title: Text(l10n.translateServiceLabel),
              value: Text(Prefs().translateService.getLabel(context)),
              onPressed: (_) => _pick(l10n.translateServiceLabel, services, Prefs().translateService,
                  (v) => Prefs().translateService = v),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.input),
              title: Text(l10n.translateFromLang),
              value: Text(Prefs().translateFrom.getNative(context)),
              onPressed: (_) => _pick(
                  l10n.translateFromLang, _languages(context), Prefs().translateFrom, (v) => Prefs().translateFrom = v),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.output),
              title: Text(l10n.translateToLang),
              value: Text(Prefs().translateTo.getNative(context)),
              onPressed: (_) => _pick(
                  l10n.translateToLang, _languages(context), Prefs().translateTo, (v) => Prefs().translateTo = v),
            ),
            SettingsTile.switchTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: Text(l10n.readingPageAutoTranslateSelection),
              initialValue: Prefs().autoTranslateSelection,
              onToggle: (value) => setState(() => Prefs().autoTranslateSelection = value),
            ),
          ],
        ),
        SettingsSection(
          title: Text(l10n.fullTextTranslation),
          tiles: [
            SettingsTile.navigation(
              leading: const Icon(Icons.translate),
              title: Text(l10n.translateServiceLabel),
              value: Text(Prefs().fullTextTranslateService.getLabel(context)),
              onPressed: (_) => _pick(l10n.translateServiceLabel, fullTextServices, Prefs().fullTextTranslateService,
                  (v) => Prefs().fullTextTranslateService = v),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.input),
              title: Text(l10n.translateFromLang),
              value: Text(Prefs().fullTextTranslateFrom.getNative(context)),
              onPressed: (_) => _pick(l10n.translateFromLang, _languages(context), Prefs().fullTextTranslateFrom,
                  (v) => Prefs().fullTextTranslateFrom = v),
            ),
            SettingsTile.navigation(
              leading: const Icon(Icons.output),
              title: Text(l10n.translateToLang),
              value: Text(Prefs().fullTextTranslateTo.getNative(context)),
              onPressed: (_) => _pick(l10n.translateToLang, _languages(context), Prefs().fullTextTranslateTo,
                  (v) => Prefs().fullTextTranslateTo = v),
            ),
          ],
        ),
        if (configurable.isNotEmpty)
          SettingsSection(
            title: Text(l10n.translationServiceConfiguration),
            tiles: [
              for (final service in configurable)
                SettingsTile.navigation(
                  leading: const Icon(Icons.tune),
                  title: Text(service.getLabel(context)),
                  onPressed: (_) => _configure(service),
                ),
            ],
          ),
      ],
    );
  }
}

/// The config form, then "test" (saves and translates a sample with this service) and "save".
class _ServiceConfigSheet extends StatefulWidget {
  const _ServiceConfigSheet({required this.service});

  final TranslateService service;

  @override
  State<_ServiceConfigSheet> createState() => _ServiceConfigSheetState();
}

class _ServiceConfigSheetState extends State<_ServiceConfigSheet> {
  late Map<String, dynamic> _config = getTranslateServiceConfig(widget.service);
  String? _result;
  bool _testing = false;

  Future<void> _test() async {
    saveTranslateServiceConfig(widget.service, _config);
    setState(() {
      _testing = true;
      _result = null;
    });
    String result;
    try {
      result = await translateTextOnly('Hello, world!', service: widget.service);
    } catch (e) {
      result = e.toString();
    }
    if (mounted) {
      setState(() {
        _testing = false;
        _result = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ServiceConfigForm(
            configItems: getTranslateServiceConfigItems(context, widget.service),
            initialConfig: _config,
            onConfigChanged: (value) => _config = value,
          ),
          if (_testing || _result != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: mgSheetGroupColor(context), borderRadius: BorderRadius.circular(10)),
              child: _testing
                  ? const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  : Text(_result!, style: const TextStyle(fontSize: 15, height: 1.45)),
            ),
          ],
          const SizedBox(height: 16),
          MgSheetButtons(
            secondary: l10n.commonTest,
            onSecondary: _testing ? null : _test,
            primary: l10n.commonSave,
            onPrimary: () {
              saveTranslateServiceConfig(widget.service, _config);
              AnxToast.show(l10n.commonSaved);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }
}
