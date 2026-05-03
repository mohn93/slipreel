import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_settings.dart';

void main() {
  group('ExportSettings', () {
    test('defaults are MP4 / 1080p / Web / 30fps / File / no title / not private', () {
      final s = ExportSettings.defaults();
      expect(s.format, ExportFormat.mp4);
      expect(s.resolution, ExportResolution.r1080p);
      expect(s.compression, CompressionTier.web);
      expect(s.frameRate, 30);
      expect(s.destination, ExportDestination.file);
      expect(s.title, isNull);
      expect(s.isPrivate, isFalse);
    });

    test('round-trips through JSON with non-default values', () {
      final s = ExportSettings(
        format: ExportFormat.gif,
        resolution: ExportResolution.r720p,
        compression: CompressionTier.studio,
        frameRate: 60,
        destination: ExportDestination.shareableLink,
        title: 'My Video',
        isPrivate: true,
      );
      final json = s.toJson();
      final restored = ExportSettings.fromJson(json);
      expect(restored.format, ExportFormat.gif);
      expect(restored.resolution, ExportResolution.r720p);
      expect(restored.compression, CompressionTier.studio);
      expect(restored.frameRate, 60);
      expect(restored.destination, ExportDestination.shareableLink);
      expect(restored.title, 'My Video');
      expect(restored.isPrivate, isTrue);
    });

    test('round-trips through JSON with all enum values', () {
      for (final format in ExportFormat.values) {
        for (final resolution in ExportResolution.values) {
          for (final compression in CompressionTier.values) {
            for (final destination in ExportDestination.values) {
              final s = ExportSettings(
                format: format,
                resolution: resolution,
                compression: compression,
                frameRate: 30,
                destination: destination,
              );
              final json = s.toJson();
              final restored = ExportSettings.fromJson(json);
              expect(restored.format, format);
              expect(restored.resolution, resolution);
              expect(restored.compression, compression);
              expect(restored.destination, destination);
            }
          }
        }
      }
    });

    test('fromJson throws FormatException on unknown format enum value', () {
      final json = {
        'format': 'avi',
        'resolution': 'r1080p',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'file',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on unknown resolution enum value', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r2160p',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'file',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on unknown compression enum value', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'compression': 'ultraHigh',
        'frameRate': 30,
        'destination': 'file',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on unknown destination enum value', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'dropbox',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on missing required field (format)', () {
      final json = {
        'resolution': 'r1080p',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'file',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on missing required field (resolution)', () {
      final json = {
        'format': 'mp4',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'file',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on missing required field (compression)', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'frameRate': 30,
        'destination': 'file',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on missing required field (frameRate)', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'compression': 'web',
        'destination': 'file',
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson throws FormatException on missing required field (destination)', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'compression': 'web',
        'frameRate': 30,
      };
      expect(
        () => ExportSettings.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });

    test('fromJson defaults optional fields (title=null, isPrivate=false)', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'file',
      };
      final restored = ExportSettings.fromJson(json);
      expect(restored.title, isNull);
      expect(restored.isPrivate, isFalse);
    });

    test('fromJson parses optional title', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'file',
        'title': 'Test Video',
      };
      final restored = ExportSettings.fromJson(json);
      expect(restored.title, 'Test Video');
    });

    test('fromJson parses optional isPrivate', () {
      final json = {
        'format': 'mp4',
        'resolution': 'r1080p',
        'compression': 'web',
        'frameRate': 30,
        'destination': 'file',
        'isPrivate': true,
      };
      final restored = ExportSettings.fromJson(json);
      expect(restored.isPrivate, isTrue);
    });

    test('copyWith with no args returns equal value', () {
      final s = ExportSettings.defaults();
      final s2 = s.copyWith();
      expect(s2, s);
    });

    test('copyWith with clearTitle: true clears title', () {
      final s = ExportSettings(
        format: ExportFormat.mp4,
        resolution: ExportResolution.r1080p,
        compression: CompressionTier.web,
        frameRate: 30,
        destination: ExportDestination.file,
        title: 'My Video',
      );
      final s2 = s.copyWith(clearTitle: true);
      expect(s2.title, isNull);
      expect(s2.format, s.format);
      expect(s2.resolution, s.resolution);
    });

    test('copyWith without clearTitle leaves title intact', () {
      final s = ExportSettings(
        format: ExportFormat.mp4,
        resolution: ExportResolution.r1080p,
        compression: CompressionTier.web,
        frameRate: 30,
        destination: ExportDestination.file,
        title: 'My Video',
      );
      final s2 = s.copyWith(format: ExportFormat.gif);
      expect(s2.title, 'My Video');
      expect(s2.format, ExportFormat.gif);
    });

    test('copyWith updating one field leaves others intact', () {
      final s = ExportSettings.defaults();
      final s2 = s.copyWith(frameRate: 60);
      expect(s2.frameRate, 60);
      expect(s2.format, s.format);
      expect(s2.resolution, s.resolution);
      expect(s2.compression, s.compression);
      expect(s2.destination, s.destination);
      expect(s2.title, s.title);
      expect(s2.isPrivate, s.isPrivate);
    });

    test('copyWith can update multiple fields', () {
      final s = ExportSettings.defaults();
      final s2 = s.copyWith(
        frameRate: 60,
        resolution: ExportResolution.r720p,
        isPrivate: true,
      );
      expect(s2.frameRate, 60);
      expect(s2.resolution, ExportResolution.r720p);
      expect(s2.isPrivate, isTrue);
      expect(s2.format, s.format);
      expect(s2.compression, s.compression);
      expect(s2.destination, s.destination);
    });

    test('equality is based on all fields', () {
      final s1 = ExportSettings.defaults();
      final s2 = ExportSettings.defaults();
      expect(s1, s2);

      final s3 = s1.copyWith(frameRate: 60);
      expect(s3 != s1, isTrue);

      final s4 = s1.copyWith(title: 'Test');
      expect(s4 != s1, isTrue);

      final s5 = s1.copyWith(isPrivate: true);
      expect(s5 != s1, isTrue);
    });
  });

  group('ExportResolution.dimensionsFor', () {
    test('produces 1920x1080 from 2560x1440 + r1080p', () {
      final size = ExportResolution.r1080p.dimensionsFor(const Size(2560, 1440));
      expect(size.width, 1920);
      expect(size.height, 1080);
      expect(size.width % 2, 0); // width must be even
      expect(size.height % 2, 0); // height must be even
    });

    test('produces 1428x1080 from 1428x1080 + r1080p', () {
      final size = ExportResolution.r1080p.dimensionsFor(const Size(1428, 1080));
      expect(size.width, 1428);
      expect(size.height, 1080);
      expect(size.width % 2, 0);
      expect(size.height % 2, 0);
    });

    test('width is always even (even from odd source dimensions)', () {
      // 1500x800 source at 1080p
      final size = ExportResolution.r1080p.dimensionsFor(const Size(1500, 800));
      expect(size.height, 1080);
      expect(size.width % 2, 0);
    });

    test('height is 720 for r720p', () {
      final size = ExportResolution.r720p.dimensionsFor(const Size(2560, 1440));
      expect(size.height, 720);
      expect(size.width % 2, 0);
      expect(size.height % 2, 0);
    });

    test('height is 1080 for r1080p', () {
      final size = ExportResolution.r1080p.dimensionsFor(const Size(2560, 1440));
      expect(size.height, 1080);
    });

    test('height is 2160 for r4k', () {
      final size = ExportResolution.r4k.dimensionsFor(const Size(4096, 2160));
      expect(size.height, 2160);
      expect(size.width % 2, 0);
      expect(size.height % 2, 0);
    });

    test('maintains aspect ratio (1.5:1)', () {
      // source is 1500x1000
      final size = ExportResolution.r1080p.dimensionsFor(const Size(1500, 1000));
      // expected: height = 1080, width = 1080 * 1500/1000 = 1620
      expect(size.height, 1080);
      expect(size.width, 1620);
      expect(size.width % 2, 0);
    });

    test('maintains aspect ratio (16:9)', () {
      // source is 1920x1080
      final size = ExportResolution.r1080p.dimensionsFor(const Size(1920, 1080));
      expect(size.height, 1080);
      expect(size.width, 1920);
      expect(size.width % 2, 0);
    });

    test('maintains aspect ratio (9:16)', () {
      // source is 1080x1920 (portrait)
      final size = ExportResolution.r720p.dimensionsFor(const Size(1080, 1920));
      expect(size.height, 720);
      // width = 720 * 1080 / 1920 = 405
      expect(size.width, 406); // rounded up and bumped to even
      expect(size.width % 2, 0);
    });
  });
}
