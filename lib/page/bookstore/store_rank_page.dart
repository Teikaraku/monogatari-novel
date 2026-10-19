import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:flutter/material.dart';

/// Charts as one ranked list per board: popularity, saves, rising, completed, length, volumes and
/// new arrivals. Popularity and completed take a period.
class StoreRankPage extends StatefulWidget {
  const StoreRankPage({super.key, this.board = StoreBoard.popular});

  final StoreBoard board;

  @override
  State<StoreRankPage> createState() => _StoreRankPageState();
}

class _StoreRankPageState extends State<StoreRankPage> {
  late StoreBoard _board = widget.board;
  StoreRankPeriod _period = StoreRankPeriod.week;
  final _pagers = <String, StorePager>{};

  String get _key => _board.periodic ? '${_board.name}:${_period.name}' : _board.name;

  StorePager get _pager => _pagers[_key] ??= StorePager(
        (offset, limit) => BookstoreApi.instance.rank(_period, board: _board, offset: offset, limit: limit),
        pageSize: 50,
      )..more();

  @override
  void dispose() {
    for (final pager in _pagers.values) {
      pager.dispose();
    }
    super.dispose();
  }

  String _boardLabel(L10n l10n, StoreBoard board) => switch (board) {
        StoreBoard.popular => l10n.storeBoardPopular,
        StoreBoard.shelf => l10n.storeBoardShelf,
        StoreBoard.rising => l10n.storeBoardRising,
        StoreBoard.completed => l10n.storeBoardCompleted,
        StoreBoard.words => l10n.storeBoardWords,
        StoreBoard.volumes => l10n.storeBoardVolumes,
        StoreBoard.newest => l10n.storeBoardNew,
      };

  /// The board's own figure; words and volumes already sit in the meta line.
  String? _extra(L10n l10n, StoreBook book) {
    final score = book.score ?? book.readers ?? 0;
    if (score <= 0) return null;
    return switch (_board) {
      StoreBoard.popular || StoreBoard.completed => l10n.storeReaders(score),
      StoreBoard.shelf => l10n.storeSaves(score),
      StoreBoard.rising => l10n.storeRising(score),
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final pager = _pager;
    final inset = MgShelfMetrics.of(context).inset;
    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.fromLTRB(inset, 2, inset, 0),
          child: Row(children: [
            for (final board in StoreBoard.values)
              _BoardTab(
                label: _boardLabel(l10n, board),
                selected: board == _board,
                onTap: () => setState(() => _board = board),
              ),
          ]),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          child: _board.periodic
              ? Padding(
                  padding: EdgeInsets.fromLTRB(inset, 10, inset, 0),
                  child: Row(children: [
                    for (final (period, label) in [
                      (StoreRankPeriod.day, l10n.storeRankDay),
                      (StoreRankPeriod.week, l10n.storeRankWeek),
                      (StoreRankPeriod.month, l10n.storeRankMonth),
                      (StoreRankPeriod.total, l10n.storeRankTotal),
                    ]) ...[
                      MgChip(
                        label: label,
                        selected: period == _period,
                        checkmark: false,
                        onTap: () => setState(() => _period = period),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ]),
                )
              : const SizedBox(width: double.infinity),
        ),
        const SizedBox(height: 8),
      ],
    );
    return MgPage(
      title: l10n.storeRankings,
      header: header,
      body: ListenableBuilder(
        listenable: pager,
        builder: (context, _) {
          final items = pager.items;
          if (items.isEmpty) {
            if (pager.error != null) {
              return MgEmptyState(
                  icon: Icons.wifi_off, title: l10n.storeOffline, action: l10n.storeRetry, onAction: pager.more);
            }
            if (pager.done) return MgEmptyState(icon: Icons.bar_chart, title: l10n.storeRankEmpty);
            return const Center(child: CircularProgressIndicator(strokeWidth: 2));
          }
          final listInset = 16 + mgCenteredInset(context, mgDetailWidth);
          return RefreshIndicator(
            onRefresh: pager.reset,
            child: CustomScrollView(
              key: PageStorageKey(_key),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(listInset, 4, listInset, 0),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        if (index >= items.length - 10 && !pager.done && !pager.loading) {
                          WidgetsBinding.instance.addPostFrameCallback((_) => pager.more());
                        }
                        final book = items[index];
                        return StoreBookTile(
                          book: book,
                          compact: index >= 3,
                          coverWidth: index < 3 ? 64 : 52,
                          leading: StoreRankNumber(rank: index + 1),
                          extra: _extra(l10n, book),
                        );
                      },
                      childCount: items.length,
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: SizedBox(
                    height: 48 + MediaQuery.paddingOf(context).bottom,
                    child: pager.loading
                        ? const Center(
                            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                        : null,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A text tab with an accent underline when selected.
class _BoardTab extends StatelessWidget {
  const _BoardTab({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 18, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 150),
              style: TextStyle(
                fontSize: selected ? 18 : 16,
                fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                color: selected ? Theme.of(context).colorScheme.onSurface : MgPalette.of(context).secondaryLabel,
              ),
              child: Text(label),
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 3,
              width: selected ? 20 : 0,
              decoration: BoxDecoration(color: accent, borderRadius: BorderRadius.circular(2)),
            ),
          ],
        ),
      ),
    );
  }
}
