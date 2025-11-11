import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_test_app/media_player.dart';
import 'package:sync_test_app/sync_protocol.dart';
import 'package:sync_test_app/tcp_sync_service.dart';
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
  final TextEditingController _serverAddressController = TextEditingController(
    text: '127.0.0.1',
  );
  Timer? _startTimer;
  DateTime? _scheduledDateTime;
  bool _showVideo = false;
  AppMode _mode = AppMode.server;
  TcpSyncService? _syncService;
  final List<SyncCommand> _pendingCommands = [];
  Timer? _pendingCommandTimer;
  List<String> _localAddresses = const [];
  bool _isClientConnected = false;
  int _initialMediaIndex = 0;
  int _playbackSession = 0;
  StreamSubscription<bool>? _connectionSub;

  static const int _tcpPort = 8989;

  int get _currentMediaIndex =>
      _mediaPlayerController.currentIndex ?? _initialMediaIndex;

  @override
  void initState() {
    super.initState();
    Future.microtask(() async {
      await _loadLocalAddresses();
      await _restartSyncService();
    });
  }

  @override
  void dispose() {
    _startTimer?.cancel();
    unawaited(_syncService?.dispose());
    _mediaPlayerController.dispose();
    _pendingCommandTimer?.cancel();
    _serverAddressController.dispose();
    _connectionSub?.cancel();
    super.dispose();
  }

  void _startPlaybackNow({
    bool broadcast = true,
    DateTime? referenceTime,
    int? mediaIndex,
  }) {
    _startTimer?.cancel();
    _startTimer = null;
    final startIndex = mediaIndex ?? _currentMediaIndex;
    _initialMediaIndex = startIndex;
    final startTime = referenceTime ?? DateTime.now();
    _playbackSession++;
    setState(() {
      _scheduledDateTime = startTime;
      _showVideo = true;
    });
    if (_mode == AppMode.server && broadcast) {
      debugPrint('_startPlaybackNow');
      unawaited(
        _broadcastCommand(
          SyncCommand(
            SyncCommandType.startNow,
            payload: _encodeIndexTime(startIndex, startTime),
          ),
        ),
      );
    }
    _schedulePendingCommandProcessing();
  }

  void _handleMediaPlayerExit() {
    _startTimer?.cancel();
    _startTimer = null;
    _pendingCommandTimer?.cancel();
    _pendingCommandTimer = null;
    _pendingCommands.clear();
    setState(() {
      _scheduledDateTime = null;
      _showVideo = false;
    });
  }

  Future<void> _restartSyncService() async {
    final previous = _syncService;
    _connectionSub?.cancel();
    _connectionSub = null;
    await previous?.stop();
    final service = TcpSyncService(
      port: _tcpPort,
      mode: _mode,
      onCommand: _handleRemoteCommand,
      serverAddress: _serverAddressController.text.trim(),
    );
    await service.start();
    if (!mounted) {
      service.dispose();
      return;
    }
    _connectionSub = service.connectionState.listen((connected) {
      if (!mounted) return;
      setState(() {
        _isClientConnected = connected;
      });
    });
    setState(() {
      _syncService = service;
      _isClientConnected = _mode == AppMode.server ? true : false;
    });
    debugPrint('[Main] Sync service restarted mode=$_mode');
  }

  Future<void> _broadcastCommand(SyncCommand command) async {
    if (_mode != AppMode.server) return;
    debugPrint('[Main] broadcast ${command.type} payload=${command.payload}');
    await _syncService?.sendCommand(command);
  }

  void _handleMediaPlayerAction(MediaPlayerEvent event) {
    final payload = event.index.toString();
    debugPrint('[Main] local action ${event.action} index=${event.index}');
    _initialMediaIndex = event.index;
    switch (event.action) {
      case MediaPlayerAction.next:
        unawaited(
          _broadcastCommand(
            SyncCommand(SyncCommandType.next, payload: payload),
          ),
        );
        break;
      case MediaPlayerAction.previous:
        unawaited(
          _broadcastCommand(
            SyncCommand(SyncCommandType.previous, payload: payload),
          ),
        );
        break;
      case MediaPlayerAction.exit:
        unawaited(
          _broadcastCommand(
            SyncCommand(SyncCommandType.exit, payload: payload),
          ),
        );
        break;
    }
  }

  void _handleRemoteCommand(SyncCommand command) {
    if (!mounted) return;
    debugPrint('[Main] remote ${command.type} payload=${command.payload}');
    switch (command.type) {
      case SyncCommandType.startNow:
        final (index, time) = _decodeIndexTime(command.payload);
        final startTime = time ?? DateTime.now();
        if (index != null) {
          _initialMediaIndex = index;
        }
        _startPlaybackNow(
          broadcast: false,
          referenceTime: startTime,
          mediaIndex: index,
        );
        _schedulePendingCommandProcessing();
        break;
      case SyncCommandType.next:
        final nextIndex = _parseIndex(command.payload);
        if (nextIndex != null) {
          _initialMediaIndex = nextIndex;
        }
        _handleOrQueueRemoteCommand(command);
        break;
      case SyncCommandType.previous:
        final previousIndex = _parseIndex(command.payload);
        if (previousIndex != null) {
          _initialMediaIndex = previousIndex;
        }
        _handleOrQueueRemoteCommand(command);
        break;
      case SyncCommandType.exit:
        final exitIndex = _parseIndex(command.payload);
        if (exitIndex != null) {
          _initialMediaIndex = exitIndex;
        }
        _handleOrQueueRemoteCommand(command);
        break;
      case SyncCommandType.schedule:
        _handleScheduleCommand(command.payload);
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
    if (mode == AppMode.server) {
      await _loadLocalAddresses();
    }
    await _restartSyncService();
  }

  void _handleOrQueueRemoteCommand(SyncCommand command) {
    if (_canExecuteImmediate(command)) {
      _executeCommand(command);
    } else {
      _pendingCommands.add(command);
      _schedulePendingCommandProcessing();
    }
  }

  Future<void> _connectToServer() async {
    if (_mode != AppMode.client) return;
    final address = _serverAddressController.text.trim();
    if (address.isEmpty) return;
    debugPrint('[Main] connect to server $address');
    final service = _syncService;
    if (service == null) {
      await _restartSyncService();
    } else {
      await service.updateServerAddress(address);
    }
    await _restartSyncService();
  }

  Future<void> _disconnectFromServer() async {
    if (_mode != AppMode.client) return;
    debugPrint('[Main] disconnect from server');
    _connectionSub?.cancel();
    _connectionSub = null;
    await _syncService?.stop();
    setState(() {
      _syncService = null;
      _isClientConnected = false;
    });
  }

  bool _canExecuteImmediate(SyncCommand command) {
    if (!_showVideo) return false;
    if (!_mediaPlayerController.isAttached) return false;
    return true;
  }

  void _schedulePendingCommandProcessing() {
    if (_pendingCommands.isEmpty) return;
    _pendingCommandTimer ??= Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (!mounted) {
        timer.cancel();
        _pendingCommandTimer = null;
        return;
      }
      if (_pendingCommands.isEmpty) {
        timer.cancel();
        _pendingCommandTimer = null;
        return;
      }
      _processPendingCommands();
    });
  }

  void _processPendingCommands() {
    if (_pendingCommands.isEmpty) return;
    if (_canExecuteImmediate(_pendingCommands.first)) {
      final commands = List<SyncCommand>.from(_pendingCommands);
      _pendingCommands.clear();
      for (final command in commands) {
        _executeCommand(command);
      }
    }
  }

  void _executeCommand(SyncCommand command) {
    switch (command.type) {
      case SyncCommandType.startNow:
        final (index, time) = _decodeIndexTime(command.payload);
        final startTime = time ?? DateTime.now();
        if (index != null) {
          _initialMediaIndex = index;
        }
        _startPlaybackNow(
          broadcast: false,
          referenceTime: startTime,
          mediaIndex: index,
        );
        break;
      case SyncCommandType.next:
        final index = _parseIndex(command.payload);
        if (index != null) {
          _initialMediaIndex = index;
          _mediaPlayerController.playAt(index, fromRemote: true);
        } else {
          _mediaPlayerController.playNext(fromRemote: true);
        }
        break;
      case SyncCommandType.previous:
        final index = _parseIndex(command.payload);
        if (index != null) {
          _initialMediaIndex = index;
          _mediaPlayerController.playAt(index, fromRemote: true);
        } else {
          _mediaPlayerController.playPrevious(fromRemote: true);
        }
        break;
      case SyncCommandType.exit:
        final index = _parseIndex(command.payload);
        if (index != null) {
          _initialMediaIndex = index;
        }
        _mediaPlayerController.exit(fromRemote: true);
        break;
      case SyncCommandType.schedule:
        _handleScheduleCommand(command.payload);
        break;
    }
  }

  Future<void> _loadLocalAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final addresses = <String>{};
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4 &&
              addr.rawAddress.length == 4) {
            addresses.add(addr.address);
          }
        }
      }
      if (mounted) {
        setState(() {
          _localAddresses = addresses.isEmpty
              ? const ['알 수 없음']
              : addresses.toList();
        });
      }
    } catch (error) {
      debugPrint('Failed to load local addresses: $error');
    }
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

    _initialMediaIndex = _currentMediaIndex;
    _applySchedule(scheduled, shouldBroadcastOnStart: true);

    if (_mode == AppMode.server) {
      unawaited(
        _broadcastCommand(
          SyncCommand(
            SyncCommandType.schedule,
            payload: _encodeIndexTime(_initialMediaIndex, scheduled),
          ),
        ),
      );
    }
  }

  void _applySchedule(
    DateTime scheduled, {
    required bool shouldBroadcastOnStart,
  }) {
    _startTimer?.cancel();
    final now = DateTime.now();

    void startPlayback() {
      _startPlaybackNow(
        broadcast: shouldBroadcastOnStart,
        referenceTime: scheduled,
        mediaIndex: _initialMediaIndex,
      );
    }

    final delay = scheduled.difference(now);
    if (delay <= Duration.zero) {
      startPlayback();
      return;
    }

    _startTimer = Timer(delay, () {
      if (!mounted) return;
      debugPrint('[Main] auto start playback @ $scheduled');
      startPlayback();
    });

    setState(() {
      _scheduledDateTime = scheduled;
      _showVideo = false;
    });
  }

  void _handleScheduleCommand(String? payload) {
    final (index, scheduled) = _decodeIndexTime(payload);
    if (scheduled == null) {
      return;
    }
    if (index != null) {
      _initialMediaIndex = index;
    }
    debugPrint('[Main] apply schedule index=$index time=$scheduled');
    _applySchedule(scheduled, shouldBroadcastOnStart: false);
  }

  (int?, DateTime?) _decodeIndexTime(String? payload) {
    if (payload == null || payload.isEmpty) return (null, null);
    final separator = payload.indexOf(',');
    if (separator == -1) {
      final time = _parseDateTime(payload);
      if (time != null) {
        return (null, time);
      }
      return (_parseIndex(payload), null);
    }
    final indexPart = payload.substring(0, separator).trim();
    final timePart = payload.substring(separator + 1).trim();
    return (_parseIndex(indexPart), _parseDateTime(timePart));
  }

  String _encodeIndexTime(int index, DateTime time) =>
      '$index,${time.toUtc().toIso8601String()}';

  int? _parseIndex(String? value) {
    if (value == null || value.isEmpty) return null;
    return int.tryParse(value.trim());
  }

  DateTime? _parseDateTime(String? value) {
    if (value == null || value.isEmpty) return null;
    try {
      return DateTime.parse(value).toLocal();
    } catch (error) {
      debugPrint('Failed to parse date time payload: $value ($error)');
      return null;
    }
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
                key: ValueKey('session_$_playbackSession'),
                mediaList: _mediaList,
                controller: _mediaPlayerController,
                onAction: _handleMediaPlayerAction,
                onExit: _handleMediaPlayerExit,
                autoAdvance: _mode == AppMode.server,
                initialIndex: _initialMediaIndex,
                isActive: _showVideo,
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
                      const SizedBox(height: 16),
                      if (_mode == AppMode.server) ...[
                        Text(
                          '서버 주소',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Column(
                          children: _localAddresses
                              .map(
                                (address) => Text(
                                  address,
                                  style: Theme.of(context).textTheme.bodyMedium
                                      ?.copyWith(color: Colors.grey.shade700),
                                ),
                              )
                              .toList(),
                        ),
                      ] else ...[
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            '서버 주소',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: 260,
                          child: TextField(
                            controller: _serverAddressController,
                            decoration: const InputDecoration(
                              border: OutlineInputBorder(),
                              hintText: '예: 192.168.0.10',
                              isDense: true,
                            ),
                            onSubmitted: (_) => _connectToServer(),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ElevatedButton.icon(
                          onPressed: _isClientConnected
                              ? _disconnectFromServer
                              : _connectToServer,
                          icon: Icon(
                            _isClientConnected ? Icons.link_off : Icons.link,
                          ),
                          label: Text(_isClientConnected ? '연결 해제' : '서버 연결'),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _isClientConnected
                              ? '서버와 연결되었습니다.'
                              : '서버에 연결해야 재생 제어가 동기화됩니다.',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: Colors.grey.shade600),
                        ),
                      ],
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
