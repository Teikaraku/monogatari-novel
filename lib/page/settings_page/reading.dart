import 'package:anx_reader/page/reader/reader_settings.dart';
import 'package:flutter/material.dart';

/// Reading settings outside the reader: the same groups as the reader's settings sheet.
class ReadingSettings extends StatelessWidget {
  const ReadingSettings({super.key});

  @override
  Widget build(BuildContext context) => ListView(
        padding: EdgeInsets.only(top: 6, bottom: 32 + MediaQuery.paddingOf(context).bottom),
        children: const [ReaderLayoutSettings(), ReaderContentSettings(), ReaderControlSettings()],
      );
}
