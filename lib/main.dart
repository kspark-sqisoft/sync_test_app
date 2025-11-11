import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_test_app/media_player.dart';
import 'package:sync_test_app/sync_protocol.dart';
import 'package:sync_test_app/udp_sync_service.dart';
import 'package:video_player_media_kit/video_player_media_kit.dart';

void main() {
  VideoPlayerMediaKit.ensureInitialized(windows: true, android: true);
  runApp(ProviderScope(child: const MyApp()));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(debugShowCheckedModeBanner: false, home: MyHomePage());
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final List<String> _mediaList = [
    'assets/video/video0.mp4',
    'assets/image/image0.jpg',
    'assets/video/video1.mp4',
    'assets/image/image1.jpg',
    'assets/video/video2.mp4',
    'assets/image/image2.jpg',
  ];
  final MediaPlayerController _mediaPlayerController = MediaPlayerController();
  Timer? _startTimer;
  DateTime? _scheduledDateTime;
  bool _showVideo = false;
  AppMode _mode = AppMode.server;
  UdpSyncService? _udpService;

  static const int _udpPort = 45454;

  @override
  void initState() {
    super.initState();
    Future.microtask(_restartUdpService);
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    _udpService?.dispose();
    _mediaPlayerController.dispose();
    super.dispose();
  }

  void _startPlaybackNow({bool broadcast = true, DateTime? referenceTime}) {
    _startTimer?.cancel();
    _startTimer = null;
    setState(() {
      _scheduledDateTime = referenceTime ?? DateTime.now();
      _showVideo = true;
    });
    if (_mode == AppMode.server && broadcast) {
      _broadcastCommand(SyncCommand.startNow);
    }
  }

  void _handleMediaPlayerExit() {
    _startTimer?.cancel();
    _startTimer = null;
    setState(() {
      _scheduledDateTime = null;
      _showVideo = false;
    });
  }

  Future<void> _restartUdpService() async {
    final previous = _udpService;
    await previous?.stop();
    final service = UdpSyncService(
      port: _udpPort,
      mode: _mode,
      onCommand: _handleRemoteCommand,
    );
    await service.start();
    if (!mounted) {
      service.dispose();
      return;
    }
    setState(() {
      _udpService = service;
    });
  }

  void _broadcastCommand(SyncCommand command) {
    if (_mode != AppMode.server) return;
    _udpService?.sendCommand(command);
  }

  void _handleMediaPlayerAction(MediaPlayerAction action) {
    switch (action) {
      case MediaPlayerAction.next:
        _broadcastCommand(SyncCommand.next);
        break;
      case MediaPlayerAction.previous:
        _broadcastCommand(SyncCommand.previous);
        break;
      case MediaPlayerAction.exit:
        _broadcastCommand(SyncCommand.exit);
        break;
    }
  }

  void _handleRemoteCommand(SyncCommand command) {
    if (!mounted) return;
    switch (command) {
      case SyncCommand.startNow:
        _startPlaybackNow(broadcast: false);
        break;
      case SyncCommand.next:
        if (_showVideo) {
          _mediaPlayerController.playNext(fromRemote: true);
        }
        break;
      case SyncCommand.previous:
        if (_showVideo) {
          _mediaPlayerController.playPrevious(fromRemote: true);
        }
        break;
      case SyncCommand.exit:
        if (_showVideo) {
          _mediaPlayerController.exit(fromRemote: true);
        }
        break;
    }
  }

  Future<void> _changeMode(AppMode mode) async {
    if (_mode == mode) return;
    _startTimer?.cancel();
    _startTimer = null;
    if (_showVideo) {
      _mediaPlayerController.exit(fromRemote: true);
    }
    setState(() {
      _mode = mode;
      if (mode == AppMode.client) {
        _scheduledDateTime = null;
      }
    });
    await _restartUdpService();
  }

  Future<void> _pickScheduleTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );

    if (picked == null) {
      return;
    }

    _scheduleVideoStart(picked);
  }

  void _scheduleVideoStart(TimeOfDay time) {
    final now = DateTime.now();
    DateTime scheduled = DateTime(
      now.year,
      now.month,
      now.day,
      time.hour,
      time.minute,
    );

    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }

    _startTimer?.cancel();

    final delay = scheduled.difference(now);
    if (delay.inSeconds <= 0) {
      _startPlaybackNow(referenceTime: scheduled);
      return;
    }

    _startTimer = Timer(delay, () {
      if (!mounted) return;
      _startPlaybackNow(referenceTime: scheduled);
    });

    setState(() {
      _scheduledDateTime = scheduled;
      _showVideo = false;
    });
  }

  String _formatSchedule(DateTime dateTime) {
    final timeOfDay = TimeOfDay.fromDateTime(dateTime);
    final hour = timeOfDay.hourOfPeriod == 0 ? 12 : timeOfDay.hourOfPeriod;
    final minute = timeOfDay.minute.toString().padLeft(2, '0');
    final period = timeOfDay.period == DayPeriod.am ? 'AM' : 'PM';
    return '$period $hour:$minute';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _showVideo
            ? MediaPlayer(
                key: ValueKey(_scheduledDateTime),
                mediaList: _mediaList,
                controller: _mediaPlayerController,
                onAction: _handleMediaPlayerAction,
                onExit: _handleMediaPlayerExit,
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    key: const ValueKey('schedule_view'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '동기화 모드',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(width: 12),
                          DropdownButton<AppMode>(
                            value: _mode,
                            onChanged: (mode) {
                              if (mode != null) {
                                Future.microtask(() => _changeMode(mode));
                              }
                            },
                            items: const [
                              DropdownMenuItem(
                                value: AppMode.server,
                                child: Text('서버'),
                              ),
                              DropdownMenuItem(
                                value: AppMode.client,
                                child: Text('클라이언트'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _mode == AppMode.client
                            ? '클라이언트 모드입니다. 서버 신호를 기다리고 있습니다.'
                            : _scheduledDateTime == null
                            ? '재생 시간을 선택하세요.'
                            : '지정 시간 ${_formatSchedule(_scheduledDateTime!)} 에 자동 재생됩니다.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      if (_mode == AppMode.client) ...[
                        const SizedBox(height: 12),
                        Text(
                          '재생 제어는 서버에서만 가능합니다.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey.shade600),
                        ),
                      ],
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _mode == AppMode.server
                            ? _pickScheduleTime
                            : null,
                        icon: const Icon(Icons.schedule),
                        label: Text(
                          _scheduledDateTime == null ? '재생 시간 지정' : '재생 시간 변경',
                        ),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton.icon(
                        onPressed: _mode == AppMode.server
                            ? () => _startPlaybackNow()
                            : null,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('바로 재생'),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
