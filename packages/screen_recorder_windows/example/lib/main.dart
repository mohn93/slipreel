import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:screen_recorder_windows/screen_recorder_windows.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _screenRecorderWindowsPlugin = ScreenRecorderWindows();
  List<WindowInfo> _windows = [];
  List<ScreenInfo> _screens = [];
  String _status = 'Not initialized';

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  Future<void> initPlatformState() async {
    try {
      final windows = await _screenRecorderWindowsPlugin.getAvailableWindows();
      final screens = await _screenRecorderWindowsPlugin.getAvailableScreens();

      if (!mounted) return;

      setState(() {
        _windows = windows;
        _screens = screens;
        _status = 'Initialized successfully';
      });
    } on PlatformException catch (e) {
      setState(() {
        _status = 'Failed to initialize: ${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Screen Recorder Windows Example'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Status: $_status'),
              const SizedBox(height: 16),
              Text('Available Screens: ${_screens.length}'),
              ..._screens.map((screen) => Text('  - ${screen.name} (${screen.width}x${screen.height})')),
              const SizedBox(height: 16),
              Text('Available Windows: ${_windows.length}'),
              ..._windows.take(5).map((window) => Text('  - ${window.title}')),
            ],
          ),
        ),
      ),
    );
  }
}
