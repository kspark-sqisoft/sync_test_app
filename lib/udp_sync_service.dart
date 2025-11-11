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
  List<InternetAddress> _broadcastTargets = const [];
  Set<String> _localIpAddresses = const {};

  bool get _isServer => mode == AppMode.server;

  Future<void> start() async {
    await stop();

    if (_isServer) {
      _broadcastTargets = await _resolveBroadcastTargets();
      _localIpAddresses = await _resolveLocalIpAddresses();
    } else {
      _broadcastTargets = const [];
      _localIpAddresses = await _resolveLocalIpAddresses();
    }

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

  Future<void> sendCommand(SyncCommand command) async {
    if (!_isServer) return;
    final message = _commandToString(command);
    final bytes = utf8.encode(message);

    final targets = _broadcastTargets.isEmpty
        ? [InternetAddress('255.255.255.255')]
        : _broadcastTargets;

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
        reusePort: true,
      );
      socket.broadcastEnabled = true;
      for (final target in targets) {
        try {
          socket.send(bytes, target, port);
        } catch (error) {
          debugPrint('Failed to send UDP packet to ${target.address}: $error');
        }
      }
    } catch (error) {
      debugPrint('Unable to create UDP send socket: $error');
    } finally {
      socket?.close();
    }
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
      while (socket.receive() != null) {}
      return;
    }
    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final messageAddress = datagram!.address.address;
      if (_localIpAddresses.contains(messageAddress)) {
        continue;
      }
      final message = utf8.decode(datagram.data).trim();
      final command = _stringToCommand(message);
      if (command != null) {
        onCommand(command);
      }
    }
  }

  Future<List<InternetAddress>> _resolveBroadcastTargets() async {
    final targets = <InternetAddress>{InternetAddress('255.255.255.255')};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type != InternetAddressType.IPv4) continue;
          final broadcast = _calculateBroadcastAddress(addr);
          if (broadcast != null) {
            targets.add(broadcast);
          }
        }
      }
    } catch (error, stack) {
      debugPrint('Failed to resolve broadcast targets: $error');
      debugPrint('$stack');
    }
    return targets.toList();
  }

  Future<Set<String>> _resolveLocalIpAddresses() async {
    final results = <String>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: true,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (addr.type == InternetAddressType.IPv4) {
            results.add(addr.address);
          }
        }
      }
    } catch (error) {
      debugPrint('Failed to resolve local IP addresses: $error');
    }
    return results;
  }

  InternetAddress? _calculateBroadcastAddress(InternetAddress address) {
    final parts = address.address.split('.');
    if (parts.length != 4) return null;
    return InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255');
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
