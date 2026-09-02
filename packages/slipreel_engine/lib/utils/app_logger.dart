import 'package:logger/logger.dart';

import 'breadcrumbs.dart';

/// Log zones for different parts of the application
enum LogZone {
  platform('Platform'),
  videoEncoder('VideoEncoder'),
  audioEncoder('AudioEncoder'),
  recording('Recording'),
  ui('UI'),
  isolate('Isolate'),
  ffmpeg('FFmpeg'),
  permissions('Permissions');

  final String name;
  const LogZone(this.name);
}

/// Custom log output that includes zone information
class ZoneLogOutput extends LogOutput {
  @override
  void output(OutputEvent event) {
    for (var line in event.lines) {
      // ignore: avoid_print
      print(line);
    }
  }
}

/// Custom log printer that formats messages with zone and timestamp
class ZoneLogPrinter extends PrettyPrinter {
  final LogZone zone;

  ZoneLogPrinter(this.zone)
      : super(
          methodCount: 0,
          errorMethodCount: 5,
          lineLength: 80,
          colors: true,
          printEmojis: true,
          dateTimeFormat: DateTimeFormat.onlyTimeAndSinceStart,
        );

  @override
  List<String> log(LogEvent event) {
    // nit: some levels (verbose/wtf and any future level) have no entry in
    // defaultLevelColors; fall back to a no-op color so logging them never
    // throws on a null force-unwrap.
    final color =
        PrettyPrinter.defaultLevelColors[event.level] ?? AnsiColor.none();
    final emoji = PrettyPrinter.defaultLevelEmojis[event.level];
    final message = event.message;

    // Format: [TIME] EMOJI [ZONE] LEVEL: MESSAGE
    final time = getTime(event.time);
    final zoneName = '[${zone.name}]'.padRight(18);
    final levelName = event.level.name.toUpperCase().padRight(7);

    final output = '$time $emoji $zoneName $levelName $message';

    final lines = <String>[color(output)];

    if (event.error != null) {
      lines.add(color('Error: ${event.error}'));
    }

    if (event.stackTrace != null) {
      final stackStr = event.stackTrace.toString();
      final stackLines = stackStr.split('\n').take(errorMethodCount ?? 5);
      lines.addAll(stackLines.map((line) => color(line)));
    }

    return lines;
  }
}

/// Application logger with zone-based logging
class AppLogger {
  static final Map<LogZone, Logger> _loggers = {};
  static bool _initialized = false;

  /// Initialize the logging system
  static void initialize({Level level = Level.debug}) {
    if (_initialized) return;

    // Create loggers for each zone
    for (final zone in LogZone.values) {
      _loggers[zone] = Logger(
        printer: ZoneLogPrinter(zone),
        output: MultiOutput([ZoneLogOutput(), BreadcrumbLogOutput(zone.name)]),
        level: level,
      );
    }

    _initialized = true;
  }

  /// Get logger for a specific zone
  static Logger zone(LogZone zone) {
    if (!_initialized) {
      initialize();
    }
    return _loggers[zone]!;
  }

  /// Convenience getters for common zones
  static Logger get platform => zone(LogZone.platform);
  static Logger get videoEncoder => zone(LogZone.videoEncoder);
  static Logger get audioEncoder => zone(LogZone.audioEncoder);
  static Logger get recording => zone(LogZone.recording);
  static Logger get ui => zone(LogZone.ui);
  static Logger get isolate => zone(LogZone.isolate);
  static Logger get ffmpeg => zone(LogZone.ffmpeg);
  static Logger get permissions => zone(LogZone.permissions);
}
