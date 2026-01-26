import 'package:flutter/material.dart';
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:screen_recorder_macos/screen_recorder_macos.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

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
  int _audioSampleCount = 0;
  StreamSubscription<AudioData>? _audioSubscription;
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
    _audioSubscription?.cancel();
    _cursorSubscription?.cancel();
    super.dispose();
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

  Future<void> _startRecording() async {
    try {
      // Subscribe to audio stream
      _audioSubscription = ScreenRecorderPlatform.instance.audioStream.listen(
        (audioData) {
          setState(() {
            _audioSampleCount++;
          });
          if (_audioSampleCount % 10 == 0) {
            print('Audio sample #$_audioSampleCount: ${audioData.sampleRate}Hz, ${audioData.channels}ch, ${audioData.data.length} bytes');
          }
        },
        onError: (error) {
          print('Audio stream error: $error');
        },
      );

      // Subscribe to cursor stream
      _cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
        (cursorData) {
          setState(() {
            _cursorSampleCount++;
            _lastCursorPosition = cursorData;
          });

          if (_cursorSampleCount % 60 == 0) {
            print('Cursor sample #$_cursorSampleCount: ${cursorData.x}, ${cursorData.y}, clicked: ${cursorData.isClicked}');
          }
        },
        onError: (error) {
          print('Cursor stream error: $error');
        },
      );

      // Start recording with audio
      await ScreenRecorderPlatform.instance.startRecording(
        const RecordingSettings(
          source: RecordingSource.screen,
          frameRate: 30,
          captureAudio: true,
        ),
      );

      setState(() {
        _isRecording = true;
        _audioSampleCount = 0;
        _cursorSampleCount = 0;
        _status = 'Recording with audio and cursor...';
      });
    } catch (e) {
      setState(() {
        _status = 'Error starting recording: $e';
      });
    }
  }

  Future<void> _stopRecording() async {
    try {
      await ScreenRecorderPlatform.instance.stopRecording();
      await _audioSubscription?.cancel();
      _audioSubscription = null;
      await _cursorSubscription?.cancel();
      _cursorSubscription = null;

      setState(() {
        _isRecording = false;
        _status = 'Recording stopped. Received $_audioSampleCount audio samples and $_cursorSampleCount cursor samples.';
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
                Text('Audio samples received: $_audioSampleCount'),
                const SizedBox(height: 10),
                Text('Cursor samples received: $_cursorSampleCount'),
                const SizedBox(height: 10),
                if (_lastCursorPosition != null)
                  Text('Last cursor position: (${_lastCursorPosition!.x.toStringAsFixed(1)}, ${_lastCursorPosition!.y.toStringAsFixed(1)})${_lastCursorPosition!.isClicked ? " CLICKED" : ""}'),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isRecording ? null : _startRecording,
                child: const Text('Start Recording with Audio'),
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
