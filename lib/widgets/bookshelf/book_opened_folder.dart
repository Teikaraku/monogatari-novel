import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/models/book.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/book_list.dart';
import 'package:anx_reader/providers/tb_groups.dart';
import 'package:anx_reader/widgets/bookshelf/book_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Opens a shelf folder as a tall sheet.
Future<void> showBookFolder(BuildContext context, {required List<Book> books, required String groupName}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    builder: (sheet) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * .86),
      child: BookOpenedFolder(books: books, groupName: groupName),
    ),
  );
}

/// A folder's books under its name: tap the name to rename, Edit to take books out, or ungroup.
class BookOpenedFolder extends ConsumerStatefulWidget {
  const BookOpenedFolder({
    super.key,
    required this.books,
    required this.groupName,
  });

  final List<Book> books;
  final String groupName;

  @override
  ConsumerState<BookOpenedFolder> createState() => _BookOpenedFolderState();
}

class _BookOpenedFolderState extends ConsumerState<BookOpenedFolder> {
  bool _editing = false;
  bool _renaming = false;
  late final List<Book> _books = [...widget.books];
  late final TextEditingController _name = TextEditingController(text: widget.groupName);
  late String _groupName = widget.groupName;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _name.text.trim();
    setState(() => _renaming = false);
    if (name.isEmpty || name == _groupName || _books.isEmpty) {
      _name.text = _groupName;
      return;
    }
    final groupId = _books.first.groupId;
    if (groupId <= 0) return;
    final group = await ref.read(groupDaoProvider.notifier).getGroup(groupId);
    if (group == null) return;
    await ref.read(groupDaoProvider.notifier).updateGroup(group.copyWith(name: name));
    if (mounted) setState(() => _groupName = name);
  }

  void _remove(Book book) {
    ref.read(bookListProvider.notifier).removeFromGroup(book);
    setState(() => _books.remove(book));
    if (_books.length <= 1) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;

    final title = _renaming
        ? TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _saveName(),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              isDense: true,
              filled: true,
              fillColor: mgSheetGroupColor(context),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              suffixIcon: IconButton(icon: Icon(Icons.check, color: accent), onPressed: _saveName),
            ),
          )
        : GestureDetector(
            onTap: () => setState(() => _renaming = true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_groupName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(l10n.mgBookCount(_books.length), style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
              ],
            ),
          );

    return Column(
      mainAxisSize: MainAxisSize.min,
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
          padding: const EdgeInsets.fromLTRB(20, 6, 8, 8),
          child: Row(
            children: [
              Expanded(child: title),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _editing = !_editing),
                child: Text(_editing ? l10n.folderDone : l10n.commonEdit),
              ),
              MgMenuButton(
                sections: () => [
                  [
                    MgMenuAction(
                      title: l10n.folderRename,
                      icon: Icons.drive_file_rename_outline,
                      onTap: () => setState(() => _renaming = true),
                    ),
                    MgMenuAction(
                      title: l10n.folderDissolve,
                      icon: Icons.folder_off_outlined,
                      onTap: () {
                        ref.read(bookListProvider.notifier).dissolveGroup(_books);
                        Navigator.of(context).pop();
                      },
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        Flexible(
          child: LayoutBuilder(builder: (context, constraints) {
            final columns = (constraints.maxWidth / Prefs().bookCoverWidth).floor().clamp(2, 12);
            final cell = (constraints.maxWidth - 32 - (columns - 1) * 14) / columns;
            return GridView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                childAspectRatio: cell / (cell * 1.5 + 59),
                mainAxisSpacing: 18,
                crossAxisSpacing: 14,
              ),
              itemCount: _books.length,
              itemBuilder: (context, index) {
                final book = _books[index];
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: IgnorePointer(ignoring: _editing, child: BookItem(book: book))),
                    if (_editing)
                      Positioned(
                        left: -6,
                        top: -6,
                        child: GestureDetector(
                          onTap: () => _remove(book),
                          child: Container(
                            width: 24,
                            height: 24,
                            decoration: BoxDecoration(
                              color: palette.secondaryLabel,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: const Icon(Icons.remove, size: 16, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          }),
        ),
      ],
    );
  }
}
