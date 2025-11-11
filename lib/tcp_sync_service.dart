import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sync_protocol.dart';

class TcpSyncService {
  TcpSyncService({
    required this.port,
    required this.mode,
    required this.onCommand,
    this.serverAddress,
  });

  final int port;
  final AppMode mode;
  final ValueChanged<SyncCommand> onCommand;

  String? serverAddress;

  ServerSocket? _serverSocket;
  final Set<Socket> _clients = {};

  Socket? _clientSocket;
  StreamSubscription<List<int>>? _clientSubscription;
  String _clientBuffer = '';
  StreamSubscription<Socket>? _serverSubscription;
  Timer? _reconnectTimer;
  final StreamController<bool> _connectionStateController =
      StreamController<bool>.broadcast();
  bool _isConnected = false;

  bool get _isServer => mode == AppMode.server;
  Stream<bool> get connectionState async* {
    if (_isServer) {
      yield true;
    } else {
      yield _isConnected;
      yield* _connectionStateController.stream;
    }
  }

  Future<void> start({String? serverAddress}) async {
    await stop();

    if (serverAddress != null) {
      this.serverAddress = serverAddress;
    }

    if (_isServer) {
      await _startServer();
    } else {
      await _connectToServer();
    }
  }

  Future<void> stop() async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _setClientConnected(false);

    await _clientSubscription?.cancel();
    _clientSubscription = null;
    await _clientSocket?.close();
    _clientSocket = null;

    await _serverSubscription?.cancel();
    _serverSubscription = null;

    for (final client in _clients.toList()) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();

    await _serverSocket?.close();
    _serverSocket = null;
  }

  Future<void> dispose() async {
    await stop();
    await _connectionStateController.close();
  }

  Future<void> sendCommand(SyncCommand command) async {
    if (!_isServer) return;
    final message = '${_encodeCommand(command)}\n';
    final data = utf8.encode(message);
    debugPrint(
      '[TcpSyncService] send ${command.type} payload=${command.payload}',
    );
    for (final client in _clients.toList()) {
      try {
        client.add(data);
        await client.flush();
        debugPrint(
          '[TcpSyncService] -> ${client.address}:$port ${command.type} payload=${command.payload}',
        );
      } catch (error) {
        debugPrint('Failed to send command to ${client.remoteAddress}: $error');
        await _removeClient(client);
      }
    }
  }

  Future<void> updateServerAddress(String address) async {
    serverAddress = address;
    if (!_isServer) {
      await start();
    }
  }

  Future<void> _startServer() async {
    final shared = !Platform.isWindows;
    final server = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      port,
      shared: shared,
    );
    _serverSocket = server;
    _serverSubscription = server.listen(
      _handleIncomingConnection,
      onError: (error) => debugPrint('TCP server error: $error'),
      onDone: () => debugPrint('TCP server closed'),
    );
    debugPrint('TCP sync server listening on port $port');
  }

  void _handleIncomingConnection(Socket client) {
    _clients.add(client);
    debugPrint(
      'Client connected: ${client.remoteAddress.address}:${client.remotePort}',
    );
    client.done.then((_) => _removeClient(client));
    client.listen(
      (_) {},
      onError: (error) {
        debugPrint('Client socket error: $error');
      },
      onDone: () => _removeClient(client),
      cancelOnError: true,
    );
  }

  Future<void> _removeClient(Socket client) async {
    if (_clients.remove(client)) {
      debugPrint(
        'Client disconnected: ${client.remoteAddress.address}:${client.remotePort}',
      );
    }
    try {
      await client.close();
    } catch (_) {}
  }

  Future<void> _connectToServer() async {
    final host = serverAddress;
    if (host == null || host.isEmpty) {
      debugPrint('No TCP server address configured');
      return;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = null;

    try {
      debugPrint('Connecting to TCP sync server $host:$port');
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 3),
      );
      _clientSocket = socket;
      _setClientConnected(true);
      _clientBuffer = '';
      _clientSubscription = socket.listen(
        _handleIncomingData,
        onError: (error) {
          debugPrint('TCP client error: $error');
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      debugPrint('Connected to TCP sync server');
    } catch (error) {
      debugPrint('Unable to connect to TCP sync server: $error');
      _scheduleReconnect();
    }
  }

  void _handleIncomingData(List<int> data) {
    if (_clientSocket == null) {
      return;
    }
    _clientBuffer += utf8.decode(data);
    int newlineIndex;
    while ((newlineIndex = _clientBuffer.indexOf('\n')) != -1) {
      final line = _clientBuffer.substring(0, newlineIndex).trim();
      _clientBuffer = _clientBuffer.substring(newlineIndex + 1);
      final command = _decodeCommand(line);
      if (command != null) {
        onCommand(command);
      }
    }
  }

  void _scheduleReconnect([dynamic _]) {
    _clientSubscription?.cancel();
    _clientSubscription = null;
    _clientSocket?.destroy();
    _clientSocket = null;
    _setClientConnected(false);

    if (_isServer) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), _connectToServer);
  }

  void _setClientConnected(bool value) {
    if (_isConnected == value) return;
    _isConnected = value;
    _connectionStateController.add(value);
  }

  String _encodeCommand(SyncCommand command) {
    final type = _encodeType(command.type);
    if (command.payload == null || command.payload!.isEmpty) {
      return type;
    }
    final payload = command.payload!.replaceAll('\n', '\\n');
    return '$type|$payload';
  }

  SyncCommand? _decodeCommand(String raw) {
    if (raw.isEmpty) return null;
    final parts = raw.split('|');
    final typeString = parts.first.toUpperCase();
    final type = _decodeType(typeString);
    if (type == null) return null;
    final payload = parts.length > 1 ? parts.sublist(1).join('|') : null;
    final value = payload?.replaceAll('\\n', '\n');
    final command = SyncCommand(type, payload: value);
    debugPrint('[TcpSyncService] recv $type payload=$value');
    return command;
  }

  String _encodeType(SyncCommandType type) {
    switch (type) {
      case SyncCommandType.startNow:
        return 'START_NOW';
      case SyncCommandType.next:
        return 'NEXT';
      case SyncCommandType.previous:
        return 'PREVIOUS';
      case SyncCommandType.exit:
        return 'EXIT';
      case SyncCommandType.schedule:
        return 'SCHEDULE';
    }
  }

  SyncCommandType? _decodeType(String value) {
    switch (value) {
      case 'START_NOW':
        return SyncCommandType.startNow;
      case 'NEXT':
        return SyncCommandType.next;
      case 'PREVIOUS':
        return SyncCommandType.previous;
      case 'EXIT':
        return SyncCommandType.exit;
      case 'SCHEDULE':
        return SyncCommandType.schedule;
      default:
        return null;
    }
  }
}
