import 'package:anx_reader/main.dart';
import 'package:anx_reader/service/tts/base_tts.dart';
import 'package:anx_reader/service/tts/tts_handler.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

class TtsFab extends StatefulWidget {
  const TtsFab({super.key});

  @override
  State<TtsFab> createState() => _TtsFabState();
}

class _TtsFabState extends State<TtsFab> with SingleTickerProviderStateMixin {
  bool _isExpanded = false;
  late AnimationController _animationController;
  late Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _expandAnimation = CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _animationController.forward();
      } else {
        _animationController.reverse();
      }
    });
  }

  void _collapse() {
    if (_isExpanded) {
      setState(() {
        _isExpanded = false;
        _animationController.reverse();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TtsStateEnum>(
      valueListenable: TtsHandler().ttsStateNotifier,
      builder: (context, ttsState, _) {
        final isPlaying = ttsState == TtsStateEnum.playing;
        final ttsActive =
            ttsState == TtsStateEnum.playing || ttsState == TtsStateEnum.paused;

        // Collapse when TTS stops, but keep widget alive so State is preserved
        // during brief stopped transitions (e.g. between sentences).
        if (ttsState == TtsStateEnum.stopped) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _collapse());
        }

        return AnimatedOpacity(
          opacity: ttsActive ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: IgnorePointer(
            ignoring: !ttsActive,
            child: PointerInterceptor(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Expanded action buttons (slide in from right, appear to left of main FAB)
                  AnimatedBuilder(
                    animation: _expandAnimation,
                    builder: (context, child) {
                      return ClipRect(
                        child: Align(
                          alignment: Alignment.centerRight,
                          widthFactor: _expandAnimation.value,
                          child: child,
                        ),
                      );
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(right: 8.0),
                      child: Container(
                        height: 44,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: _capsule(22),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _ActionButton(icon: Icons.fast_rewind_rounded, onPressed: () => TtsHandler().playPrevious()),
                            _ActionButton(
                              icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              onPressed: () => isPlaying ? audioHandler.pause() : audioHandler.play(),
                            ),
                            _ActionButton(icon: Icons.fast_forward_rounded, onPressed: () => TtsHandler().playNext()),
                            _ActionButton(
                              icon: Icons.stop_rounded,
                              onPressed: () {
                                audioHandler.stop();
                                _collapse();
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  // Main FAB — heroTag: null disables the built-in Hero to avoid
                  // nesting inside the reading page's own Hero animation.
                  GestureDetector(
                    onTap: _toggleExpanded,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: _capsule(22),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: Icon(
                          _isExpanded ? Icons.close_rounded : Icons.headphones_rounded,
                          key: ValueKey(_isExpanded),
                          size: 20,
                          color: isPlaying || _isExpanded ? Colors.white : Colors.white60,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.onPressed,
  });

  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onPressed,
      radius: 20,
      child: SizedBox(width: 40, height: 44, child: Icon(icon, size: 22, color: Colors.white)),
    );
  }
}

/// The dark translucent capsule shared with the selection toolbar and toasts.
BoxDecoration _capsule(double radius) => BoxDecoration(
      color: const Color(0xE6242426),
      borderRadius: BorderRadius.circular(radius),
      boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 14, offset: Offset(0, 4))],
    );
