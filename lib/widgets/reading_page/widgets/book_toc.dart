import 'package:anx_reader/main.dart';
import 'package:anx_reader/models/search_result_model.dart';
import 'package:anx_reader/models/toc_item.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/providers/book_toc.dart';
import 'package:anx_reader/providers/toc_search.dart';
import 'package:anx_reader/widgets/common/container/filled_container.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class BookToc extends ConsumerStatefulWidget {
  const BookToc({
    super.key,
    required this.epubPlayerKey,
    required this.hideAppBarAndBottomBar,
    required this.closeDrawer,
  });

  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final Function hideAppBarAndBottomBar;
  final VoidCallback closeDrawer;

  @override
  ConsumerState<BookToc> createState() => _BookTocState();
}

class _BookTocState extends ConsumerState<BookToc> {
  final TextEditingController searchBarController = TextEditingController();
  final ScrollController searchResultsScrollController = ScrollController();
  late List<TocItem> tocItems;
  List<_VisibleTocEntry> _visibleItems = const [];
  final Set<String> _expandedItemKeys = {};
  final ItemScrollController _itemScrollController = ItemScrollController();
  final ItemPositionsListener _itemPositionsListener =
      ItemPositionsListener.create();
  String? _lastAutoScrolledHref;
  String? _pendingScrollKey;
  bool _pendingScrollAnimated = false;
  bool _hasRestoredScrollPosition = false;

  @override
  void initState() {
    super.initState();
    searchBarController.text = ref.read(tocSearchProvider).query ?? '';
    // Add listener to save scroll position
    searchResultsScrollController.addListener(_saveScrollPosition);
  }

  void _saveScrollPosition() {
    if (searchResultsScrollController.hasClients) {
      ref.read(tocSearchProvider.notifier).updateScrollOffset(
            searchResultsScrollController.offset,
          );
    }
  }

  @override
  void dispose() {
    searchBarController.dispose();
    searchResultsScrollController.dispose();
    super.dispose();
  }

  String _keyForItem(TocItem item) => '${item.id}_${item.href}';

  List<TocItem>? _findPath(List<TocItem> items, String href) {
    for (final item in items) {
      if (item.href == href) {
        return [item];
      }
      final nested = _findPath(item.subitems, href);
      if (nested != null) {
        return [item, ...nested];
      }
    }
    return null;
  }

