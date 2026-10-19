import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/widgets/common/color_picker_sheet.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:flutter/material.dart';
import 'package:anx_reader/utils/color/hash_color.dart';

class TagChip extends StatelessWidget {
  const TagChip({
    super.key,
    required this.label,
    this.color,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.dense = false,
  });

  final String label;
  final Color? color;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool dense;

  Color _colorForLabel(String value) {
    return color ?? hashColor(value);
  }

  @override
  Widget build(BuildContext context) {
    ThemeData theme = Theme.of(context);
    final isEink = Prefs().eInkMode;

    final einkBgColor = selected ? theme.colorScheme.secondary : Colors.transparent;
    final einkBorderColor = selected ? Colors.transparent : theme.colorScheme.onSurface;
    final einkForeground = selected ? theme.colorScheme.onSecondary : theme.colorScheme.onSurface;

    final baseColor = _colorForLabel(label);
    final normalBgColor = selected ? baseColor.withAlpha(46) : Colors.transparent;
    final normalBorderColor = selected ? Colors.transparent : baseColor.withAlpha(102);
    final normalForeground = selected ? baseColor : Theme.of(context).colorScheme.onSurface.withAlpha(179);

    final bgColor = isEink ? einkBgColor : normalBgColor;
    final normalBborderColor = isEink ? einkBorderColor : normalBorderColor;
    final foreground = isEink ? einkForeground : normalForeground;

    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      onLongPress: onLongPress,
      onSecondaryTap: onLongPress,
      child: Container(
        padding: dense
            ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
            : const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: normalBborderColor, width: 1),
        ),
        child: Text(
          '# $label',
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: foreground,
          ),
        ),
      ),
    );
  }

  static const _presetColors = [
    Color(0xFFFF2D55),
    Color(0xFFFF9500),
    Color(0xFFFFCC00),
    Color(0xFF34C759),
    Color(0xFF5AC8FA),
    Color(0xFF007AFF),
    Color(0xFF5856D6),
    Color(0xFFAF52DE),
    Color(0xFF8E8E93),
  ];

  /// Rename, recolour or delete a tag in a sheet. Colour changes apply at once; the name on save.
  static Future<void> showEditDialog({
    required BuildContext context,
    required String initialName,
    required Color? initialColor, // RGB
    required Future<void> Function(String newName) onRename,
    required Future<void> Function(Color color) onColorChange,
    required Future<void> Function() onDelete,
  }) async {
    final l10n = L10n.of(context);
    final controller = TextEditingController(text: initialName);
    var color = (initialColor ?? hashColor(initialName)).withAlpha(0xFF);
    await showMgSheet(
      context: context,
      title: l10n.tagEditTitle,
      builder: (sheet) => StatefulBuilder(builder: (sheet, setSheet) {
        Future<void> pick(Color value) async {
          setSheet(() => color = value);
          await onColorChange(value);
        }

        Widget dot(Color value) {
          final selected = value.toARGB32() == color.toARGB32();
          return GestureDetector(
            onTap: () => pick(value),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: value,
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? Theme.of(sheet).colorScheme.onSurface : Colors.transparent,
                  width: 2.5,
                ),
              ),
              child: selected ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
            ),
          );
        }

        final custom = !_presetColors.any((c) => c.toARGB32() == color.toARGB32());
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: controller,
                    autofocus: false,
                    style: const TextStyle(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: l10n.tagNamePlaceholder,
                      isDense: true,
                      filled: true,
                      fillColor: mgSheetGroupColor(sheet),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      for (final preset in _presetColors) dot(preset),
                      GestureDetector(
                        onTap: () async {
                          final picked = await showRgbColorPicker(context: sheet, initialColor: color);
                          if (picked != null) await pick(picked.withAlpha(0xFF));
                        },
                        child: Container(
                          height: 30,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: custom ? color : mgSheetGroupColor(sheet),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Text(l10n.tagCustomColor,
                              style: TextStyle(fontSize: 13, color: custom ? Colors.white : null)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            MgSheetGroup(children: [
              MgSheetAction(
                title: l10n.commonDelete,
                icon: Icons.delete_outline,
                destructive: true,
                onTap: () async {
                  await onDelete();
                  if (sheet.mounted) Navigator.of(sheet).pop();
                },
              ),
            ]),
          ],
        );
      }),
      footer: (sheet) => MgSheetButtons(
        secondary: l10n.commonCancel,
        onSecondary: () => Navigator.of(sheet).pop(),
        primary: l10n.commonSave,
        onPrimary: () async {
          final name = controller.text.trim();
          if (name.isEmpty) return;
          await onRename(name);
          if (sheet.mounted) Navigator.of(sheet).pop();
        },
      ),
    );
    controller.dispose();
  }
}
