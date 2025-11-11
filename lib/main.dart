import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_test_app/media_player.dart';
import 'package:sync_test_app/sync_protocol.dart';
import 'package:sync_test_app/tcp_sync_service.dart';
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
  final TextEditingController _serverAddressController = TextEditingController(
    text: '127.0.0.1',
  );
  Timer? _startTimer;
  DateTime? _scheduledDateTime;
  bool _showVideo = false;
  AppMode _mode = AppMode.server;
  TcpSyncService? _syncService;
  UdpSyncService? _udpSyncService;
  final List<SyncCommand> _pendingCommands = [];
  Timer? _pendingCommandTimer;
  Timer? _udpBroadcastTimer;
  List<String> _localAddresses = const [];
  bool _isClientConnected = false;
  bool _udpSyncEnabled = true;
  int _initialMediaIndex = 0;
  int _playbackSession = 0;
  StreamSubscription<bool>? _connectionSub;
  double _currentPlaybackSpeed = 1.0;
  Timer? _pingTimer;
  int? _lastPingSentMs;
  int _networkDelayMs = 0;
  int _clockOffsetMs = 0;
  int? _lastSyncDiffMs;
  bool _syncHealthy = true;
  DateTime? _lastSyncUpdatedAt;
  String _syncStatusMessage = '동기화 정보를 수신 대기중입니다.';

  static const int _tcpPort = 8989;
  static const int _udpSyncPort = 45455;

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
    _udpSyncService?.dispose();
    _mediaPlayerController.dispose();
    _pendingCommandTimer?.cancel();
    _udpBroadcastTimer?.cancel();
    _pingTimer?.cancel();
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
    _currentPlaybackSpeed = 1.0;
    _lastSyncDiffMs = null;
    _syncHealthy = true;
    _syncStatusMessage = _udpSyncEnabled
        ? '동기화 정보를 수신 대기중입니다.'
        : 'UDP 동기화 비활성화됨';
    _lastSyncUpdatedAt = null;
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
    if (_udpSyncEnabled) {
      _startUdpSyncService();
    }
  }

  void _handleMediaPlayerExit() {
    _startTimer?.cancel();
    _startTimer = null;
    _pendingCommandTimer?.cancel();
    _pendingCommandTimer = null;
    _pendingCommands.clear();
    _udpBroadcastTimer?.cancel();
    _udpBroadcastTimer = null;
    _udpSyncService?.stop();
    _currentPlaybackSpeed = 1.0;
    _lastSyncDiffMs = null;
    _syncHealthy = true;
    _syncStatusMessage = _udpSyncEnabled
        ? '동기화 정보를 수신 대기중입니다.'
        : 'UDP 동기화 비활성화됨';
    _lastSyncUpdatedAt = null;
    setState(() {
      _scheduledDateTime = null;
      _showVideo = false;
    });
  }

  Future<void> _restartSyncService() async {
    final previous = _syncService;
    _connectionSub?.cancel();
    _connectionSub = null;
    if (_mode == AppMode.client) {
      _stopPingTimer();
    }
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
      if (_mode == AppMode.client) {
        if (connected) {
          _startPingTimer();
        } else {
          _stopPingTimer();
        }
      }
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
    if (_mode == AppMode.server && _udpSyncEnabled) {
      Future.delayed(const Duration(seconds: 1), () {
        if (!_udpSyncEnabled ||
            _mode != AppMode.server ||
            !_showVideo ||
            !_mediaPlayerController.isAttached ||
            _mediaPlayerController.currentIndex != event.index) {
          return;
        }
        _broadcastUdpSyncData();
      });
    }
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
      case SyncCommandType.ping:
        // handled at transport layer
        break;
      case SyncCommandType.pong:
        _handlePongCommand(command.payload);
        break;
    }
  }

  void _startPingTimer() {
    if (_mode != AppMode.client) return;
    _pingTimer?.cancel();
    _sendPing();
    _pingTimer = Timer.periodic(const Duration(seconds: 3), (_) => _sendPing());
  }

  void _stopPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _lastPingSentMs = null;
  }

  void _sendPing() {
    if (_mode != AppMode.client) return;
    final service = _syncService;
    if (service == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _lastPingSentMs = now;
    debugPrint('[Ping] send $now');
    unawaited(
      service.sendClientCommand(
        SyncCommand(SyncCommandType.ping, payload: now.toString()),
      ),
    );
  }

  void _handlePongCommand(String? payload) {
    if (_mode != AppMode.client) return;
    final parts = payload?.split('|');
    if (parts == null || parts.length < 2) return;
    final sentMs = int.tryParse(parts[0]);
    final serverMs = int.tryParse(parts[1]);
    if (sentMs == null || serverMs == null) return;
    if (_lastPingSentMs != null && sentMs != _lastPingSentMs) {
      debugPrint(
        '[Ping] ignoring pong for stale ping sent=$sentMs expected=$_lastPingSentMs',
      );
      return;
    }
    final receiveMs = DateTime.now().millisecondsSinceEpoch;
    final rtt = receiveMs - sentMs;
    if (rtt <= 0) return;
    final delay = (rtt / 2).round();
    final offset = serverMs - (sentMs + delay);
    _networkDelayMs = delay;
    _clockOffsetMs = offset;
    debugPrint('[Ping] pong rtt=${rtt}ms delay=$delay offset=$offset');
    final diff = _lastSyncDiffMs ?? 0;
    _updateSyncStatus(
      diffMs: diff,
      healthy: _syncHealthy,
      status: '핑 RTT=${rtt}ms 지연≈${delay}ms 오프셋=${offset}ms',
    );
  }

  Future<void> _changeMode(AppMode mode) async {
    if (_mode == mode) return;
    _startTimer?.cancel();
    _startTimer = null;
    _stopPingTimer();
    if (_showVideo) {
      _mediaPlayerController.exit(fromRemote: true);
    }
    setState(() {
      _mode = mode;
      if (mode == AppMode.client) {
        _scheduledDateTime = null;
      }
    });
    _networkDelayMs = 0;
    _clockOffsetMs = 0;
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
    _stopPingTimer();
    _networkDelayMs = 0;
    _clockOffsetMs = 0;
    _lastPingSentMs = null;
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
      case SyncCommandType.ping:
      case SyncCommandType.pong:
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

  void _setUdpSyncEnabled(bool value) {
    if (_udpSyncEnabled == value) return;
    if (!value) {
      _udpBroadcastTimer?.cancel();
      _udpBroadcastTimer = null;
      unawaited(_udpSyncService?.stop());
      setState(() {
        _udpSyncEnabled = value;
        _lastSyncDiffMs = null;
        _syncHealthy = true;
        _syncStatusMessage = 'UDP 동기화 비활성화됨';
      });
      return;
    }

    setState(() {
      _udpSyncEnabled = value;
      _syncHealthy = true;
      _lastSyncDiffMs = null;
      _syncStatusMessage = '동기화 정보를 수신 대기중입니다.';
    });

    if (_showVideo) {
      _startUdpSyncService();
    }
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

  Future<void> _startUdpSyncService() async {
    if (!_udpSyncEnabled) {
      return;
    }
    await _udpSyncService?.stop();
    final service = UdpSyncService(
      port: _udpSyncPort,
      isServer: _mode == AppMode.server,
      onSyncData: _mode == AppMode.client ? _handleSyncData : null,
    );
    await service.start();
    if (!mounted) {
      service.dispose();
      return;
    }
    _udpSyncService = service;
    setState(() {
      _syncHealthy = true;
      _lastSyncDiffMs = null;
      _syncStatusMessage = '동기화 정보를 수신 대기중입니다.';
    });

    if (_mode == AppMode.server) {
      // 서버: 주기적으로 현재 상태 브로드캐스트
      _udpBroadcastTimer?.cancel();
      _udpBroadcastTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _broadcastUdpSyncData(),
      );
    }
  }

  void _broadcastUdpSyncData() {
    if (!_udpSyncEnabled || _mode != AppMode.server || !_showVideo) return;
    final index = _mediaPlayerController.currentIndex ?? _initialMediaIndex;
    final elapsed =
        _mediaPlayerController.currentElapsedMs ?? _estimatedElapsedMs();
    debugPrint(
      '[UDP] broadcast index=$index elapsed=${elapsed}ms session=$_playbackSession',
    );
    _udpSyncService?.broadcastSyncData(index, elapsed);
  }

  void _handleSyncData(MediaSyncData data) {
    if (!_udpSyncEnabled || _mode != AppMode.client || !_showVideo) return;
    if (!_mediaPlayerController.isAttached) return;

    final clientIndex = _mediaPlayerController.currentIndex;
    final clientElapsed = _mediaPlayerController.currentElapsedMs;

    if (clientIndex == null || clientElapsed == null) return;

    // 미디어 인덱스가 다르면 즉시 맞춤
    if (clientIndex != data.mediaIndex) {
      debugPrint(
        '[UdpSync] Index mismatch: client=$clientIndex server=${data.mediaIndex}, jumping',
      );
      _updateSyncStatus(
        diffMs: 0,
        healthy: false,
        status:
            '미디어 인덱스 불일치 → ${data.mediaIndex} 번으로 이동합니다. (지연≈${_networkDelayMs}ms)',
      );
      _mediaPlayerController.playAt(data.mediaIndex, fromRemote: true);
      return;
    }

    // 네트워크 지연 보정
    final clientTime = DateTime.now().millisecondsSinceEpoch;
    int serverNowEstimate = clientTime + _clockOffsetMs;
    int transit = serverNowEstimate - data.serverTimestampMs;
    if (transit < 0) {
      transit = 0;
    }
    if (_networkDelayMs > 0 && transit < _networkDelayMs) {
      transit = _networkDelayMs;
    }
    final serverElapsedAdjusted = data.elapsedMs + transit;

    // 경과 시간 차이 계산
    final diff = serverElapsedAdjusted - clientElapsed;
    final absDiff = diff.abs();
    debugPrint(
      '[UdpSync] diff=${diff}ms (transit=$transit, server=${data.elapsedMs}, client=$clientElapsed, offset=$_clockOffsetMs)',
    );

    // 큰 차이(500ms 이상)는 즉시 seekTo로 맞춤
    if (absDiff > 400) {
      debugPrint(
        '[UdpSync] Large diff: ${diff}ms, seeking to ${serverElapsedAdjusted}ms',
      );
      _mediaPlayerController.seekToMs(serverElapsedAdjusted);
      _currentPlaybackSpeed = 1.0;
      _updateSyncStatus(
        diffMs: diff,
        healthy: false,
        status: '큰 오차 감지 (Δ=${diff}ms, 지연≈${transit}ms) → 즉시 위치 조정',
      );
      return;
    }

    // 작은 차이(100ms 이상)는 재생 속도 조절
    if (absDiff > 80) {
      // 차이를 줄이기 위한 속도 계산
      // 서버보다 느리면 빠르게 (diff > 0), 빠르면 느리게 (diff < 0)
      double targetSpeed;
      if (diff > 0) {
        // 클라이언트가 느림 -> 빠르게 (최대 1.05x)
        targetSpeed = 1.0 + (diff / 2000.0).clamp(0.0, 0.05);
      } else {
        // 클라이언트가 빠름 -> 느리게 (최소 0.95x)
        targetSpeed = 1.0 + (diff / 2000.0).clamp(-0.05, 0.0);
      }

      // 속도 변화가 크면 점진적으로 조절
      if ((targetSpeed - _currentPlaybackSpeed).abs() > 0.003) {
        _currentPlaybackSpeed = targetSpeed;
        _mediaPlayerController.adjustPlaybackSpeed(targetSpeed);
        debugPrint(
          '[UdpSync] Adjusting speed: ${targetSpeed.toStringAsFixed(3)}x (diff: ${diff}ms)',
        );
      }
      _updateSyncStatus(
        diffMs: diff,
        healthy: absDiff <= 150,
        status:
            '속도 조절 중 (Δ=${diff}ms, 속도=${_currentPlaybackSpeed.toStringAsFixed(3)}x, 지연≈${transit}ms)',
      );
    } else {
      // 차이가 작으면 정상 속도로 복귀
      if (_currentPlaybackSpeed != 1.0) {
        _currentPlaybackSpeed = 1.0;
        _mediaPlayerController.adjustPlaybackSpeed(1.0);
        debugPrint('[UdpSync] Resetting speed to 1.0x');
      }
      _updateSyncStatus(
        diffMs: diff,
        healthy: true,
        status:
            '안정 상태 (Δ=${diff}ms, 속도=${_currentPlaybackSpeed.toStringAsFixed(3)}x, 지연≈${transit}ms)',
      );
    }
  }

  int _estimatedElapsedMs() {
    final scheduled = _scheduledDateTime;
    if (scheduled == null) {
      return 0;
    }
    final diff = DateTime.now().difference(scheduled).inMilliseconds;
    if (diff.isNegative) {
      return 0;
    }
    return diff;
  }

  void _updateSyncStatus({
    required int diffMs,
    required bool healthy,
    required String status,
  }) {
    if (!mounted) return;
    final now = DateTime.now();
    final shouldUpdate =
        healthy != _syncHealthy ||
        _lastSyncDiffMs == null ||
        (_lastSyncDiffMs! - diffMs).abs() > 15 ||
        _lastSyncUpdatedAt == null ||
        now.difference(_lastSyncUpdatedAt!).inMilliseconds >= 400 ||
        _syncStatusMessage != status;
    if (!shouldUpdate) {
      return;
    }
    setState(() {
      _syncHealthy = healthy;
      _lastSyncDiffMs = diffMs;
      _syncStatusMessage = status;
      _lastSyncUpdatedAt = now;
    });
  }

  Widget _buildSyncIndicator(BuildContext context) {
    final healthy = _syncHealthy;
    final color = healthy ? Colors.greenAccent : Colors.redAccent;
    final diffText = _lastSyncDiffMs == null
        ? 'N/A'
        : '${_lastSyncDiffMs!.abs()} ms';

    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: healthy ? Colors.greenAccent : Colors.redAccent,
                width: 1.5,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: color,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: color.withValues(alpha: 0.7),
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        healthy ? '동기화 정상' : '동기화 조정 중',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Δ $diffText',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _syncStatusMessage,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.white70),
                    textAlign: TextAlign.right,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
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
            ? Stack(
                children: [
                  MediaPlayer(
                    key: ValueKey('session_$_playbackSession'),
                    mediaList: _mediaList,
                    controller: _mediaPlayerController,
                    onAction: _handleMediaPlayerAction,
                    onExit: _handleMediaPlayerExit,
                    autoAdvance: _mode == AppMode.server,
                    initialIndex: _initialMediaIndex,
                    isActive: _showVideo,
                  ),
                  if (_mode == AppMode.client && _udpSyncEnabled)
                    _buildSyncIndicator(context),
                ],
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
                      SwitchListTile.adaptive(
                        value: _udpSyncEnabled,
                        onChanged: (value) => _setUdpSyncEnabled(value),
                        contentPadding: EdgeInsets.zero,
                        title: const Text('UDP 동기화 사용'),
                        subtitle: Text(
                          _mode == AppMode.server
                              ? '서버가 UDP 브로드캐스트로 클라이언트를 동기화합니다.'
                              : '서버로부터 UDP 브로드캐스트를 수신해 동기화합니다.',
                        ),
                      ),
                      const SizedBox(height: 12),
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
