import 'dart:async';

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_catalog_page.dart';
import 'package:anx_reader/page/bookstore/store_widgets.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/bookstore/bookstore_api.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Searches the bookstore as the user types (debounced); popular tags fill the empty state.
class StoreSearchPage extends ConsumerStatefulWidget {
  const StoreSearchPage({super.key, this.initialQuery = ''});

  final String initialQuery;

  @override
  ConsumerState<StoreSearchPage> createState() => _StoreSearchPageState();
}

class _StoreSearchPageState extends ConsumerState<StoreSearchPage> {
  late final _controller = TextEditingController(text: widget.initialQuery);
  Timer? _debounce;
  String _query = '';
  StorePager? _pager;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) _search(widget.initialQuery);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _pager?.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _search(String value) {
    final query = value.trim();
    if (query == _query) return;
    setState(() {
      _query = query;
      _pager?.dispose();
      _pager = query.isEmpty
          ? null
          : (StorePager((offset, limit) =>
              BookstoreApi.instance.search(query, offset: offset, limit: limit))
            ..more());
    });
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () => _search(value));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final pager = _pager;
    final tags = ref.watch(storeHomeProvider).valueOrNull?.tags ?? const [];
    return MgPage(
      title: l10n.navBarSearch,
      header: MgReadable(
        maxWidth: mgDetailWidth,
        child: MgSearchField(
          controller: _controller,
          placeholder: l10n.storeSearchHint,
          autofocus: widget.initialQuery.isEmpty,
          onChanged: _onChanged,
          onSubmitted: _search,
        ),
      ),
      body: pager == null
          ? ListView(
              padding: EdgeInsets.symmetric(
                  horizontal: MgShelfMetrics.of(context).inset, vertical: 12),
              children: [
                if (tags.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final tag in tags)
                        MgChip(
                          label: tag.name,
                          selected: false,
                          checkmark: false,
                          onTap: () => Navigator.of(context).push(CupertinoPageRoute(
                            builder: (_) => StoreCatalogPage(tags: [tag.name]),
                          )),
                        ),
                    ],
                  ),
              ],
            )
          : CustomScrollView(
              key: ValueKey(_query),
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              slivers: [
                StorePagedSliver(
                  pager: pager,
                  itemBuilder: (context, book, _) => StoreBookTile(book: book),
                ),
              ],
            ),
    );
  }
}
