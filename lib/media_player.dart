import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

enum MediaPlayerAction { next, previous, exit }

class MediaPlayerEvent {
  const MediaPlayerEvent(this.action, this.index);

  final MediaPlayerAction action;
  final int index;
}

class MediaPlayerController {
  _MediaPlayerState? _state;

  void _attach(_MediaPlayerState state) {
    _state = state;
  }

  void _detach(_MediaPlayerState state) {
    if (identical(_state, state)) {
      _state = null;
    }
  }

  bool get isAttached => _state != null;

  void playNext({bool fromRemote = false}) {
    _state?._playNext(fromExternal: fromRemote);
  }

  void playPrevious({bool fromRemote = false}) {
    _state?._playPrevious(fromExternal: fromRemote);
  }

  void playAt(int index, {bool fromRemote = false}) {
    _state?._jumpTo(index, fromExternal: fromRemote);
  }

  void exit({bool fromRemote = false}) {
    _state?._handleExit(fromExternal: fromRemote);
  }

  void dispose() {
    _state = null;
  }

  int? get currentIndex => _state?._currentIndex;

  int? get currentElapsedMs {
    final state = _state;
    if (state == null) return null;
    if (state._isCurrentVideo) {
      final controller = state._videoController;
      if (controller == null || !controller.value.isInitialized) return null;
      return controller.value.position.inMilliseconds;
    } else {
      return state._currentPosition.inMilliseconds;
    }
  }

  void adjustPlaybackSpeed(double speed) {
    final state = _state;
    if (state == null) return;
    final controller = state._videoController;
    if (controller == null || !controller.value.isInitialized) return;
    controller.setPlaybackSpeed(speed.clamp(0.5, 2.0));
  }

  void seekToMs(int milliseconds) {
    final state = _state;
    if (state == null) return;
    state._seekTo(Duration(milliseconds: milliseconds));
  }
}

class _NextMediaIntent extends Intent {
  const _NextMediaIntent();
}

class _PreviousMediaIntent extends Intent {
  const _PreviousMediaIntent();
}

class _ExitIntent extends Intent {
  const _ExitIntent();
}

class MediaPlayer extends StatefulWidget {
  const MediaPlayer({
    super.key,
    required this.mediaList,
    this.imageDisplayDuration = const Duration(seconds: 10),
    required this.onExit,
    this.controller,
    this.onAction,
    this.autoAdvance = true,
    this.initialIndex = 0,
    this.isActive = true,
  });

  final List<String> mediaList;
  final Duration imageDisplayDuration;
  final VoidCallback onExit;
  final MediaPlayerController? controller;
  final ValueChanged<MediaPlayerEvent>? onAction;
  final bool autoAdvance;
  final int initialIndex;
  final bool isActive;

  @override
  State<MediaPlayer> createState() => _MediaPlayerState();
}

class _MediaPlayerState extends State<MediaPlayer> {
  int _currentIndex = 0;
  String? _currentMedia;
  VideoPlayerController? _videoController;
  Timer? _imageTimer;
  Timer? _progressTimer;
  bool _advancing = false;
  late final FocusNode _focusNode;
  Duration _currentPosition = Duration.zero;
  Duration _currentDuration = Duration.zero;
  MediaPlayerController? _controller;

  bool get _hasMedia => widget.mediaList.isNotEmpty;
  bool get _isCurrentVideo =>
      _currentMedia != null && _isVideoPath(_currentMedia!);
  bool get _shouldPlay => widget.isActive;

