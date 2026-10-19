import 'package:anx_reader/monogatari/theme.dart';
import 'package:flutter/material.dart';

/// The rounded gray search field under large titles.
class MgSearchField extends StatefulWidget {
  const MgSearchField({
    super.key,
    this.controller,
    required this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
  });

  final TextEditingController? controller;
  final String placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final EdgeInsetsGeometry padding;

  @override
  State<MgSearchField> createState() => _MgSearchFieldState();
}

class _MgSearchFieldState extends State<MgSearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();

  @override
  void dispose() {
    if (widget.controller == null) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = MgPalette.of(context);
    return Padding(
      padding: widget.padding,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: _controller,
        builder: (context, value, _) => TextField(
          controller: _controller,
          autofocus: widget.autofocus,
          textInputAction: widget.onSubmitted != null
              ? TextInputAction.search
              : TextInputAction.done,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          style: const TextStyle(fontSize: 17),
          decoration: InputDecoration(
            hintText: widget.placeholder,
            prefixIcon: Icon(Icons.search, color: palette.secondaryLabel),
            suffixIcon: value.text.isEmpty
                ? null
                : IconButton(
                    icon: Icon(Icons.cancel, size: 18, color: palette.secondaryLabel),
                    onPressed: () {
                      _controller.clear();
                      widget.onChanged?.call('');
                    },
                  ),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}
