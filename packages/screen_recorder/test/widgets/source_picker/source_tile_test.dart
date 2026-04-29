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
}
