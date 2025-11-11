enum AppMode { server, client }

enum SyncCommandType { startNow, next, previous, exit, schedule }

class SyncCommand {
  const SyncCommand(this.type, {this.payload});

  final SyncCommandType type;
  final String? payload;
}
