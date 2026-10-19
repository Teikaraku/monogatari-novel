import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/dao/reading_time.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/home_page.dart';
import 'package:anx_reader/page/home_page/notes_page.dart';
import 'package:anx_reader/page/home_page/statistics_page.dart';
import 'package:anx_reader/page/settings_page/about_page.dart';
import 'package:anx_reader/page/settings_page/advanced.dart';
import 'package:anx_reader/page/settings_page/ai.dart';
import 'package:anx_reader/page/settings_page/appearance.dart';
import 'package:anx_reader/page/settings_page/developer/developer_options_page.dart';
import 'package:anx_reader/page/settings_page/narrate.dart';
import 'package:anx_reader/page/settings_page/reading.dart';
import 'package:anx_reader/page/settings_page/settings_page.dart';
import 'package:anx_reader/page/settings_page/storege.dart';
import 'package:anx_reader/page/settings_page/sync.dart';
import 'package:anx_reader/page/settings_page/transfer.dart';
import 'package:anx_reader/page/settings_page/translate.dart';
import 'package:anx_reader/utils/env_var.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class _Entry {
  const _Entry(this.title, this.icon, this.color, this.page, {this.grouped = true});

  final String title;
  final IconData icon;
  final Color color;
  final Widget Function() page;

  /// Settings categories are grouped lists; statistics and notes are plain pages.
  final bool grouped;
}

class _Summary {
  const _Summary(this.today, this.total, this.books);

  final int today;
  final int total;
  final int books;
}

Future<_Summary> _loadSummary() async {
  final now = DateTime.now();
  final results = await Future.wait([
    readingTimeDao.selectReadingTimeOfWeek(now),
    readingTimeDao.selectTotalReadingTime(),
    readingTimeDao.selectTotalNumberOfBook(),
  ]);
  final week = results[0] as List<int>;
  return _Summary(week[now.weekday - 1], results[1] as int, results[2] as int);
}

/// Settings root in the 物语 style: large title, a reading summary, a search field and
/// colored-icon groups.
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  String _query = '';
  late Future<_Summary> _summary = _loadSummary();

  void _reloadSummary() => setState(() { _summary = _loadSummary(); });

  Future<void> _open(_Entry entry) async {
    await Navigator.of(context).push(CupertinoPageRoute(
      builder: (context) => entry.grouped
          ? SettingsPageBody(title: entry.title, isMobile: true, sections: entry.page())
          : entry.page(),
    ));
    if (mounted) _reloadSummary();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(homeTabProvider, (_, tab) {
      if (tab == 4) _reloadSummary();
    });
    final l10n = L10n.of(context);
    final stats = _Entry(l10n.mgReadingStats, Icons.bar_chart, MgColors.indigo,
        () => MgSubPage(title: l10n.mgReadingStats, grouped: false, body: const StatisticPage()),
        grouped: false);
    final reading = [
      _Entry(l10n.settingsAppearance, Icons.text_fields, MgColors.blue, () => const AppearanceSetting()),
      _Entry(l10n.settingsReading, Icons.menu_book, MgColors.green, () => const ReadingSettings()),
      _Entry(l10n.settingsNarrate, Icons.headphones, MgColors.orange, () => const NarrateSettings()),
      _Entry(l10n.settingsTranslate, Icons.translate, MgColors.indigo, () => const TranslateSetting()),
      if (EnvVar.enableAIFeature)
        _Entry(l10n.settingsAi, Icons.auto_awesome, MgColors.purple, () => const AISettings()),
    ];
    final library = [
      stats,
      _Entry(l10n.navBarNotes, Icons.sticky_note_2_outlined, MgColors.yellow,
          () => MgSubPage(title: l10n.navBarNotes, grouped: false, body: const NotesPage()),
          grouped: false),
      _Entry(l10n.transferTitle, Icons.swap_vert, MgColors.blue, () => const TransferSettings()),
      _Entry(l10n.settingsSync, Icons.sync, MgColors.teal, () => const SyncSetting()),
      _Entry(l10n.storage, Icons.storage, MgColors.pink, () => const StorageSettings()),
    ];
    final other = [
      _Entry(l10n.settingsAdvanced, Icons.settings, MgColors.gray, () => const AdvancedSetting()),
      _Entry(l10n.mgAbout, Icons.info_outline, MgColors.gray, () => const AboutPage(), grouped: false),
      if (Prefs().developerOptionsEnabled)
        _Entry('Developer Options', Icons.developer_mode, MgColors.gray, () => const DeveloperOptionsPage(),
            grouped: false),
    ];
    final query = _query.trim().toLowerCase();
    bool matches(_Entry entry) => query.isEmpty || entry.title.toLowerCase().contains(query);

    Widget group(List<_Entry> entries) {
      final visible = entries.where(matches).toList();
      if (visible.isEmpty) return const SizedBox.shrink();
      return MgGroup(children: [
        for (final entry in visible)
          MgRow(
            title: entry.title,
            icon: entry.icon,
            iconColor: entry.color,
            onTap: () => _open(entry),
          ),
      ]);
    }

    return MgPage(
      title: l10n.navBarSettings,
      grouped: true,
      showBack: false,
      contentWidth: mgReadableWidth,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          MgReadable(
            child: MgSearchField(
              placeholder: l10n.navBarSearch,
              onChanged: (value) => setState(() => _query = value),
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
            ),
          ),
          if (query.isEmpty)
            FutureBuilder<_Summary>(
              future: _summary,
              builder: (context, snapshot) => _SummaryCard(summary: snapshot.data, onTap: () => _open(stats)),
            ),
          group(reading),
          group(library),
          group(other),
        ],
      ),
    );
  }
}

/// Today's reading, total time and books read; opens the statistics page.
class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary, required this.onTap});

  final _Summary? summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    Widget cell(String figure, String label) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
              const SizedBox(height: 4),
              MgFigure(figure, size: 20),
            ],
          ),
        );
    return MgReadable(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Material(
          color: palette.card,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Row(
                children: [
                  cell(mgDuration(l10n, summary?.today ?? 0), l10n.settingsSummaryToday),
                  cell(mgDuration(l10n, summary?.total ?? 0), l10n.settingsSummaryTotal),
                  cell(l10n.mgBookCount(summary?.books ?? 0), l10n.settingsSummaryBooks),
                  Icon(Icons.chevron_right, color: palette.secondaryLabel.withValues(alpha: .7)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
