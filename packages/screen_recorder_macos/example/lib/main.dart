import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:io';

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
  bool _isRecording = false;
  String? _lastOutputPath;
  StreamSubscription<CursorPosition>? _cursorSubscription;
  int _cursorSampleCount = 0;
  CursorPosition? _lastCursorPosition;

  @override
  void initState() {
    super.initState();
    initPlatformState();
  }

  @override
  void dispose() {
    _cursorSubscription?.cancel();
    super.dispose();
  }

  Future<void> initPlatformState() async {
    String status;
    try {
      // Try to check permissions as a simple test
      final permStatus =
          await ScreenRecorderPlatform.instance.getScreenRecordingPermission();
      status =
          'Plugin loaded. Permissions: ${permStatus.name}';
    } on PlatformException catch (e) {
      status = 'Plugin loaded. Error: ${e.message}';
    }

    if (!mounted) return;

    setState(() {
      _status = status;
    });
  }

  Future<void> _startRecording() async {
    try {
      // Subscribe to cursor stream (still available on the live path).
      _cursorSubscription =
          ScreenRecorderPlatform.instance.cursorStream.listen(
        (cursorData) {
          setState(() {
            _cursorSampleCount++;
            _lastCursorPosition = cursorData;
          });
        },
        onError: (error) {
          // ignore: avoid_print
          print('Cursor stream error: $error');
        },
      );

      final tmp = Directory.systemTemp;
      final outputPath =
          '${tmp.path}/screen_recorder_macos_example_${DateTime.now().millisecondsSinceEpoch}.mp4';

      // Use the live recording path — writes a finalized MP4 directly to
      // [outputPath]. (The legacy spool path that emitted raw frames over
      // an EventChannel has been removed.)
      await ScreenRecorderPlatform.instance.startLiveRecording(
        settings: const RecordingSettings(
          source: RecordingSource.screen,
          frameRate: 30,
        ),
        outputPath: outputPath,
        width: 1920,
        height: 1080,
      );

      setState(() {
        _isRecording = true;
        _cursorSampleCount = 0;
        _lastOutputPath = outputPath;
        _status = 'Recording (live) to ${outputPath.split(Platform.pathSeparator).last}…';
      });
    } catch (e) {
      setState(() {
        _status = 'Error starting recording: $e';
      });
    }
  }

  Future<void> _stopRecording() async {
    try {
      final result = await ScreenRecorderPlatform.instance.stopLiveRecording();
      await _cursorSubscription?.cancel();
      _cursorSubscription = null;

      setState(() {
        _isRecording = false;
        _lastOutputPath = result.outputPath;
        _status = 'Stopped. Wrote ${result.outputPath} '
            '(${result.width}x${result.height}). '
            'Cursor samples: $_cursorSampleCount.';
      });
    } catch (e) {
      setState(() {
        _status = 'Error stopping recording: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Screen Recorder macOS Example'),
        ),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('Status: $_status'),
              const SizedBox(height: 20),
              if (_isRecording) ...[
                Text('Cursor samples received: $_cursorSampleCount'),
                const SizedBox(height: 10),
                if (_lastCursorPosition != null)
                  Text(
                      'Last cursor position: (${_lastCursorPosition!.x.toStringAsFixed(1)}, ${_lastCursorPosition!.y.toStringAsFixed(1)})${_lastCursorPosition!.isClicked ? " CLICKED" : ""}'),
              ],
              if (_lastOutputPath != null && !_isRecording) ...[
                const SizedBox(height: 10),
                Text('Last output: $_lastOutputPath'),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isRecording ? null : _startRecording,
                child: const Text('Start Live Recording'),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: _isRecording ? _stopRecording : null,
                child: const Text('Stop Recording'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
