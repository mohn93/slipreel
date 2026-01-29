import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:screen_recorder_linux/screen_recorder_linux.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  ScreenRecorderLinux.registerWith();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _status = 'Ready';
  final _screenRecorderLinuxPlugin = ScreenRecorderLinux();
  List<ScreenInfo> _screens = [];

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  Future<void> initPlatformState() async {
    try {
      final screens = await _screenRecorderLinuxPlugin.getAvailableScreens();
      if (!mounted) return;

      setState(() {
        _screens = screens;
        _status = 'Found ${screens.length} screen(s)';
      });
    } on PlatformException catch (e) {
      if (!mounted) return;

      setState(() {
        _status = 'Failed to get screens: ${e.message}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Linux Screen Recorder Example'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Status: $_status\n'),
              const SizedBox(height: 20),
              if (_screens.isNotEmpty) ...[
                const Text('Available Screens:'),
                ..._screens.map((screen) => Text(
                      '${screen.name} (${screen.width}x${screen.height})',
                    )),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