  int _normalizeIndex(int index) {
    final total = widget.mediaList.length;
    if (total == 0) return 0;
    final normalized = ((index % total) + total) % total;
    return normalized;
  }

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _controller = widget.controller;
    _controller?._attach(this);
    if (_hasMedia) {
      _playMedia(widget.initialIndex);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant MediaPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.mediaList, widget.mediaList) && _hasMedia) {
      _playMedia(widget.initialIndex);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      _controller = widget.controller;
      _controller?._attach(this);
    }
    if (oldWidget.initialIndex != widget.initialIndex &&
        widget.initialIndex != _currentIndex &&
        _hasMedia) {
      _playMedia(widget.initialIndex);
    }
  }

  @override
  void dispose() {
    _disposeVideoController();
    _imageTimer?.cancel();
    _progressTimer?.cancel();
    _focusNode.dispose();
    _controller?._detach(this);
    super.dispose();
  }

  void _playMedia(int index) {
    if (!_hasMedia || !mounted) return;

    _imageTimer?.cancel();
    _progressTimer?.cancel();
    _disposeVideoController();

    final normalized = _normalizeIndex(index);
    final mediaPath = widget.mediaList[normalized];
    final isVideo = _isVideoPath(mediaPath);

    if (isVideo) {
      setState(() {
        _currentIndex = normalized;
        _currentMedia = mediaPath;
        _advancing = false;
        _currentPosition = Duration.zero;
        _currentDuration = Duration.zero;
      });
      _initializeAndPlayVideo(mediaPath);
    } else {
      setState(() {
        _currentIndex = normalized;
        _currentMedia = mediaPath;
        _advancing = false;
        _currentPosition = Duration.zero;
        _currentDuration = widget.imageDisplayDuration;
      });
      _startImageProgress(Duration.zero);
      if (_shouldPlay && widget.autoAdvance) {
        _imageTimer = Timer(widget.imageDisplayDuration, () => _playNext());
      }
    }
  }

  void _jumpTo(int index, {bool fromExternal = false}) {
    if (!_hasMedia || !mounted) return;
    final total = widget.mediaList.length;
    final normalized = ((index % total) + total) % total;
    _playMedia(normalized);
    if (!fromExternal) {
      widget.onAction?.call(
        MediaPlayerEvent(MediaPlayerAction.next, _currentIndex),
      );
    }
  }

  void _initializeAndPlayVideo(String assetPath) {
    final controller = VideoPlayerController.asset(assetPath);
    _videoController = controller;

    controller
        .initialize()
        .then((_) {
          if (!mounted || _videoController != controller) {
            controller.dispose();
            if (identical(_videoController, controller)) {
              _videoController = null;
            }
            return;
          }
          setState(() {
            _currentDuration = controller.value.duration;
            _currentPosition = controller.value.position;
          });
          controller.setLooping(false);
          if (_shouldPlay) {
            controller.play();
          } else {
            controller
              ..pause()
              ..seekTo(Duration.zero);
          }
          controller.addListener(_onVideoTick);
        })
        .catchError((error) {
          debugPrint('Failed to load video asset $assetPath: $error');
          if (identical(_videoController, controller)) {
            _videoController = null;
          }
          controller.dispose();
          if (mounted) {
            _playNext();
          }
        });
  }

  void _onVideoTick() {
    final controller = _videoController;
    if (controller == null || !controller.value.isInitialized) return;

    final value = controller.value;
    if (value.isCompleted && !_advancing) {
      _advancing = true;
      if (_shouldPlay && widget.autoAdvance) {
        _playNext();
      }
    }

    final position = value.position;
    final duration = value.duration;
    if (position != _currentPosition || duration != _currentDuration) {
      setState(() {
        _currentPosition = position;
        _currentDuration = duration;
      });
    }
  }

  void _playNext({bool fromExternal = false}) {
    if (!fromExternal && !widget.autoAdvance) {
      return;
    }
    if (!_hasMedia || !mounted) return;
    final nextIndex = (_currentIndex + 1) % widget.mediaList.length;
    _playMedia(nextIndex);
    if (!fromExternal) {
      widget.onAction?.call(
        MediaPlayerEvent(MediaPlayerAction.next, _currentIndex),
      );
    }
  }

  void _playPrevious({bool fromExternal = false}) {
    if (!fromExternal && !widget.autoAdvance) {
      return;
    }
    if (!_hasMedia || !mounted) return;
    final total = widget.mediaList.length;
    final previousIndex = (_currentIndex - 1 + total) % total;
    _playMedia(previousIndex);
    if (!fromExternal) {
      widget.onAction?.call(
        MediaPlayerEvent(MediaPlayerAction.previous, _currentIndex),
      );
    }
  }

  void _disposeVideoController() {
    final controller = _videoController;
    if (controller != null) {
      controller.removeListener(_onVideoTick);
      controller.dispose();
      _videoController = null;
    }
  }

  void _handleExit({bool fromExternal = false}) {
    _advancing = false;
    _imageTimer?.cancel();
    _imageTimer = null;
    _progressTimer?.cancel();
    _progressTimer = null;
    _disposeVideoController();
    if (!fromExternal) {
      widget.onAction?.call(
        MediaPlayerEvent(MediaPlayerAction.exit, _currentIndex),
      );
    }
    widget.onExit();
  }

  void _startImageProgress(Duration startPosition) {
    _progressTimer?.cancel();
    final total = widget.imageDisplayDuration;
    Duration clampedStart = startPosition;
    if (clampedStart < Duration.zero) {
      clampedStart = Duration.zero;
    }
    if (total > Duration.zero && clampedStart > total) {
      clampedStart = total;
    }
    setState(() {
      _currentDuration = total;
      _currentPosition = clampedStart;
    });
    if (total <= Duration.zero) {
      return;
    }
    if (_currentPosition >= total) {
      setState(() {
        _currentPosition = total;
      });
      _progressTimer?.cancel();
      if (widget.autoAdvance && _shouldPlay) {
        _imageTimer?.cancel();
        _imageTimer = Timer(total, () => _playNext());
      }
      return;
    }
    const tick = Duration(milliseconds: 200);
    _progressTimer = Timer.periodic(tick, (_) {
      if (!mounted) return;
      setState(() {
        _currentPosition += tick;
        if (_currentPosition >= total) {
          _currentPosition = total;
          _progressTimer?.cancel();
          if (widget.autoAdvance && _shouldPlay) {
            _imageTimer?.cancel();
            _imageTimer = Timer(total, () => _playNext());
          }
        }
      });
    });
  }

  void _seekTo(Duration target) {
    Duration clamped = target;
    if (clamped < Duration.zero) {
      clamped = Duration.zero;
    } else if (_currentDuration > Duration.zero && clamped > _currentDuration) {
      clamped = _currentDuration;
    }

    _advancing = false;

    if (_isCurrentVideo) {
      final controller = _videoController;
      if (controller == null) return;
      controller.seekTo(clamped).then((_) {
        if (!controller.value.isPlaying) {
          controller.play();
        }
      });
      setState(() {
        _currentPosition = clamped;
      });
    } else {
      if (_currentDuration <= Duration.zero) return;
      _imageTimer?.cancel();
      final remaining = _currentDuration - clamped;
      if (remaining <= Duration.zero) {
        setState(() {
          _currentPosition = _currentDuration;
        });
        _progressTimer?.cancel();
        if (widget.autoAdvance && _shouldPlay) {
          _playNext();
        }
        return;
      }
      _startImageProgress(clamped);
      if (widget.autoAdvance) {
        _imageTimer = Timer(remaining, () => _playNext());
      }
    }
  }

  bool _isVideoPath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.avi');
  }

  String? get _currentMediaName {
    final media = _currentMedia;
    if (media == null) return null;
    final normalized = media.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (segments.isEmpty) return media;
    return segments.last.isEmpty ? media : segments.last;
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildCurrentMediaView() {
    if (!_hasMedia) {
      return const Center(child: Text('재생할 미디어가 없습니다.'));
    }

    if (_isCurrentVideo) {
      final controller = _videoController;
      if (controller == null || !controller.value.isInitialized) {
        return const Center(child: CircularProgressIndicator());
      }

      final size = controller.value.size;
      return SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: VideoPlayer(controller),
          ),
        ),
      );
    }

    return SizedBox.expand(
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Colors.black),
        child: _currentMedia == null
            ? const SizedBox.shrink()
            : Image.asset(_currentMedia!, fit: BoxFit.cover),
      ),
    );
  }

  Widget _buildProgressOverlay(BuildContext context) {
    if (!_hasMedia) return const SizedBox.shrink();

    final totalMs = _currentDuration.inMilliseconds;
    final sliderMax = totalMs > 0 ? totalMs.toDouble() : 1.0;
    final currentMs = _currentPosition.inMilliseconds;
    final sliderValue = totalMs > 0
        ? math.min(currentMs.toDouble(), sliderMax)
        : 0.0;

    final textStyle = Theme.of(
      context,
    ).textTheme.labelMedium?.copyWith(color: Colors.white);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        color: Colors.black54,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                value: sliderValue,
                min: 0,
                max: sliderMax,
                onChanged: totalMs <= 0
                    ? null
                    : (double newValue) {
                        setState(() {
                          _currentPosition = Duration(
                            milliseconds: newValue.round(),
                          );
                        });
                      },
                onChangeEnd: totalMs <= 0
                    ? null
                    : (double newValue) {
                        _seekTo(Duration(milliseconds: newValue.round()));
                      },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(_currentPosition), style: textStyle),
                Text(_formatDuration(_currentDuration), style: textStyle),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoOverlay(BuildContext context) {
    final mediaName = _currentMediaName;
    if (mediaName == null) return const SizedBox.shrink();
    return Positioned(
      left: 16,
      top: 16,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            mediaName,
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _buildTopProgressBar() {
    if (_currentDuration <= Duration.zero) {
      return const SizedBox.shrink();
    }
    final totalMs = _currentDuration.inMilliseconds;
    final currentMs = _currentPosition.inMilliseconds;
    final progress = totalMs > 0 ? (currentMs / totalMs).clamp(0.0, 1.0) : 0.0;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: LinearProgressIndicator(
        value: progress.isNaN ? 0.0 : progress,
        minHeight: 4,
        backgroundColor: Colors.black45,
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white70),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.arrowRight): const _NextMediaIntent(),
        LogicalKeySet(LogicalKeyboardKey.arrowLeft):
            const _PreviousMediaIntent(),
        LogicalKeySet(LogicalKeyboardKey.escape): const _ExitIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _NextMediaIntent: CallbackAction<_NextMediaIntent>(
            onInvoke: (intent) {
              _playNext();
              return null;
            },
          ),
          _PreviousMediaIntent: CallbackAction<_PreviousMediaIntent>(
            onInvoke: (intent) {
              _playPrevious();
              return null;
            },
          ),
          _ExitIntent: CallbackAction<_ExitIntent>(
            onInvoke: (intent) {
              _handleExit();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          autofocus: true,
          child: Stack(
            children: [
              Positioned.fill(child: _buildCurrentMediaView()),
              _buildTopProgressBar(),
              _buildInfoOverlay(context),
              _buildProgressOverlay(context),
            ],
          ),
        ),
      ),
    );
  }
}
