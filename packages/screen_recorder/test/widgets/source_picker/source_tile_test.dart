import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/source_tile.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 240, height: 200, child: child)),
      );

  testWidgets('renders title and subtitle', (tester) async {
    await tester.pumpWidget(wrap(SourceTile(
      title: 'Document.pdf',
      subtitle: 'Preview',
      thumbnail: null,
      isSelected: false,
      isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    expect(find.text('Document.pdf'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
  });

  testWidgets('shows fallback icon when thumbnail is null', (tester) async {
    await tester.pumpWidget(wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: false, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.window), findsOneWidget);
  });

  testWidgets('shows fallback icon when isErrored', (tester) async {
    await tester.pumpWidget(wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: false, isErrored: true,
      fallbackIcon: Icons.desktop_windows,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.desktop_windows), findsOneWidget);
  });

  testWidgets('selected state shows purple border', (tester) async {
    await tester.pumpWidget(wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: true, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    final container = tester.widget<Container>(
        find.byKey(const ValueKey('source-tile-outer')));
    final decoration = container.decoration as BoxDecoration;
    final border = decoration.border as Border;
    expect(border.top.color, const Color(0xFF6C63FF));
    expect(border.top.width, 2);
  });

  testWidgets('tap fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: false, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(SourceTile));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('renders Image.memory when thumbnail bytes present', (tester) async {
    // Minimal 1x1 transparent PNG
    final bytes = Uint8List.fromList([
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0,
      1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65,
      84, 120, 156, 98, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73,
      69, 78, 68, 174, 66, 96, 130,
    ]);
    await tester.pumpWidget(wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: bytes, isSelected: false, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.window), findsNothing);
  });
}
