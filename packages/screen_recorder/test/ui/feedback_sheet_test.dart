import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/feedback/feedback_service.dart';
import 'package:screen_recorder/ui/feedback/feedback_sheet.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

class _FakeFeedback implements FeedbackService {
  FeedbackReport? submitted;
  int submitCount = 0;
  @override
  Future<void> submit(FeedbackReport report) async {
    submitted = report;
    submitCount++;
  }
  @override
  Future<void> load() async {}
  @override
  Future<void> dispose() async {}
  @override
  void setDistinctId(String id) {}
  @override
  Future<void> flush() async {}
}

void main() {
  testWidgets('submitting sends type + message through the service', (tester) async {
    final fake = _FakeFeedback();
    await tester.pumpWidget(ProviderScope(
      overrides: [feedbackServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
        theme: ThemeData(extensions: const [AppPalette.midnight]),
        home: Builder(builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => FeedbackSheet.show(context),
            child: const Text('open'),
          ),
        )),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'it crashed');
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(fake.submitted, isNotNull);
    expect(fake.submitted!.message, 'it crashed');
    // Drain AppAlerts' success auto-dismiss timer (4s; no overlay is
    // attached in this host) — same pattern as paywall_sheet_test.dart.
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a rapid double-tap on Send submits only once', (tester) async {
    final fake = _FakeFeedback();
    await tester.pumpWidget(ProviderScope(
      overrides: [feedbackServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
        theme: ThemeData(extensions: const [AppPalette.midnight]),
        home: Builder(builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () => FeedbackSheet.show(context),
            child: const Text('open'),
          ),
        )),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'once please');
    // Two taps within the same frame (before the sheet pops) — the _busy guard
    // must swallow the second.
    await tester.tap(find.text('Send'));
    await tester.tap(find.text('Send'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(fake.submitCount, 1);
    await tester.pump(const Duration(seconds: 5));
  });
}
