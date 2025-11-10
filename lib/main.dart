import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sync_test_app/video_view.dart';
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
  Timer? _startTimer;
  DateTime? _scheduledDateTime;
  bool _showVideo = false;

  @override
  void dispose() {
    _startTimer?.cancel();
    super.dispose();
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
      setState(() {
        _scheduledDateTime = scheduled;
        _showVideo = true;
      });
      return;
    }

    _startTimer = Timer(delay, () {
      if (!mounted) return;
      setState(() {
        _showVideo = true;
      });
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
            ? const VideoView()
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    key: const ValueKey('schedule_view'),
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _scheduledDateTime == null
                            ? '재생 시간을 선택하세요.'
                            : '지정 시간 ${_formatSchedule(_scheduledDateTime!)} 에 자동 재생됩니다.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: _pickScheduleTime,
                        icon: const Icon(Icons.schedule),
                        label: Text(
                          _scheduledDateTime == null ? '재생 시간 지정' : '재생 시간 변경',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
