import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:screen_recorder_macos/screen_recorder_macos.dart';

void main() {
  // Register the macOS implementation
  ScreenRecorderMacos.registerWith();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  String _status = 'Initializing...';

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  Future<void> initPlatformState() async {
    String status;
    try {
      // Try to check permissions as a simple test
      final hasPermissions = await ScreenRecorderPlatform.instance.checkPermissions();
      status = 'Plugin loaded. Permissions: ${hasPermissions ? 'Granted' : 'Not granted'}';
    } on PlatformException catch (e) {
      status = 'Plugin loaded. Error: ${e.message}';
    }

    if (!mounted) return;

    setState(() {
      _status = status;
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Screen Recorder macOS Example'),
        ),
        body: Center(
          child: Text('Status: $_status\n'),
        ),
      ),
    );
  }
}