  void _ensureItemVisible(TocItem item, {bool animated = false}) {
    if (!mounted) {
      return;
    }
    final path = _findPath(tocItems, item.href);
    if (path == null) {
      return;
    }

    final keysToExpand = <String>{};
    for (final ancestor in path) {
      if (ancestor.subitems.isNotEmpty) {
        final key = _keyForItem(ancestor);
        if (!_expandedItemKeys.contains(key)) {
          keysToExpand.add(key);
        }
      }
    }

    void scheduleScroll() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final key = _keyForItem(item);
        if (!_itemScrollController.isAttached) {
          _pendingScrollKey = key;
          _pendingScrollAnimated = animated;
          return;
        }
        final index = _visibleItems.indexWhere((entry) => entry.key == key);
        if (index == -1) {
          _pendingScrollKey = key;
          _pendingScrollAnimated = animated;
          return;
        }
        _pendingScrollKey = null;
        _pendingScrollAnimated = false;
        final duration = animated
            ? const Duration(milliseconds: 250)
            : const Duration(milliseconds: 1);
        _itemScrollController.scrollTo(
          index: index,
          duration: duration,
          curve: Curves.easeInOut,
          alignment: 0.0,
        );
      });
    }

    if (keysToExpand.isNotEmpty) {
      setState(() {
        _expandedItemKeys.addAll(keysToExpand);
      });
    }
    scheduleScroll();
  }

  void _scrollToCurrent({bool animated = false}) {
    final currentHref = widget.epubPlayerKey.currentState?.chapterHref ?? '';
    if (currentHref.isEmpty) {
      return;
    }
    final path = _findPath(tocItems, currentHref);
    if (path == null || path.isEmpty) {
      return;
    }
    _ensureItemVisible(path.last, animated: animated);
  }

  void _toggleExpanded(TocItem item) {
    final key = _keyForItem(item);
    setState(() {
      if (_expandedItemKeys.contains(key)) {
        _expandedItemKeys.remove(key);
      } else {
        _expandedItemKeys.add(key);
      }
    });
  }

  void _pruneExpandedKeys(List<TocItem> items) {
    final validKeys = <String>{};

    void collect(List<TocItem> children) {
      for (final child in children) {
        final key = _keyForItem(child);
        validKeys.add(key);
        if (child.subitems.isNotEmpty) {
          collect(child.subitems);
        }
      }
    }

    collect(items);
    _expandedItemKeys.removeWhere((key) => !validKeys.contains(key));
  }

  List<_VisibleTocEntry> _buildVisibleItems(List<TocItem> items) {
    final entries = <_VisibleTocEntry>[];

    void visit(List<TocItem> nodes, int depth) {
      for (final node in nodes) {
        final key = _keyForItem(node);
        final isExpanded = _expandedItemKeys.contains(key);
        entries.add(
          _VisibleTocEntry(
            item: node,
            key: key,
            depth: depth,
            isExpanded: isExpanded,
          ),
        );
        if (node.subitems.isNotEmpty && isExpanded) {
          visit(node.subitems, depth + 1);
        }
      }
    }

    visit(items, 0);
    return entries;
  }

  void _fulfillPendingScrollIfPossible() {
    if (!mounted) {
      return;
    }
    final pendingKey = _pendingScrollKey;
    if (pendingKey == null) {
      return;
    }
    if (!_itemScrollController.isAttached) {
      return;
    }

    final index = _visibleItems.indexWhere((entry) => entry.key == pendingKey);
    if (index == -1) {
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      if (!_itemScrollController.isAttached) {
        return;
      }
      _pendingScrollKey = null;
      final duration = _pendingScrollAnimated
          ? const Duration(milliseconds: 250)
          : const Duration(milliseconds: 1);
      _pendingScrollAnimated = false;
      _itemScrollController.scrollTo(
        index: index,
        duration: duration,
        curve: Curves.easeInOut,
        alignment: 0.0,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    tocItems = ref.watch(bookTocProvider);
    _pruneExpandedKeys(tocItems);
    _visibleItems = _buildVisibleItems(tocItems);
    _fulfillPendingScrollIfPossible();
    final tocSearchState = ref.watch(tocSearchProvider);
    final currentQuery = tocSearchState.query ?? '';
    if (searchBarController.text != currentQuery) {
      searchBarController.value = TextEditingValue(
        text: currentQuery,
        selection: TextSelection.collapsed(offset: currentQuery.length),
      );
    }
    final isSearchActive = tocSearchState.isActive;
    final searchResults = tocSearchState.results;
    final showSearchProgress = tocSearchState.isSearching;
    final progressValue = tocSearchState.progress <= 0.0
        ? null
        : tocSearchState.progress.clamp(0.0, 1.0);

    // Restore scroll position when search results are available (only once)
    if (isSearchActive &&
        searchResults.isNotEmpty &&
        !_hasRestoredScrollPosition &&
        tocSearchState.scrollOffset > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && searchResultsScrollController.hasClients) {
          final targetOffset = tocSearchState.scrollOffset.clamp(
            0.0,
            searchResultsScrollController.position.maxScrollExtent,
          );
          searchResultsScrollController.jumpTo(targetOffset);
          _hasRestoredScrollPosition = true;
        }
      });
    }

    // Reset the flag when search becomes inactive
    if (!isSearchActive && _hasRestoredScrollPosition) {
      _hasRestoredScrollPosition = false;
    }

    final currentHref = widget.epubPlayerKey.currentState?.chapterHref ?? '';
    final currentPath = currentHref.isEmpty
        ? <TocItem>[]
        : (_findPath(tocItems, currentHref) ?? <TocItem>[]);

    if (!isSearchActive &&
        currentHref.isNotEmpty &&
        currentHref != _lastAutoScrolledHref &&
        currentPath.isNotEmpty) {
      _lastAutoScrolledHref = currentHref;
      final target = currentPath.last;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _ensureItemVisible(target);
      });
    }

    final selectedKeys = currentPath.map(_keyForItem).toSet();
    final currentState = widget.epubPlayerKey.currentState;
    final currentProgress = currentState == null
        ? ''
        : '${currentState.chapterCurrentPage} / ${currentState.chapterTotalPages}';

    var locatingButton = IconButton(
      icon: Icon(Icons.my_location, color: MgPalette.of(context).secondaryLabel),
      tooltip: L10n.of(context).readerCurrent,
      onPressed: () {
        _scrollToCurrent(animated: true);
      },
    );

    var searchBox = MgSearchField(
      controller: searchBarController,
      placeholder: L10n.of(context).readerSearchBook,
      padding: EdgeInsets.zero,
      onChanged: (value) {
        if (value.trim().isEmpty && isSearchActive) {
          widget.epubPlayerKey.currentState?.clearSearch();
        }
      },
      onSubmitted: (value) {
        final trimmed = value.trim();
        if (trimmed.isEmpty) {
          searchBarController.clear();
          widget.epubPlayerKey.currentState?.clearSearch();
        } else {
          widget.epubPlayerKey.currentState?.search(trimmed);
        }
      },
    );
    final bottomInset = MediaQuery.paddingOf(context).bottom + 24;
    var searchResult = Expanded(
        child: Column(
      children: [
        const SizedBox(height: 6.0),
        if (showSearchProgress)
          LinearProgressIndicator(
            value: progressValue,
          ),
        Expanded(
          child: searchResults.isEmpty
              ? const SizedBox()
              : ListView.builder(
                  controller: searchResultsScrollController,
                  padding: EdgeInsets.only(bottom: bottomInset),
                  itemCount: searchResults.length,
                  itemBuilder: (context, index) {
                    return searchResultWidget(
                      searchResult: searchResults[index],
                      hideAppBarAndBottomBar: widget.hideAppBarAndBottomBar,
                      epubPlayerKey: widget.epubPlayerKey,
                      closeDrawer: widget.closeDrawer,
                    );
                  },
                ),
        ),
      ],
    ));
    final columnChildren = <Widget>[
      Row(
        children: [
          Expanded(child: searchBox),
          if (!isSearchActive) locatingButton,
        ],
      ),
    ];

    columnChildren.add(
      isSearchActive
          ? searchResult
          : Expanded(
              child: ScrollablePositionedList.builder(
                padding: EdgeInsets.only(bottom: bottomInset),
                itemScrollController: _itemScrollController,
                itemPositionsListener: _itemPositionsListener,
                itemCount: _visibleItems.length,
                itemBuilder: (context, index) {
                  final entry = _visibleItems[index];
                  final tocItem = entry.item;
                  final key = entry.key;
                  final isSelected = selectedKeys.contains(key);
                  final isCurrentLeaf =
                      currentHref == tocItem.href && tocItem.subitems.isEmpty;

                  return TocItemWidget(
                    tocItem: tocItem,
                    depth: entry.depth,
                    isExpanded: entry.isExpanded,
                    isSelected: isSelected,
                    showProgress: isCurrentLeaf,
                    progressText: currentProgress,
                    onToggle: tocItem.subitems.isEmpty
                        ? null
                        : () => _toggleExpanded(tocItem),
                    onTap: () {
                      widget.hideAppBarAndBottomBar(false);
                      widget.epubPlayerKey.currentState!.goToHref(tocItem.href);
                      widget.closeDrawer();
                    },
                  );
                },
              ),
            ),
    );
    return Column(children: columnChildren);
  }
}

