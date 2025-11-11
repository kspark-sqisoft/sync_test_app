import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'sync_protocol.dart';

class UdpSyncService {
  UdpSyncService({
    required this.port,
    required this.mode,
    required this.onCommand,
  });

  final int port;
  final AppMode mode;
  final ValueChanged<SyncCommand> onCommand;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;

  bool get _isServer => mode == AppMode.server;

  Future<void> start() async {
    await stop();
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: true,
    );
    socket.broadcastEnabled = true;
    _socket = socket;

    _subscription = socket.listen(
      _handleSocketEvent,
      onError: (error, stackTrace) {
        debugPrint('UDP socket error: $error');
      },
      onDone: () {
        debugPrint('UDP socket closed');
      },
    );
  }

  void sendCommand(SyncCommand command) {
    if (!_isServer) return;
    final socket = _socket;
    if (socket == null) return;
    final message = _commandToString(command);
    final bytes = utf8.encode(message);
    socket.send(bytes, InternetAddress('255.255.255.255'), port);
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    final socket = _socket;
    _socket = null;
    socket?.close();
  }

  void dispose() {
    stop();
  }

  void _handleSocketEvent(RawSocketEvent event) {
    final socket = _socket;
    if (socket == null) {
      return;
    }
    if (event != RawSocketEvent.read) {
      return;
    }
    if (_isServer) {
      // Drain incoming packets when acting as server.
      socket.receive();
      return;
    }
    final datagram = socket.receive();
    if (datagram == null) return;
    final message = utf8.decode(datagram.data).trim();
    final command = _stringToCommand(message);
    if (command != null) {
      onCommand(command);
    }
  }

  String _commandToString(SyncCommand command) {
    switch (command) {
      case SyncCommand.startNow:
        return 'START_NOW';
      case SyncCommand.next:
        return 'NEXT';
      case SyncCommand.previous:
        return 'PREVIOUS';
      case SyncCommand.exit:
        return 'EXIT';
    }
  }

  SyncCommand? _stringToCommand(String raw) {
    switch (raw.toUpperCase()) {
      case 'START_NOW':
        return SyncCommand.startNow;
      case 'NEXT':
        return SyncCommand.next;
      case 'PREVIOUS':
        return SyncCommand.previous;
      case 'EXIT':
        return SyncCommand.exit;
    }
    return null;
  }
}
