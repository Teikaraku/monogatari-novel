import 'dart:async';
import 'dart:io';

import 'package:anx_reader/enums/sync_direction.dart';
import 'package:anx_reader/enums/sync_trigger.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/providers/sync.dart';
import 'package:anx_reader/service/book.dart';
import 'package:anx_reader/service/md5_service.dart';
import 'package:anx_reader/service/wifi_transfer/wifi_transfer_server.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';

enum _ShelfStatus { importing, imported, duplicate, failed }

/// Runs the Wi-Fi transfer server while open and adds every received book to the shelf.
class WifiTransferPage extends ConsumerStatefulWidget {
  const WifiTransferPage({super.key});

  @override
  ConsumerState<WifiTransferPage> createState() => _WifiTransferPageState();
}

class _WifiTransferPageState extends ConsumerState<WifiTransferPage> {
  final _server = WifiTransferServer.instance;
  final _shelf = <String, _ShelfStatus>{};
  StreamSubscription<File>? _subscription;
  Future<void> _queue = Future.value();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _subscription = _server.received.listen((file) => _queue = _queue.then((_) => _add(file)));
    _server.start();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _server.stop();
    WakelockPlus.disable();
    super.dispose();
  }

  /// Imports one received file unless the shelf already has it; the file is consumed either way.
  Future<void> _add(File file) async {
    final key = p.basename(file.path);
    setState(() => _shelf[key] = _ShelfStatus.importing);
    try {
      final check = (await MD5Service.checkImportFiles([file.path])).first;
      if (check.isDuplicate) {
        if (await file.exists()) await file.delete();
        if (mounted) setState(() => _shelf[key] = _ShelfStatus.duplicate);
        return;
      }
      await importBook(file, ref);
      if (mounted) setState(() => _shelf[key] = _ShelfStatus.imported);
      ref.read(syncProvider.notifier).syncData(SyncDirection.upload, ref, trigger: SyncTrigger.auto);
    } catch (e) {
      AnxLog.severe('Wi-Fi import failed for ${file.path}: $e');
      if (mounted) setState(() => _shelf[key] = _ShelfStatus.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return MgSubPage(
      title: l10n.transferWifi,
      grouped: true,
      body: ValueListenableBuilder<WifiTransferState>(
        valueListenable: _server.state,
        builder: (context, state, _) => ListView(
          padding: EdgeInsets.fromLTRB(0, 8, 0, 32 + MediaQuery.paddingOf(context).bottom),
          children: [
            MgReadable(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: _AddressCard(state: state, onRetry: _server.start),
              ),
            ),
            if (state.uploads.isNotEmpty)
              MgGroup(
                title: l10n.wifiReceived,
                children: [
                  for (final upload in state.uploads) _UploadRow(upload: upload, shelf: _shelf[upload.fileName]),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.state, required this.onRetry});

  final WifiTransferState state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final accent = Theme.of(context).colorScheme.primary;
    final running = state.status == WifiTransferStatus.running;
    final url = running && state.urls.isNotEmpty ? state.urls.first : null;

    Widget body;
    if (state.status == WifiTransferStatus.failed) {
      body = Column(children: [
        Text(l10n.importFailedShort, style: TextStyle(fontSize: 15, color: Theme.of(context).colorScheme.error)),
        const SizedBox(height: 8),
        FilledButton(onPressed: onRetry, child: Text(l10n.storeRetry)),
      ]);
    } else if (!running) {
      body = Column(children: [
        const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(height: 10),
        Text(l10n.wifiStarting, style: TextStyle(fontSize: 14, color: palette.secondaryLabel)),
      ]);
    } else if (url == null) {
      body = Text(l10n.wifiNoNetwork, style: TextStyle(fontSize: 16, color: palette.secondaryLabel));
    } else {
      body = Column(
        children: [
          Text(l10n.wifiOpenInBrowser, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
          const SizedBox(height: 8),
          SelectableText(
            url,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: accent, letterSpacing: .2),
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: url));
              AnxToast.show(l10n.notesPageCopied);
            },
            icon: const Icon(Icons.copy, size: 18),
            label: Text(l10n.notesCopy),
          ),
          if (state.urls.length > 1) ...[
            const SizedBox(height: 14),
            Text(l10n.wifiOtherAddresses, style: TextStyle(fontSize: 12, color: palette.secondaryLabel)),
            const SizedBox(height: 4),
            for (final other in state.urls.skip(1))
              SelectableText(other, style: TextStyle(fontSize: 13, color: palette.secondaryLabel)),
          ],
        ],
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
      decoration: BoxDecoration(color: palette.card, borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: accent.withValues(alpha: .1), shape: BoxShape.circle),
            child: Icon(running && url != null ? Icons.wifi : Icons.wifi_find, size: 32, color: accent),
          ),
          const SizedBox(height: 18),
          body,
        ],
      ),
    );
  }
}

class _UploadRow extends StatelessWidget {
  const _UploadRow({required this.upload, required this.shelf});

  final WifiTransferUpload upload;
  final _ShelfStatus? shelf;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final palette = MgPalette.of(context);
    final scheme = Theme.of(context).colorScheme;
    final progress = upload.totalBytes > 0 ? (upload.receivedBytes / upload.totalBytes).clamp(0.0, 1.0) : null;

    final (String label, Color color) = switch ((upload.done, upload.error, shelf)) {
      (true, 'unsupported', _) => (l10n.importUnsupported, scheme.error),
      (true, 'too_large', _) => (l10n.wifiTooLarge, scheme.error),
      (true, final String _, _) => (l10n.importFailedShort, scheme.error),
      (_, _, _ShelfStatus.importing) => (l10n.wifiImporting, palette.secondaryLabel),
      (_, _, _ShelfStatus.imported) => (l10n.wifiImported, const Color(0xFF34C759)),
      (_, _, _ShelfStatus.duplicate) => (l10n.wifiDuplicate, palette.secondaryLabel),
      (_, _, _ShelfStatus.failed) => (l10n.importFailedShort, scheme.error),
      (true, _, _) => (l10n.wifiReceived, palette.secondaryLabel),
      _ => (progress == null ? '…' : '${(progress * 100).round()}%', scheme.primary),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(upload.fileName,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15)),
              ),
              const SizedBox(width: 12),
              Text(label, style: TextStyle(fontSize: 13, color: color)),
            ],
          ),
          if (!upload.done)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(value: progress, minHeight: 3),
              ),
            ),
        ],
      ),
    );
  }
}