Widget searchResultWidget({
  required SearchResultModel searchResult,
  required Function hideAppBarAndBottomBar,
  required GlobalKey<EpubPlayerState> epubPlayerKey,
  required VoidCallback closeDrawer,
}) {
  bool isExpanded = true;
  TextStyle matchStyle = TextStyle(
    color: Theme.of(navigatorKey.currentContext!).colorScheme.primary,
    fontWeight: FontWeight.bold,
  );
  TextStyle prePostStyle = const TextStyle(
    color: Colors.grey,
  );
  return StatefulBuilder(
    builder: (context, setState) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton(
            onPressed: () {
              setState(() {
                isExpanded = !isExpanded;
              });
            },
            child: Row(
              children: [
                Flexible(child: Text(searchResult.label)),
                isExpanded
                    ? const Icon(Icons.expand_less)
                    : const Icon(Icons.expand_more),
                // const Spacer(),
                Text(
                  searchResult.subitems.length.toString(),
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
          ),
          if (isExpanded)
            for (var subItem in searchResult.subitems)
              FilledContainer(
                margin: EdgeInsets.only(bottom: 5),
                width: double.infinity,
                padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                radius: 10,
                child: InkWell(
                  onTap: () {
                    hideAppBarAndBottomBar(false);
                    epubPlayerKey.currentState!.goToCfi(subItem.cfi);
                    closeDrawer();
                  },
                  child: RichText(
                    text: TextSpan(
                      children: [
                        TextSpan(text: subItem.pre, style: prePostStyle),
                        TextSpan(text: subItem.match, style: matchStyle),
                        TextSpan(text: subItem.post, style: prePostStyle),
                      ],
                    ),
                  ),
                ),
              ),
        ],
      );
    },
  );
}

class TocItemWidget extends StatelessWidget {
  const TocItemWidget({
    super.key,
    required this.tocItem,
    required this.depth,
    required this.isExpanded,
    required this.isSelected,
    required this.showProgress,
    required this.progressText,
    required this.onToggle,
    required this.onTap,
  });

  final TocItem tocItem;
  final int depth;
  final bool isExpanded;
  final bool isSelected;
  final bool showProgress;
  final String progressText;
  final VoidCallback? onToggle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final indent = 4.0 + depth * 16.0;
    return InkWell(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 50),
        padding: EdgeInsets.only(left: indent, right: 4),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: palette.separator, width: .5)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: tocItem.subitems.isEmpty
                  ? (showProgress
                      ? Center(
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(color: scheme.primary, shape: BoxShape.circle),
                          ),
                        )
                      : null)
                  : InkResponse(
                      onTap: onToggle,
                      radius: 18,
                      child: Icon(isExpanded ? Icons.expand_more : Icons.chevron_right,
                          size: 20, color: palette.secondaryLabel),
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tocItem.label.trim(),
                      style: TextStyle(
                        fontSize: depth == 0 ? 15 : 14,
                        height: 1.35,
                        fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                        color: isSelected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                    if (showProgress && progressText.trim() != '/')
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          '${L10n.of(context).readerCurrent} · $progressText',
                          style: TextStyle(fontSize: 12, color: scheme.primary.withValues(alpha: .8)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              tocItem.percentage,
              style: TextStyle(
                fontSize: 12,
                color: isSelected ? scheme.primary : palette.secondaryLabel,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VisibleTocEntry {
  const _VisibleTocEntry({
    required this.item,
    required this.key,
    required this.depth,
    required this.isExpanded,
  });

  final TocItem item;
  final String key;
  final int depth;
  final bool isExpanded;
}
