import 'package:anx_reader/dao/store_book_tag.dart';
import 'package:anx_reader/dao/tag.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/tag.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/tags.dart';
import 'package:anx_reader/utils/color/hash_color.dart';
import 'package:anx_reader/widgets/common/tag_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Where a tag editor reads and writes attachments: a local book or a bookstore series.
abstract class TagBinding {
  Future<Set<int>> attached();
  Future<void> attach(int tagId);
  Future<void> detach(int tagId);
}

class BookTagBinding implements TagBinding {
  const BookTagBinding(this.bookId);

  final int bookId;

  @override
  Future<Set<int>> attached() async => (await bookTagDao.fetchTagIdsForBook(bookId)).toSet();

  @override
  Future<void> attach(int tagId) => bookTagDao.addRelation(bookId: bookId, tagId: tagId);

  @override
  Future<void> detach(int tagId) => bookTagDao.removeRelation(bookId: bookId, tagId: tagId);
}

class StoreTagBinding implements TagBinding {
  const StoreTagBinding(this.storeId);

  final String storeId;

  @override
  Future<Set<int>> attached() async => (await storeBookTagDao.tagIdsForStore(storeId)).toSet();

  @override
  Future<void> attach(int tagId) => storeBookTagDao.attach(storeId, tagId);

  @override
  Future<void> detach(int tagId) => storeBookTagDao.detach(storeId, tagId);
}

/// Every tag as a toggle plus a field to create one; long press renames, recolours or deletes.
/// [onChanged] runs after each change so callers can refresh what they show.
Future<void> showTagEditorSheet(
  BuildContext context, {
  required TagBinding binding,
  required VoidCallback onChanged,
}) =>
    showMgSheet(
      context: context,
      title: L10n.of(context).tagsSectionTitle,
      builder: (_) => _TagEditor(binding: binding, onChanged: onChanged),
    );

/// A tag as a pill with its colour dot; selected pills are outlined in the accent.
class TagPill extends StatelessWidget {
  const TagPill({super.key, required this.tag, required this.selected, this.onTap, this.onLongPress});

  final Tag tag;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final color = tag.color ?? hashColor(tag.name);
    return Material(
      color: selected ? accent.withValues(alpha: .1) : mgSheetGroupColor(context),
      shape: StadiumBorder(side: BorderSide(color: selected ? accent : Colors.transparent)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 7),
              Text(tag.name, style: TextStyle(fontSize: 14, color: selected ? accent : null)),
            ],
          ),
        ),
      ),
    );
  }
}

class _TagEditor extends ConsumerStatefulWidget {
  const _TagEditor({required this.binding, required this.onChanged});

  final TagBinding binding;
  final VoidCallback onChanged;

  @override
  ConsumerState<_TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends ConsumerState<_TagEditor> {
  final _controller = TextEditingController();
  Set<int>? _attached;

  @override
  void initState() {
    super.initState();
    widget.binding.attached().then((ids) {
      if (mounted) setState(() => _attached = ids);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _toggle(Tag tag) async {
    final attached = {...?_attached};
    if (attached.remove(tag.id)) {
      await widget.binding.detach(tag.id);
    } else {
      attached.add(tag.id);
      await widget.binding.attach(tag.id);
    }
    if (mounted) setState(() => _attached = attached);
    widget.onChanged();
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    final id = await ref.read(tagListProvider.notifier).createTag(name, color: hashColor(name));
    await widget.binding.attach(id);
    _controller.clear();
    if (mounted) setState(() => _attached = {...?_attached, id});
    widget.onChanged();
  }

  Future<void> _edit(Tag tag) => TagChip.showEditDialog(
        context: context,
        initialName: tag.name,
        initialColor: tag.color ?? hashColor(tag.name),
        onRename: (name) async {
          await ref.read(tagListProvider.notifier).updateTag(tag.id, newName: name);
          widget.onChanged();
        },
        onColorChange: (color) async {
          await ref.read(tagListProvider.notifier).updateTag(tag.id, color: color);
          widget.onChanged();
        },
        onDelete: () async {
          await ref.read(tagListProvider.notifier).deleteTag(tag.id);
          if (mounted) setState(() => _attached = {...?_attached}..remove(tag.id));
          ref.read(tagSelectionProvider.notifier).setSelection(
              ref.read(tagSelectionProvider).where((id) => id != tag.id).toSet());
          widget.onChanged();
        },
      );

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final tags = ref.watch(tagListProvider).valueOrNull;
    final attached = _attached;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _create(),
                  decoration: InputDecoration(
                    hintText: l10n.tagNewPlaceholder,
                    isDense: true,
                    filled: true,
                    fillColor: mgSheetGroupColor(context),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton(onPressed: _create, child: Text(l10n.tagAddButton)),
            ],
          ),
          const SizedBox(height: 16),
          if (tags == null || attached == null)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags)
                  TagPill(
                    tag: tag,
                    selected: attached.contains(tag.id),
                    onTap: () => _toggle(tag),
                    onLongPress: () => _edit(tag),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
