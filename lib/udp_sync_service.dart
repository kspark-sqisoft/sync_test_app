import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class MediaSyncData {
  const MediaSyncData({
    required this.mediaIndex,
    required this.elapsedMs,
    required this.serverTimestampMs,
  });

  final int mediaIndex;
  final int elapsedMs;
  final int serverTimestampMs;

  String encode() {
    return '$mediaIndex,$elapsedMs,$serverTimestampMs';
  }

  static MediaSyncData? decode(String raw) {
    final parts = raw.split(',');
    if (parts.length != 3) return null;
    try {
      return MediaSyncData(
        mediaIndex: int.parse(parts[0]),
        elapsedMs: int.parse(parts[1]),
        serverTimestampMs: int.parse(parts[2]),
      );
    } catch (_) {
      return null;
    }
  }
}

class UdpSyncService {
  UdpSyncService({required this.port, required this.isServer, this.onSyncData});

  final int port;
  final bool isServer;
  final ValueChanged<MediaSyncData>? onSyncData;

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _subscription;

  Future<void> start() async {
    await stop();
    final shared = !Platform.isWindows;
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      port,
      reuseAddress: true,
      reusePort: shared,
    );
    socket.broadcastEnabled = true;
    _socket = socket;

    _subscription = socket.listen(
      _handleSocketEvent,
      onError: (error, stackTrace) {
        debugPrint('[UdpSyncService] Socket error: $error');
      },
      onDone: () {
        debugPrint('[UdpSyncService] Socket closed');
      },
    );

    if (isServer) {
      debugPrint('[UdpSyncService] Server started on port $port');
    } else {
      debugPrint('[UdpSyncService] Client started on port $port');
    }
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    _socket?.close();
    _socket = null;
  }

  void dispose() {
    stop();
  }

  void broadcastSyncData(int mediaIndex, int elapsedMs) {
    if (!isServer) return;
    final serverTime = DateTime.now().millisecondsSinceEpoch;
    final data = MediaSyncData(
      mediaIndex: mediaIndex,
      elapsedMs: elapsedMs,
      serverTimestampMs: serverTime,
    );
    _sendBroadcast(data);
  }

  void _sendBroadcast(MediaSyncData data) {
    final socket = _socket;
    if (socket == null) return;
    final message = data.encode();
    final bytes = utf8.encode(message);
    try {
      socket.send(bytes, InternetAddress('255.255.255.255'), port);
    } catch (error) {
      debugPrint('[UdpSyncService] Failed to send broadcast: $error');
    }
  }

  void _handleSocketEvent(RawSocketEvent event) {
    final socket = _socket;
    if (socket == null) return;
    if (event != RawSocketEvent.read) return;

    if (isServer) {
      // Drain incoming packets when acting as server
      while (socket.receive() != null) {}
      return;
    }

    Datagram? datagram;
    while ((datagram = socket.receive()) != null) {
      final d = datagram;
      if (d == null) continue;
      final dataBytes = d.data;
      if (dataBytes.isEmpty) continue;
      final message = utf8.decode(dataBytes).trim();
      final data = MediaSyncData.decode(message);
      if (data != null) {
        onSyncData?.call(data);
      }
    }
  }
}
