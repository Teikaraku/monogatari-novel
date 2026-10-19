import 'dart:async';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/l10n/generated/L10n.dart';
import 'package:anx_reader/main.dart';
import 'package:anx_reader/monogatari/ui.dart';
import 'package:anx_reader/page/book_player/epub_player.dart';
import 'package:anx_reader/page/reader/reader_kit.dart';
import 'package:anx_reader/page/settings_page/narrate.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:anx_reader/service/tts/tts_service.dart' as tts_svc;
import 'package:flutter/material.dart';

/// Stops narration after a chosen time; lives outside the panel so it keeps running when the
/// panel closes.
class ReaderSleepTimer {
  ReaderSleepTimer._();

  static final instance = ReaderSleepTimer._();

  final remaining = ValueNotifier<Duration?>(null);
  int minutes = 0;
  Timer? _timer;
  DateTime? _end;

  void start(int minutes) {
    cancel();
    this.minutes = minutes;
    if (minutes <= 0) return;
    _end = DateTime.now().add(Duration(minutes: minutes));
    remaining.value = Duration(minutes: minutes);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = _end!.difference(DateTime.now());
      if (left <= Duration.zero) {
        TtsHandler().stop();
        cancel();
      } else {
        remaining.value = left;
      }
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _end = null;
    minutes = 0;
    remaining.value = null;
  }
}

const _speeds = [0.5, 0.75, 1.0, 1.25, 1.5];
const _timers = [0, 15, 30, 60];

class ListenPanel extends StatefulWidget {
  const ListenPanel({super.key, required this.epubPlayerKey, required this.onClose});

  final GlobalKey<EpubPlayerState> epubPlayerKey;
  final VoidCallback onClose;

  @override
  State<ListenPanel> createState() => _ListenPanelState();
}

class _ListenPanelState extends State<ListenPanel> {
  @override
  void initState() {
    super.initState();
    // Opening the panel starts narration from the current page, as before.
    final player = widget.epubPlayerKey.currentState;
    if (player != null && TtsHandler().ttsStateNotifier.value != TtsStateEnum.playing) {
      TtsHandler().init(player.initTts, player.ttsNext, player.ttsPrev).then((_) => audioHandler.play());
    }
  }

  String _engineLabel(BuildContext context) {
    final id = Prefs().ttsService;
    if (id == 'system') return L10n.of(context).ttsTypeSystem;
    return tts_svc.getTtsService(id).getLabel(context);
  }

  String _clock(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _stop() async {
    ReaderSleepTimer.instance.cancel();
    await audioHandler.stop();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final scheme = Theme.of(context).colorScheme;
    final palette = MgPalette.of(context);
    final player = widget.epubPlayerKey.currentState;

    Widget control(IconData icon, VoidCallback onTap, {double size = 26}) => InkResponse(
          radius: 26,
          onTap: onTap,
          child: SizedBox(width: 48, height: 48, child: Icon(icon, size: size, color: scheme.onSurface)),
        );

    return ReaderCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
      child: ValueListenableBuilder<TtsStateEnum>(
        valueListenable: TtsHandler().ttsStateNotifier,
        builder: (context, state, _) {
          final playing = state == TtsStateEnum.playing;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ReaderPanelHeader(title: l10n.readerListen, onClose: widget.onClose),
              const SizedBox(height: 4),
              if ((player?.chapterTitle ?? '').isNotEmpty)
                Text(
                  player!.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: palette.secondaryLabel),
                ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  control(Icons.skip_previous_rounded, () async {
                    await audioHandler.stop();
                    await widget.epubPlayerKey.currentState?.ttsPrevSection();
                    TtsHandler().playPrevious();
                  }),
                  control(Icons.fast_rewind_rounded, () => TtsHandler().playPrevious(), size: 24),
                  Material(
                    color: scheme.primary,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => playing ? audioHandler.pause() : audioHandler.play(),
                      child: SizedBox(
                        width: 62,
                        height: 62,
                        child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                            size: 34, color: scheme.onPrimary),
                      ),
                    ),
                  ),
                  control(Icons.fast_forward_rounded, () => TtsHandler().playNext(), size: 24),
                  control(Icons.skip_next_rounded, () async {
                    await audioHandler.stop();
                    await widget.epubPlayerKey.currentState?.ttsNextSection();
                    TtsHandler().playNext();
                  }),
                ],
              ),
              const SizedBox(height: 16),
              ReaderLabel(l10n.readerSpeed),
              ReaderChoiceRow<double>(
                selected: _speeds.where((s) => (s - TtsHandler().rate).abs() < .01).firstOrNull,
                onSelected: (value) => setState(() => TtsHandler().rate = value),
                options: [for (final s in _speeds) (s, Text('${s == s.roundToDouble() ? s.toInt() : s}×'))],
              ),
              const SizedBox(height: 14),
              ValueListenableBuilder<Duration?>(
                valueListenable: ReaderSleepTimer.instance.remaining,
                builder: (context, left, _) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ReaderLabel(
                      l10n.readerSleepTimer,
                      trailing: left == null
                          ? null
                          : Text(l10n.readerTimerLeft(_clock(left)),
                              style: TextStyle(fontSize: 12, color: scheme.primary)),
                    ),
                    ReaderChoiceRow<int>(
                      selected: ReaderSleepTimer.instance.minutes,
                      onSelected: (value) => setState(() => ReaderSleepTimer.instance.start(value)),
                      options: [
                        for (final m in _timers) (m, Text(m == 0 ? l10n.readerTimerOff : l10n.readerMinutes(m))),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              ReaderLinkRow(
                icon: Icons.record_voice_over_outlined,
                title: l10n.readerVoice,
                value: _engineLabel(context),
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => const FractionallySizedBox(heightFactor: .75, child: NarrateSettings()),
                ).then((_) {
                  if (mounted) setState(() {});
                }),
              ),
              const SizedBox(height: 4),
              Align(
                child: TextButton(
                  onPressed: _stop,
                  style: TextButton.styleFrom(foregroundColor: palette.secondaryLabel),
                  child: Text(l10n.readerStopListening),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
