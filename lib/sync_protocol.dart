enum AppMode { server, client }

enum SyncCommandType {
  startNow,
  next,
  previous,
  exit,
  schedule,
  ping,
  pong,
}

class SyncCommand {
  const SyncCommand(this.type, {this.payload});

  final SyncCommandType type;
  final String? payload;
}
