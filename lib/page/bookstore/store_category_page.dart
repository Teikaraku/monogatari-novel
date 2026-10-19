import 'dart:math' as math;

import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/bookstore/store_catalog_page.dart';
import 'package:anx_reader/providers/bookstore.dart';
import 'package:anx_reader/service/bookstore/bookstore_models.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Categories: the big genres as colored tiles with fanned covers, then every tag with its count.
class StoreCategoryPage extends ConsumerWidget {
  const StoreCategoryPage({super.key});

  static const _tileColors = [
    MgColors.pink,
    MgColors.blue,
    MgColors.indigo,
    MgColors.orange,
    MgColors.teal,
    MgColors.purple,
    MgColors.green,
    Color(0xFFFF6482),
    Color(0xFF5E5CE6),
    Color(0xFFE5953F),
  ];

  void _open(BuildContext context, StoreTag tag) {
    Navigator.of(context).push(CupertinoPageRoute(builder: (_) => StoreCatalogPage(tags: [tag.name])));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = L10n.of(context);
    final tags = ref.watch(storeTagCoversProvider);
    final metrics = MgShelfMetrics.of(context);
    return MgPage(
      title: l10n.storeCategories,
      body: tags.when(
        loading: () => const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        error: (_, __) => MgEmptyState(
          icon: Icons.wifi_off,
          title: l10n.storeOffline,
          action: l10n.storeRetry,
          onAction: () => ref.invalidate(storeTagCoversProvider),
        ),
        data: (tags) {
          final big = tags.take(10).toList();
          final rest = tags.skip(10).toList();
          // Popular books sit in many genres; give each tile covers the tiles before it did not use.
          final used = <String>{};
          final tileCovers = [
            for (final tag in big)
              () {
                final fresh = tag.covers.where((c) => !used.contains(c)).toList();
                final picked = [...fresh, ...tag.covers.where((c) => !fresh.contains(c))].take(3).toList();
                used.addAll(picked);
                return picked;
              }(),
          ];
          final columns = metrics.wide ? 4 : 2;
          return ListView(
            padding: EdgeInsets.fromLTRB(metrics.inset, 4, metrics.inset, 32 + MediaQuery.paddingOf(context).bottom),
            children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 108,
                ),
                itemCount: big.length,
                itemBuilder: (context, index) => _GenreTile(
                  tag: big[index],
                  covers: tileCovers[index],
                  color: _tileColors[index % _tileColors.length],
                  onTap: () => _open(context, big[index]),
                ),
              ),
              if (rest.isNotEmpty) ...[
                const SizedBox(height: 26),
                Text(l10n.storeTags, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final tag in rest)
                      MgChip(
                        label: '${tag.name}  ${tag.count}',
                        selected: false,
                        checkmark: false,
                        onTap: () => _open(context, tag),
                      ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _GenreTile extends StatelessWidget {
  const _GenreTile({required this.tag, required this.covers, required this.color, required this.onTap});

  final StoreTag tag;
  final List<String> covers;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Material(
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [color, Color.lerp(color, Colors.black, .18)!],
            ),
          ),
          child: Stack(
            children: [
              // Fanned covers peeking from the right edge.
              for (var i = covers.length - 1; i >= 0; i--)
                Positioned(
                  right: -6.0 + i * 22,
                  top: 16.0 + i * 4,
                  child: Transform.rotate(
                    angle: (12 - i * 9) * math.pi / 180,
                    child: Container(
                      width: 52,
                      height: 72,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 6, offset: Offset(0, 3))],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: CachedNetworkImage(
                        imageUrl: covers[i],
                        fit: BoxFit.cover,
                        memCacheWidth: (52 * dpr).round(),
                        errorWidget: (_, __, ___) => const ColoredBox(color: Color(0x33FFFFFF)),
                        placeholder: (_, __) => const ColoredBox(color: Color(0x33FFFFFF)),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FractionallySizedBox(
                      widthFactor: .52,
                      alignment: Alignment.centerLeft,
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(tag.name,
                            maxLines: 1,
                            style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
                      ),
                    ),
                    const Spacer(),
                    Text('${tag.count}',
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: .85), fontSize: 13, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
