# Error Tracking + In-App Feedback (v1a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Dart-level error tracking and an in-app feedback form to the desktop app, both delivered to PostHog through the existing `/batch/` pipeline, gated by a new opt-out "diagnostics" consent.

**Architecture:** Extract the transport half of `AnalyticsService` into a reusable, policy-free `PostHogSink`. Run three thin consumers over it — `AnalyticsService` (unchanged behavior), a new `DiagnosticsService` (`$exception` events, gated by `shareDiagnostics`), and a new always-on `FeedbackService` (`feedback_submitted`). Global error handlers and a Settings feedback form feed those services; a ring buffer of recent logs and a PII scrubber keep reports debuggable but private.

**Tech Stack:** Dart / Flutter (macOS desktop), Riverpod (StateNotifier + Provider), `http`, `logger`, `package_info_plus`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-02-error-tracking-feedback-design.md` (this plan implements the **v1a** slice; native crash forwarding is v1b, a separate plan).

## Global Constraints

- **Analytics must never break or block the app.** Every new send path is best-effort: failures are logged via `AppLogger` and swallowed, never thrown. (Existing analytics doctrine.)
- **No new identifiers.** Diagnostics and feedback reuse the same `distinct_id` as analytics (device fingerprint, or the entitlement `sub` after identify).
- **Send nothing unless configured.** A real project key (`phc_…`, baked via `--dart-define=SLIPREEL_POSTHOG_KEY`) gates all delivery; unconfigured dev/test builds no-op.
- **PII scrubbing is mandatory** on every string that leaves the machine: the user's home dir → `~`, message/breadcrumb length caps, list-size caps. Never send file names, window titles, or recording content.
- **Consent:** diagnostics gated by `GlobalPreferences.shareDiagnostics` (default `true`, absent→`true`). Feedback is gated only by the act of submitting.
- **Copy/tone:** user-facing strings match the existing careful, no-emoji Settings tone.
- **PostHog host/key:** `AnalyticsConfig.hostResolved` and `AnalyticsConfig.projectKey` — reuse, do not duplicate.
- **Event names:** exceptions use the literal `$exception`; feedback uses `feedback_submitted`.

---

## File Structure

New:
- `lib/analytics/posthog_sink.dart` — extracted transport (queue → disk → `/batch/` → retry).
- `lib/diagnostics/pii_scrubber.dart` — pure string scrubbing.
- `lib/diagnostics/breadcrumbs.dart` — bounded ring buffer + `BreadcrumbLogOutput`.
- `lib/diagnostics/exception_event_builder.dart` — pure `$exception` event construction.
- `lib/diagnostics/diagnostics_service.dart` — gated exception capture + provider.
- `lib/diagnostics/global_error_handlers.dart` — `installGlobalErrorHandlers`.
- `lib/feedback/feedback_service.dart` — `FeedbackReport`, `FeedbackType`, `FeedbackService` + provider.
- `lib/ui/feedback/feedback_sheet.dart` — the feedback form.

Modified:
- `lib/analytics/analytics_service.dart` — delegate transport to `PostHogSink` (API unchanged).
- `lib/analytics/analytics_event.dart` — add `typedef PostHogEvent = AnalyticsEvent;`.
- `lib/state/global_preferences_store.dart` + `lib/state/global_preferences_controller.dart` — add `shareDiagnostics`.
- `packages/slipreel_engine/lib/utils/app_logger.dart` — add breadcrumb output.
- `lib/ui/screens/settings_screen.dart` — second privacy toggle + "Send feedback" row.
- `lib/ui/screens/playback_screen.dart` — one manual `captureException` at the export-failure arm.
- `lib/main.dart` — build/wire services, install handlers, `runZonedGuarded`, observers.

**Test commands** run from `packages/screen_recorder/`:
```bash
cd packages/screen_recorder && flutter test test/<path>
```
Full package suite (regression guard): `cd packages/screen_recorder && flutter test`.

---

### Task 1: Extract `PostHogSink` (behavior-preserving refactor)

Split the transport out of `AnalyticsService`. This is the refactor guard: the existing analytics tests must still pass unchanged.

**Files:**
- Create: `lib/analytics/posthog_sink.dart`
- Modify: `lib/analytics/analytics_event.dart` (add typedef)
- Modify: `lib/analytics/analytics_service.dart`
- Test: `test/analytics/posthog_sink_test.dart`
- Regression: `test/analytics/analytics_service_test.dart` (must stay green, unchanged)

**Interfaces:**
- Produces:
  - `typedef PostHogEvent = AnalyticsEvent;`
  - ```dart
    class PostHogSink {
      PostHogSink({
        required AnalyticsQueueStore store,
        required String distinctId,
        required String projectKey,
        required String host,
        http.Client? client,
        Duration flushDebounce = const Duration(seconds: 5),
        DateTime Function() now = DateTime.now,
      });
      bool get isConfigured;        // projectKey.startsWith('phc_')
      int get pendingCount;         // for tests
      Future<void> load();          // hydrate queue from store
      void enqueue(PostHogEvent event); // no-op if !isConfigured
      Future<void> flush();         // POST /batch/, retry-safe; no-op if !isConfigured or empty
      void setDistinctId(String id);
      Future<void> clear();         // drop memory + disk queue
      Future<void> dispose();       // final flush + close client
    }
    ```
- `AnalyticsService`'s public API is unchanged (`capture`, `identify`, `setEnabled`, `enabled`, `load`, `flush`, `dispose`, `analyticsServiceProvider`, `captureAnalytics` extension).

- [ ] **Step 1: Add the typedef.** In `lib/analytics/analytics_event.dart`, above the class, add:

```dart
/// A generic PostHog event. `AnalyticsEvent` predates the split into product
/// analytics vs diagnostics vs feedback; all three now share this shape.
typedef PostHogEvent = AnalyticsEvent;
```

- [ ] **Step 2: Write the failing sink test.** Create `test/analytics/posthog_sink_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';
import 'package:path/path.dart' as p;
import 'dart:io';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sink'));
  tearDown(() => dir.deleteSync(recursive: true));

  AnalyticsQueueStore store() =>
      AnalyticsQueueStore(path: p.join(dir.path, 'q.json'));

  test('no-ops entirely when unconfigured (no phc_ key)', () async {
    var calls = 0;
    final sink = PostHogSink(
      store: store(),
      distinctId: 'd1',
      projectKey: '',
      host: 'https://example.test',
      client: MockClient((_) async { calls++; return http.Response('', 200); }),
    );
    sink.enqueue(PostHogEvent(name: 'x', timestamp: DateTime.now()));
    await sink.flush();
    expect(sink.isConfigured, isFalse);
    expect(calls, 0);
  });

  test('posts queued events to /batch/ and clears on 2xx', () async {
    Map<String, dynamic>? body;
    final sink = PostHogSink(
      store: store(),
      distinctId: 'd1',
      projectKey: 'phc_test',
      host: 'https://example.test',
      flushDebounce: Duration.zero,
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{"status":1}', 200);
      }),
    );
    sink.enqueue(PostHogEvent(name: 'evt', timestamp: DateTime.now()));
    await sink.flush();
    expect(body!['api_key'], 'phc_test');
    expect((body!['batch'] as List).single['distinct_id'], 'd1');
    expect(sink.pendingCount, 0);
  });

  test('keeps queue on non-2xx for retry', () async {
    final sink = PostHogSink(
      store: store(),
      distinctId: 'd1',
      projectKey: 'phc_test',
      host: 'https://example.test',
      flushDebounce: Duration.zero,
      client: MockClient((_) async => http.Response('nope', 500)),
    );
    sink.enqueue(PostHogEvent(name: 'evt', timestamp: DateTime.now()));
    await sink.flush();
    expect(sink.pendingCount, 1);
  });

  test('setDistinctId changes the id used at send time', () async {
    Map<String, dynamic>? body;
    final sink = PostHogSink(
      store: store(),
      distinctId: 'anon',
      projectKey: 'phc_test',
      host: 'https://example.test',
      flushDebounce: Duration.zero,
      client: MockClient((req) async {
        body = jsonDecode(req.body) as Map<String, dynamic>;
        return http.Response('{}', 200);
      }),
    );
    sink.setDistinctId('user-123');
    sink.enqueue(PostHogEvent(name: 'evt', timestamp: DateTime.now()));
    await sink.flush();
    expect((body!['batch'] as List).single['distinct_id'], 'user-123');
  });
}
```

- [ ] **Step 3: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/analytics/posthog_sink_test.dart`
Expected: FAIL — `posthog_sink.dart` / `PostHogSink` not found.

- [ ] **Step 4: Implement `PostHogSink`.** Create `lib/analytics/posthog_sink.dart` by lifting the transport from `AnalyticsService` verbatim (queue list, disk mirror, debounce timer, `/batch/` POST, 2xx-removal, retry-on-failure). No gating on `enabled` here — that stays in consumers.

```dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slipreel_engine/utils/app_logger.dart';

import 'analytics_event.dart';
import 'analytics_queue_store.dart';

/// Policy-free PostHog `/batch/` transport: buffers events in memory, mirrors
/// them to a bounded on-disk queue, and delivers them best-effort. Gating
/// (opt-out, event category) is the caller's concern; this only refuses to
/// send when no real project key was baked in.
class PostHogSink {
  PostHogSink({
    required AnalyticsQueueStore store,
    required String distinctId,
    required String projectKey,
    required String host,
    http.Client? client,
    Duration flushDebounce = const Duration(seconds: 5),
    DateTime Function() now = DateTime.now,
  })  : _store = store,
        _distinctId = distinctId,
        _projectKey = projectKey,
        _host = host,
        _client = client ?? http.Client(),
        _flushDebounce = flushDebounce,
        _now = now;

  final AnalyticsQueueStore _store;
  String _distinctId;
  final String _projectKey;
  final String _host;
  final http.Client _client;
  final Duration _flushDebounce;
  final DateTime Function() _now;

  final List<PostHogEvent> _queue = [];
  bool _flushing = false;
  Timer? _flushTimer;

  bool get isConfigured => _projectKey.startsWith('phc_');
  int get pendingCount => _queue.length;

  Future<void> load() async {
    if (!isConfigured) return;
    _queue.addAll(await _store.load());
  }

  void setDistinctId(String id) => _distinctId = id;

  void enqueue(PostHogEvent event) {
    if (!isConfigured) return;
    _queue.add(event);
    unawaited(_store.save(_queue));
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(_flushDebounce, () => unawaited(flush()));
  }

  Future<void> flush() async {
    if (_flushing || !isConfigured || _queue.isEmpty) return;
    _flushing = true;
    _flushTimer?.cancel();
    final sent = List<PostHogEvent>.of(_queue);
    try {
      final res = await _client
          .post(
            Uri.parse('$_host/batch/'),
            headers: const {'content-type': 'application/json'},
            body: jsonEncode({
              'api_key': _projectKey,
              'historical_migration': false,
              'batch': sent.map((e) => e.toBatchItem(_distinctId)).toList(),
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final delivered = Set<PostHogEvent>.identity()..addAll(sent);
        _queue.removeWhere(delivered.contains);
        await _store.save(_queue);
      } else {
        AppLogger.platform.w('posthog sink: HTTP ${res.statusCode}; will retry');
      }
    } catch (e) {
      AppLogger.platform.d('posthog sink flush deferred: $e');
    } finally {
      _flushing = false;
      if (_queue.isNotEmpty) _scheduleFlush();
    }
  }

  Future<void> clear() async {
    _flushTimer?.cancel();
    _queue.clear();
    await _store.clear();
  }

  Future<void> dispose() async {
    _flushTimer?.cancel();
    await flush();
    _client.close();
  }
}
```

- [ ] **Step 5: Refactor `AnalyticsService` to delegate.** Replace its transport internals with a `PostHogSink`, keeping the constructor signature and every public method identical. `capture` builds the event with super-properties then `_sink.enqueue`; `identify` calls `_sink.setDistinctId(userId)` then enqueues the `$identify` event; `setEnabled(false)` calls `_sink.clear()`; `load`/`flush`/`dispose` delegate; the `enabled` + `_configured` guards stay in `AnalyticsService` (it still refuses to enqueue when disabled).

```dart
// Constructor body: build the sink from the same params.
_sink = PostHogSink(
  store: store,
  distinctId: distinctId,
  projectKey: projectKey,
  host: host ?? AnalyticsConfig.hostResolved,
  client: client,
  flushDebounce: flushDebounce,
  now: now,
);
// capture():
void capture(String event, {Map<String, Object?>? properties}) {
  if (!_enabled || !_sink.isConfigured) return;
  _sink.enqueue(PostHogEvent(
    name: event,
    timestamp: _now(),
    properties: {..._superProperties, ...?properties},
  ));
}
// identify(): after computing anonId/newId, _sink.setDistinctId(userId); _sink.enqueue($identify event)
// setEnabled(false): await _sink.clear();
// load()/flush()/dispose(): delegate to _sink.
```

- [ ] **Step 6: Run the new sink tests and the full analytics suite.**

Run: `cd packages/screen_recorder && flutter test test/analytics/`
Expected: PASS — new `posthog_sink_test.dart` green AND `analytics_service_test.dart` + `analytics_queue_store_test.dart` unchanged and green.

- [ ] **Step 7: Commit.**

```bash
git add packages/screen_recorder/lib/analytics/posthog_sink.dart \
        packages/screen_recorder/lib/analytics/analytics_event.dart \
        packages/screen_recorder/lib/analytics/analytics_service.dart \
        packages/screen_recorder/test/analytics/posthog_sink_test.dart
git commit -m "refactor: extract PostHogSink transport from AnalyticsService"
```

---

### Task 2: `PiiScrubber` (pure)

**Files:**
- Create: `lib/diagnostics/pii_scrubber.dart`
- Test: `test/diagnostics/pii_scrubber_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class PiiScrubber {
    PiiScrubber({required String homeDir, int maxStringLength = 500});
    factory PiiScrubber.forCurrentUser();     // uses Platform.environment['HOME']
    String scrub(String input);               // home dir -> '~', then truncate
    List<String> scrubAll(Iterable<String> inputs, {int maxItems = 40});
  }
  ```

- [ ] **Step 1: Write the failing test.** Create `test/diagnostics/pii_scrubber_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  final s = PiiScrubber(homeDir: '/Users/alice', maxStringLength: 20);

  test('replaces home dir with ~', () {
    expect(s.scrub('/Users/alice/Movies/clip.mp4'), '~/Movies/clip.mp4');
  });

  test('replaces every occurrence in a string', () {
    expect(s.scrub('a /Users/alice b /Users/alice c'), 'a ~ b ~ c');
  });

  test('truncates to maxStringLength after scrubbing', () {
    expect(s.scrub('x' * 100).length, 20);
  });

  test('scrubAll caps list size, keeping the most recent (last) items', () {
    final out = s.scrubAll(['a', 'b', 'c', 'd'], maxItems: 2);
    expect(out, ['c', 'd']);
  });

  test('no home dir leaves the string unchanged (below cap)', () {
    expect(s.scrub('nothing private here'), 'nothing private here');
  });
}
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/pii_scrubber_test.dart`
Expected: FAIL — `pii_scrubber.dart` not found.

- [ ] **Step 3: Implement.** Create `lib/diagnostics/pii_scrubber.dart`:

```dart
import 'dart:io';

/// Strips personally-identifying substrings from any text that leaves the
/// machine. macOS paths embed the account name (`/Users/<realname>/…`), so we
/// collapse the home dir to `~` and cap length to bound accidental leakage.
class PiiScrubber {
  PiiScrubber({required String homeDir, this.maxStringLength = 500})
      : _homeDir = homeDir;

  factory PiiScrubber.forCurrentUser() =>
      PiiScrubber(homeDir: Platform.environment['HOME'] ?? '');

  final String _homeDir;
  final int maxStringLength;

  String scrub(String input) {
    var out = input;
    if (_homeDir.isNotEmpty) out = out.replaceAll(_homeDir, '~');
    if (out.length > maxStringLength) out = out.substring(0, maxStringLength);
    return out;
  }

  List<String> scrubAll(Iterable<String> inputs, {int maxItems = 40}) {
    final list = inputs.toList();
    final tail = list.length > maxItems
        ? list.sublist(list.length - maxItems)
        : list;
    return tail.map(scrub).toList();
  }
}
```

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/pii_scrubber_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/diagnostics/pii_scrubber.dart \
        packages/screen_recorder/test/diagnostics/pii_scrubber_test.dart
git commit -m "feat: add PiiScrubber for diagnostics"
```

---

### Task 3: `Breadcrumbs` ring buffer + `BreadcrumbLogOutput`

**Files:**
- Create: `lib/diagnostics/breadcrumbs.dart`
- Modify: `packages/slipreel_engine/lib/utils/app_logger.dart`
- Test: `test/diagnostics/breadcrumbs_test.dart`

**Interfaces:**
- Produces:
  ```dart
  class Breadcrumbs {
    Breadcrumbs({int capacity = 40, int maxMessageLength = 200});
    static final Breadcrumbs instance = Breadcrumbs();
    void add({required String zone, required String level, required String message, DateTime? time});
    List<String> snapshot();   // oldest-first, formatted "[zone] LEVEL message"
    void clear();              // for tests
  }
  class BreadcrumbLogOutput extends LogOutput { BreadcrumbLogOutput(String zoneName); }
  ```

- [ ] **Step 1: Write the failing test.** Create `test/diagnostics/breadcrumbs_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/breadcrumbs.dart';

void main() {
  test('keeps only the most recent `capacity` entries, oldest-first', () {
    final b = Breadcrumbs(capacity: 3);
    for (var i = 1; i <= 5; i++) {
      b.add(zone: 'UI', level: 'INFO', message: 'm$i');
    }
    final snap = b.snapshot();
    expect(snap.length, 3);
    expect(snap.first, contains('m3'));
    expect(snap.last, contains('m5'));
    expect(snap.last, contains('[UI]'));
  });

  test('truncates long messages at insert time', () {
    final b = Breadcrumbs(capacity: 2, maxMessageLength: 5);
    b.add(zone: 'UI', level: 'INFO', message: 'abcdefghij');
    expect(b.snapshot().single, contains('abcde'));
    expect(b.snapshot().single, isNot(contains('fghij')));
  });
}
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/breadcrumbs_test.dart`
Expected: FAIL — `breadcrumbs.dart` not found.

- [ ] **Step 3: Implement `Breadcrumbs` + output.** Create `lib/diagnostics/breadcrumbs.dart`:

```dart
import 'dart:collection';

import 'package:logger/logger.dart';

/// A small in-memory ring buffer of recent log lines, attached to exception and
/// feedback reports for context. Bounded so it can't grow; messages are capped
/// at insert. Not scrubbed here — the PiiScrubber runs at attach time.
class Breadcrumbs {
  Breadcrumbs({this.capacity = 40, this.maxMessageLength = 200});

  static final Breadcrumbs instance = Breadcrumbs();

  final int capacity;
  final int maxMessageLength;
  final Queue<String> _entries = Queue<String>();

  void add({
    required String zone,
    required String level,
    required String message,
    DateTime? time,
  }) {
    final msg = message.length > maxMessageLength
        ? message.substring(0, maxMessageLength)
        : message;
    _entries.addLast('[$zone] $level $msg');
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  List<String> snapshot() => _entries.toList(growable: false);

  void clear() => _entries.clear();
}

/// A `logger` output that mirrors each line into [Breadcrumbs.instance]. Added
/// alongside the console output so app logging is otherwise unchanged.
class BreadcrumbLogOutput extends LogOutput {
  BreadcrumbLogOutput(this.zoneName);
  final String zoneName;

  @override
  void output(OutputEvent event) {
    Breadcrumbs.instance.add(
      zone: zoneName,
      level: event.origin.level.name.toUpperCase(),
      message: event.origin.message.toString(),
      time: event.origin.time,
    );
  }
}
```

- [ ] **Step 4: Wire it into `AppLogger.initialize`.** In `packages/slipreel_engine/lib/utils/app_logger.dart`, change the per-zone `output:` to a `MultiOutput`. Add the import and update the loop:

```dart
import 'package:screen_recorder/diagnostics/breadcrumbs.dart'; // see note below
// ...
_loggers[zone] = Logger(
  printer: ZoneLogPrinter(zone),
  output: MultiOutput([ZoneLogOutput(), BreadcrumbLogOutput(zone.name)]),
  level: level,
);
```

Note: `slipreel_engine` must not depend on the app package. Move `breadcrumbs.dart` into `packages/slipreel_engine/lib/utils/breadcrumbs.dart` instead (engine-level, no app imports), and update the test import to `package:slipreel_engine/utils/breadcrumbs.dart`. Consumers in the app import it from there. Adjust the Task 3 file paths accordingly:
- Create: `packages/slipreel_engine/lib/utils/breadcrumbs.dart`
- Test: `packages/slipreel_engine/test/utils/breadcrumbs_test.dart`
- Run: `cd packages/slipreel_engine && flutter test test/utils/breadcrumbs_test.dart`

- [ ] **Step 5: Run the breadcrumbs test and the engine suite.**

Run: `cd packages/slipreel_engine && flutter test test/utils/breadcrumbs_test.dart`
Then: `cd packages/slipreel_engine && flutter test` (confirm AppLogger change didn't break the engine suite).
Expected: PASS.

- [ ] **Step 6: Commit.**

```bash
git add packages/slipreel_engine/lib/utils/breadcrumbs.dart \
        packages/slipreel_engine/lib/utils/app_logger.dart \
        packages/slipreel_engine/test/utils/breadcrumbs_test.dart
git commit -m "feat: add breadcrumb ring buffer fed by AppLogger"
```

---

### Task 4: `ExceptionEventBuilder` (pure)

**Files:**
- Create: `lib/diagnostics/exception_event_builder.dart`
- Test: `test/diagnostics/exception_event_builder_test.dart`

**Interfaces:**
- Consumes: `PostHogEvent` (Task 1), `PiiScrubber` (Task 2).
- Produces:
  ```dart
  class ExceptionEventBuilder {
    ExceptionEventBuilder({required PiiScrubber scrubber, required Map<String, Object?> meta});
    PostHogEvent fromDart(Object error, StackTrace? stack, {
      required bool handled,
      List<String> breadcrumbs = const [],
      Map<String, Object?>? context,
      DateTime? now,
    });
    String fingerprintFor(Object error, StackTrace? stack); // exposed for tests + dedupe
  }
  ```

- [ ] **Step 1: Write the failing test.** Create `test/diagnostics/exception_event_builder_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/analytics/analytics_event.dart';
import 'package:screen_recorder/diagnostics/exception_event_builder.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  final builder = ExceptionEventBuilder(
    scrubber: PiiScrubber(homeDir: '/Users/alice'),
    meta: {'source': 'app', 'platform': 'macos', 'app_version': '1.0.0+1'},
  );

  test('builds a \$exception event with the PostHog list shape', () {
    final e = builder.fromDart(
      RangeError('index /Users/alice/x out of range'),
      StackTrace.current,
      handled: false,
      breadcrumbs: ['[UI] INFO opened'],
    );
    expect(e.name, r'$exception');
    final list = e.properties[r'$exception_list'] as List;
    final item = list.single as Map<String, Object?>;
    expect(item['type'], 'RangeError');
    expect((item['mechanism'] as Map)['handled'], false);
    expect((item['mechanism'] as Map)['type'], 'flutter');
    expect(item['stacktrace'], isNotNull);
  });

  test('scrubs the home dir out of the exception message', () {
    final e = builder.fromDart(
      StateError('/Users/alice/secret.mov failed'), null, handled: true);
    final item = (e.properties[r'$exception_list'] as List).single as Map;
    expect(item['value'], isNot(contains('/Users/alice')));
    expect(item['value'], contains('~'));
  });

  test('attaches meta and breadcrumbs and a fingerprint', () {
    final e = builder.fromDart(ArgumentError('bad'), null, handled: true,
        breadcrumbs: ['[UI] INFO a']);
    expect(e.properties['source'], 'app');
    expect(e.properties['app_version'], '1.0.0+1');
    expect(e.properties['breadcrumbs'], ['[UI] INFO a']);
    expect(e.properties[r'$exception_fingerprint'], isNotEmpty);
  });

  test('fingerprint is stable for the same error type + top frame', () {
    final st = StackTrace.current;
    expect(builder.fingerprintFor(ArgumentError('x'), st),
        builder.fingerprintFor(ArgumentError('y'), st));
  });
}
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/exception_event_builder_test.dart`
Expected: FAIL — builder not found.

- [ ] **Step 3: Implement.** Create `lib/diagnostics/exception_event_builder.dart`:

```dart
import 'analytics/../analytics/analytics_event.dart' show PostHogEvent;
import 'pii_scrubber.dart';

/// Turns a Dart error + stack into a PostHog `$exception` event. Pure and
/// deterministic: scrubbing, frame parsing, and fingerprinting all happen here
/// so they can be unit-tested without any network or service.
class ExceptionEventBuilder {
  ExceptionEventBuilder({required this.scrubber, required this.meta});

  final PiiScrubber scrubber;
  final Map<String, Object?> meta;

  PostHogEvent fromDart(
    Object error,
    StackTrace? stack, {
    required bool handled,
    List<String> breadcrumbs = const [],
    Map<String, Object?>? context,
    DateTime? now,
  }) {
    final frames = _frames(stack);
    final item = <String, Object?>{
      'type': error.runtimeType.toString(),
      'value': scrubber.scrub(error.toString()),
      'mechanism': {'handled': handled, 'type': 'flutter'},
      'stacktrace': {'type': 'raw', 'frames': frames},
    };
    return PostHogEvent(
      name: r'$exception',
      timestamp: now ?? DateTime.now(),
      properties: {
        r'$exception_list': [item],
        r'$exception_fingerprint': fingerprintFor(error, stack),
        ...meta,
        'breadcrumbs': breadcrumbs,
        if (context != null && context.isNotEmpty) 'context': context,
      },
    );
  }

  String fingerprintFor(Object error, StackTrace? stack) {
    final top = _frames(stack).isNotEmpty
        ? (_frames(stack).first['function'] ?? _frames(stack).first['filename'])
        : 'no-frame';
    return '${error.runtimeType}|$top';
  }

  // Best-effort parse of `StackTrace.toString()` lines into frame maps. Frame
  // strings are scrubbed; we keep the raw function text rather than trying to
  // fully parse every Dart stack format.
  List<Map<String, Object?>> _frames(StackTrace? stack) {
    if (stack == null) return const [];
    final lines = stack.toString().trim().split('\n');
    return lines.take(30).map((line) {
      final scrubbed = scrubber.scrub(line.trim());
      return <String, Object?>{
        'function': scrubbed,
        'in_app': !scrubbed.contains('dart:') &&
            !scrubbed.contains('package:flutter/'),
      };
    }).toList();
  }
}
```

Note: fix the import to `import 'pii_scrubber.dart';` and `import '../analytics/analytics_event.dart' show PostHogEvent;` with the correct relative path from `lib/diagnostics/` (i.e. `../analytics/analytics_event.dart`). Correct the placeholder import line before running.

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/exception_event_builder_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/diagnostics/exception_event_builder.dart \
        packages/screen_recorder/test/diagnostics/exception_event_builder_test.dart
git commit -m "feat: add ExceptionEventBuilder for PostHog error tracking"
```

---

### Task 5: `shareDiagnostics` preference

**Files:**
- Modify: `lib/state/global_preferences_store.dart`
- Modify: `lib/state/global_preferences_controller.dart`
- Test: `test/state/global_preferences_diagnostics_test.dart`

**Interfaces:**
- Produces: `GlobalPreferences.shareDiagnostics` (bool, default true), `copyWith({bool? shareDiagnostics})`, JSON round-trip, `GlobalPreferencesController.setShareDiagnostics(bool)`.

- [ ] **Step 1: Write the failing test.** Create `test/state/global_preferences_diagnostics_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/global_preferences_store.dart';

void main() {
  test('defaults shareDiagnostics to true', () {
    expect(const GlobalPreferences().shareDiagnostics, isTrue);
  });

  test('absent in JSON means on (existing users keep default)', () {
    final p = GlobalPreferences.fromJson({'shareAnalytics': false});
    expect(p.shareDiagnostics, isTrue);
    expect(p.shareAnalytics, isFalse);
  });

  test('round-trips through JSON', () {
    final p = const GlobalPreferences().copyWith(shareDiagnostics: false);
    expect(GlobalPreferences.fromJson(p.toJson()).shareDiagnostics, isFalse);
  });
}
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/state/global_preferences_diagnostics_test.dart`
Expected: FAIL — `shareDiagnostics` getter missing.

- [ ] **Step 3: Implement.** In `lib/state/global_preferences_store.dart`: add the field (default `true`), constructor param, `copyWith` param + line, `toJson` entry, and `fromJson` parse mirroring `shareAnalytics`:

```dart
// constructor:
this.shareDiagnostics = true,
// field:
final bool shareDiagnostics;
// copyWith params + body:
bool? shareDiagnostics,
// ...
shareDiagnostics: shareDiagnostics ?? this.shareDiagnostics,
// toJson:
'shareDiagnostics': shareDiagnostics,
// fromJson:
final diagnostics = json['shareDiagnostics'];
// ...
shareDiagnostics: diagnostics is bool ? diagnostics : true,
```

In `lib/state/global_preferences_controller.dart`, add:

```dart
Future<void> setShareDiagnostics(bool value) async {
  if (state.shareDiagnostics == value) return;
  state = state.copyWith(shareDiagnostics: value);
  await store.save(state);
}
```

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/state/global_preferences_diagnostics_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/state/global_preferences_store.dart \
        packages/screen_recorder/lib/state/global_preferences_controller.dart \
        packages/screen_recorder/test/state/global_preferences_diagnostics_test.dart
git commit -m "feat: add shareDiagnostics opt-out preference"
```

---

### Task 6: `DiagnosticsService`

**Files:**
- Create: `lib/diagnostics/diagnostics_service.dart`
- Test: `test/diagnostics/diagnostics_service_test.dart`

**Interfaces:**
- Consumes: `PostHogSink` (Task 1), `ExceptionEventBuilder` (Task 4), `Breadcrumbs` (Task 3).
- Produces:
  ```dart
  class DiagnosticsService {
    DiagnosticsService({
      required PostHogSink sink,
      required ExceptionEventBuilder builder,
      required Breadcrumbs breadcrumbs,
      required PiiScrubber scrubber,
      required bool enabled,
      int maxPerSession = 50,
      Duration dedupeWindow = const Duration(seconds: 30),
      DateTime Function() now = DateTime.now,
    });
    bool get enabled;
    Future<void> load();
    void captureException(Object error, StackTrace? stack, {bool handled = true, Map<String, Object?>? context});
    void setDistinctId(String id);
    Future<void> setEnabled(bool value);   // clears queue on false
    Future<void> flush();
    Future<void> dispose();
  }
  final diagnosticsServiceProvider = Provider<DiagnosticsService>(...);
  ```

- [ ] **Step 1: Write the failing test.** Create `test/diagnostics/diagnostics_service_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';
import 'package:screen_recorder/diagnostics/breadcrumbs.dart';
import 'package:screen_recorder/diagnostics/diagnostics_service.dart';
import 'package:screen_recorder/diagnostics/exception_event_builder.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('diag'));
  tearDown(() => dir.deleteSync(recursive: true));

  DiagnosticsService build({required bool enabled, required MockClient client}) {
    final scrubber = PiiScrubber(homeDir: '/Users/alice');
    return DiagnosticsService(
      sink: PostHogSink(
        store: AnalyticsQueueStore(path: p.join(dir.path, 'd.json')),
        distinctId: 'd1',
        projectKey: 'phc_test',
        host: 'https://example.test',
        flushDebounce: Duration.zero,
        client: client,
      ),
      builder: ExceptionEventBuilder(scrubber: scrubber, meta: const {'source': 'app'}),
      breadcrumbs: Breadcrumbs(capacity: 5),
      scrubber: scrubber,
      enabled: enabled,
    );
  }

  test('does not send when disabled', () async {
    var calls = 0;
    final svc = build(enabled: false,
        client: MockClient((_) async { calls++; return http.Response('{}', 200); }));
    svc.captureException(StateError('x'), StackTrace.current);
    await svc.flush();
    expect(calls, 0);
  });

  test('sends a \$exception when enabled', () async {
    var calls = 0;
    final svc = build(enabled: true,
        client: MockClient((req) async {
          calls++;
          expect(req.body, contains(r'$exception'));
          return http.Response('{}', 200);
        }));
    svc.captureException(StateError('x'), StackTrace.current, handled: false);
    await svc.flush();
    expect(calls, 1);
  });

  test('collapses identical fingerprints within the dedupe window', () async {
    var batches = 0;
    final svc = build(enabled: true,
        client: MockClient((_) async { batches++; return http.Response('{}', 200); }));
    final st = StackTrace.current;
    svc.captureException(StateError('a'), st);
    svc.captureException(StateError('b'), st); // same type + top frame -> collapsed
    await svc.flush();
    expect(batches, 1); // one batch, and it should carry a single event
  });
}
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/diagnostics_service_test.dart`
Expected: FAIL — service not found.

- [ ] **Step 3: Implement.** Create `lib/diagnostics/diagnostics_service.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/posthog_sink.dart';
import 'breadcrumbs.dart';
import 'exception_event_builder.dart';
import 'pii_scrubber.dart';

/// Sends Dart exceptions to PostHog Error Tracking, gated by the user's
/// diagnostics opt-out. Best-effort like analytics: capture never throws.
class DiagnosticsService {
  DiagnosticsService({
    required PostHogSink sink,
    required ExceptionEventBuilder builder,
    required Breadcrumbs breadcrumbs,
    required PiiScrubber scrubber,
    required bool enabled,
    this.maxPerSession = 50,
    this.dedupeWindow = const Duration(seconds: 30),
    DateTime Function() now = DateTime.now,
  })  : _sink = sink,
        _builder = builder,
        _breadcrumbs = breadcrumbs,
        _scrubber = scrubber,
        _enabled = enabled,
        _now = now;

  final PostHogSink _sink;
  final ExceptionEventBuilder _builder;
  final Breadcrumbs _breadcrumbs;
  final PiiScrubber _scrubber;
  final int maxPerSession;
  final Duration dedupeWindow;
  final DateTime Function() _now;

  bool _enabled;
  int _sessionCount = 0;
  final Map<String, DateTime> _lastSeen = {};

  bool get enabled => _enabled;

  Future<void> load() async {
    if (_enabled) await _sink.load();
  }

  void captureException(Object error, StackTrace? stack,
      {bool handled = true, Map<String, Object?>? context}) {
    if (!_enabled || !_sink.isConfigured) return;
    if (_sessionCount >= maxPerSession) return;
    final fp = _builder.fingerprintFor(error, stack);
    final last = _lastSeen[fp];
    final t = _now();
    if (last != null && t.difference(last) < dedupeWindow) return;
    _lastSeen[fp] = t;
    _sessionCount++;
    final crumbs = _scrubber.scrubAll(_breadcrumbs.snapshot());
    _sink.enqueue(_builder.fromDart(error, stack,
        handled: handled, breadcrumbs: crumbs, context: context, now: t));
  }

  void setDistinctId(String id) => _sink.setDistinctId(id);

  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    _enabled = value;
    if (!value) await _sink.clear();
  }

  Future<void> flush() => _sink.flush();
  Future<void> dispose() => _sink.dispose();
}

final diagnosticsServiceProvider = Provider<DiagnosticsService>(
  (ref) => throw UnimplementedError('Override diagnosticsServiceProvider in main()'),
);
```

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/diagnostics_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/diagnostics/diagnostics_service.dart \
        packages/screen_recorder/test/diagnostics/diagnostics_service_test.dart
git commit -m "feat: add DiagnosticsService for gated exception capture"
```

---

### Task 7: `FeedbackService`

**Files:**
- Create: `lib/feedback/feedback_service.dart`
- Test: `test/feedback/feedback_service_test.dart`

**Interfaces:**
- Consumes: `PostHogSink` (Task 1), `Breadcrumbs` (Task 3), `PiiScrubber` (Task 2).
- Produces:
  ```dart
  enum FeedbackType { idea, problem }
  class FeedbackReport {
    const FeedbackReport({required this.type, required this.message, this.email, this.attachDiagnostics = false});
    final FeedbackType type; final String message; final String? email; final bool attachDiagnostics;
  }
  class FeedbackService {
    FeedbackService({required PostHogSink sink, required Breadcrumbs breadcrumbs, required PiiScrubber scrubber, required Map<String, Object?> meta, DateTime Function() now = DateTime.now});
    Future<void> submit(FeedbackReport report);
    Future<void> load();
    Future<void> dispose();
  }
  final feedbackServiceProvider = Provider<FeedbackService>(...);
  ```

- [ ] **Step 1: Write the failing test.** Create `test/feedback/feedback_service_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/analytics/analytics_queue_store.dart';
import 'package:screen_recorder/analytics/posthog_sink.dart';
import 'package:screen_recorder/diagnostics/breadcrumbs.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';
import 'package:screen_recorder/feedback/feedback_service.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('fb'));
  tearDown(() => dir.deleteSync(recursive: true));

  FeedbackService build(MockClient client) => FeedbackService(
        sink: PostHogSink(
          store: AnalyticsQueueStore(path: p.join(dir.path, 'f.json')),
          distinctId: 'd1',
          projectKey: 'phc_test',
          host: 'https://example.test',
          flushDebounce: Duration.zero,
          client: client,
        ),
        breadcrumbs: Breadcrumbs(capacity: 5),
        scrubber: PiiScrubber(homeDir: '/Users/alice'),
        meta: const {'source': 'app', 'app_version': '1.0.0+1'},
      );

  test('submits a feedback_submitted event with type + message', () async {
    Map<String, dynamic>? item;
    final svc = build(MockClient((req) async {
      item = (jsonDecode(req.body)['batch'] as List).single as Map<String, dynamic>;
      return http.Response('{}', 200);
    }));
    await svc.submit(const FeedbackReport(type: FeedbackType.problem, message: 'broke'));
    expect(item!['event'], 'feedback_submitted');
    final props = item!['properties'] as Map<String, dynamic>;
    expect(props['type'], 'problem');
    expect(props['message'], 'broke');
    expect(props.containsKey('breadcrumbs'), isFalse); // not attached
  });

  test('attaches diagnostics only when requested', () async {
    Map<String, dynamic>? props;
    final svc = build(MockClient((req) async {
      final item = (jsonDecode(req.body)['batch'] as List).single as Map<String, dynamic>;
      props = item['properties'] as Map<String, dynamic>;
      return http.Response('{}', 200);
    }));
    await svc.submit(const FeedbackReport(
        type: FeedbackType.idea, message: 'nice', email: 'a@b.co', attachDiagnostics: true));
    expect(props!['email'], 'a@b.co');
    expect(props!.containsKey('breadcrumbs'), isTrue);
    expect(props!['app_version'], '1.0.0+1');
  });
}
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/feedback/feedback_service_test.dart`
Expected: FAIL — service not found.

- [ ] **Step 3: Implement.** Create `lib/feedback/feedback_service.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../analytics/analytics_event.dart';
import '../analytics/posthog_sink.dart';
import '../diagnostics/breadcrumbs.dart';
import '../diagnostics/pii_scrubber.dart';

enum FeedbackType { idea, problem }

class FeedbackReport {
  const FeedbackReport({
    required this.type,
    required this.message,
    this.email,
    this.attachDiagnostics = false,
  });
  final FeedbackType type;
  final String message;
  final String? email;
  final bool attachDiagnostics;
}

/// Sends user-initiated feedback. Always-on: submitting is the consent, so this
/// is not gated by the analytics or diagnostics toggles. Offline-tolerant via
/// its own PostHogSink queue.
class FeedbackService {
  FeedbackService({
    required PostHogSink sink,
    required Breadcrumbs breadcrumbs,
    required PiiScrubber scrubber,
    required Map<String, Object?> meta,
    DateTime Function() now = DateTime.now,
  })  : _sink = sink,
        _breadcrumbs = breadcrumbs,
        _scrubber = scrubber,
        _meta = meta,
        _now = now;

  final PostHogSink _sink;
  final Breadcrumbs _breadcrumbs;
  final PiiScrubber _scrubber;
  final Map<String, Object?> _meta;
  final DateTime Function() _now;

  Future<void> load() => _sink.load();

  Future<void> submit(FeedbackReport report) async {
    _sink.enqueue(PostHogEvent(
      name: 'feedback_submitted',
      timestamp: _now(),
      properties: {
        ..._meta,
        'type': report.type.name,
        'message': _scrubber.scrub(report.message),
        if (report.email != null && report.email!.isNotEmpty) 'email': report.email,
        if (report.attachDiagnostics)
          'breadcrumbs': _scrubber.scrubAll(_breadcrumbs.snapshot()),
      },
    ));
    await _sink.flush();
  }

  Future<void> dispose() => _sink.dispose();
}

final feedbackServiceProvider = Provider<FeedbackService>(
  (ref) => throw UnimplementedError('Override feedbackServiceProvider in main()'),
);
```

Note: when `attachDiagnostics` is true the standard `_meta` (which includes `app_version`, `source`, `platform`) is already merged in; that satisfies the "attach app version + OS" requirement without a separate branch.

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/feedback/feedback_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/feedback/feedback_service.dart \
        packages/screen_recorder/test/feedback/feedback_service_test.dart
git commit -m "feat: add always-on FeedbackService"
```

---

### Task 8: `installGlobalErrorHandlers`

**Files:**
- Create: `lib/diagnostics/global_error_handlers.dart`
- Test: `test/diagnostics/global_error_handlers_test.dart`

**Interfaces:**
- Consumes: `DiagnosticsService` (Task 6).
- Produces: `void installGlobalErrorHandlers(DiagnosticsService diagnostics)` — sets `FlutterError.onError` (chaining to the previous handler so debug console output is preserved) and `PlatformDispatcher.instance.onError` (forwards, returns `true`).

- [ ] **Step 1: Write the failing test.** Create `test/diagnostics/global_error_handlers_test.dart`. Use a tiny fake that records captures (no network):

```dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/global_error_handlers.dart';

class _Recorder {
  final captures = <Object>[];
}

void main() {
  test('FlutterError.onError forwards to the capture callback', () {
    final rec = _Recorder();
    final previous = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previous);

    installGlobalErrorHandlers(
      onCapture: (error, stack, {handled = false}) => rec.captures.add(error),
    );

    FlutterError.reportError(FlutterErrorDetails(exception: StateError('boom')));
    expect(rec.captures, hasLength(1));
    expect(rec.captures.single, isA<StateError>());
  });
}
```

Note: to keep this unit-testable without constructing a full `DiagnosticsService`, `installGlobalErrorHandlers` takes a capture callback rather than the service directly. `main()` passes `diagnostics.captureException`. Update the interface to:

```dart
typedef CaptureFn = void Function(Object error, StackTrace? stack, {bool handled});
void installGlobalErrorHandlers({required CaptureFn onCapture});
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/global_error_handlers_test.dart`
Expected: FAIL — function not found.

- [ ] **Step 3: Implement.** Create `lib/diagnostics/global_error_handlers.dart`:

```dart
import 'dart:ui';

import 'package:flutter/foundation.dart';

typedef CaptureFn = void Function(Object error, StackTrace? stack, {bool handled});

/// Routes uncaught Flutter/Dart errors into diagnostics while preserving the
/// existing debug console behavior. Call once, early in main(). Async errors
/// outside the Flutter pipeline are covered by wrapping runApp in
/// runZonedGuarded in main() (see Task 9).
void installGlobalErrorHandlers({required CaptureFn onCapture}) {
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    previous?.call(details); // keep dumping in debug
    onCapture(details.exception, details.stack, handled: false);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    onCapture(error, stack, handled: false);
    return true;
  };
}
```

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/diagnostics/global_error_handlers_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/diagnostics/global_error_handlers.dart \
        packages/screen_recorder/test/diagnostics/global_error_handlers_test.dart
git commit -m "feat: add installGlobalErrorHandlers"
```

---

### Task 9: Wire services + handlers into `main()`

Integration wiring; no new unit test (covered by the package build + a smoke run in Task 12). Keep every new path best-effort.

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/ui/screens/playback_screen.dart` (one manual capture)

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces: overridden `diagnosticsServiceProvider`, `feedbackServiceProvider`; global handlers installed; `runZonedGuarded` wrap; distinct-id sync + `shareDiagnostics` observer.

- [ ] **Step 1: Resolve app version + shared meta.** In `main()`, after `appSupportPath` is known, add:

```dart
final packageInfo = await PackageInfo.fromPlatform();
final appVersion = '${packageInfo.version}+${packageInfo.buildNumber}';
final diagnosticsMeta = <String, Object?>{
  'source': 'app',
  'platform': Platform.operatingSystem,
  'app_version': appVersion,
};
final scrubber = PiiScrubber.forCurrentUser();
```

(Add imports: `package:package_info_plus/package_info_plus.dart`, and the new diagnostics/feedback files.)

- [ ] **Step 2: Build the diagnostics + feedback services.** After `analyticsService` is built:

```dart
final distinctId = await _resolveAnalyticsDistinctId(appSupportPath);
// (reuse the same value already resolved for analytics rather than recomputing)

final diagnosticsService = DiagnosticsService(
  sink: PostHogSink(
    store: AnalyticsQueueStore(path: p.join(appSupportPath, 'diagnostics_queue.json')),
    distinctId: distinctId,
    projectKey: AnalyticsConfig.projectKey,
    host: AnalyticsConfig.hostResolved,
  ),
  builder: ExceptionEventBuilder(scrubber: scrubber, meta: diagnosticsMeta),
  breadcrumbs: Breadcrumbs.instance,
  scrubber: scrubber,
  enabled: initialGlobalPreferences.shareDiagnostics,
);
await diagnosticsService.load();

final feedbackService = FeedbackService(
  sink: PostHogSink(
    store: AnalyticsQueueStore(path: p.join(appSupportPath, 'feedback_queue.json')),
    distinctId: distinctId,
    projectKey: AnalyticsConfig.projectKey,
    host: AnalyticsConfig.hostResolved,
  ),
  breadcrumbs: Breadcrumbs.instance,
  scrubber: scrubber,
  meta: diagnosticsMeta,
);
await feedbackService.load();
```

Refactor `_resolveAnalyticsDistinctId` call so the id is computed once and passed to all three (analytics `distinctId:` param uses the same local).

- [ ] **Step 3: Install handlers + wrap runApp.** Replace the bare `runApp(...)` with a guarded zone, and install handlers just before:

```dart
installGlobalErrorHandlers(onCapture: diagnosticsService.captureException);

runZonedGuarded(() {
  runApp(ProviderScope(
    overrides: [
      // ...existing overrides...
      analyticsServiceProvider.overrideWithValue(analyticsService),
      diagnosticsServiceProvider.overrideWithValue(diagnosticsService),
      feedbackServiceProvider.overrideWithValue(feedbackService),
    ],
    child: MyApp(/* ...unchanged... */),
  ));
}, (error, stack) => diagnosticsService.captureException(error, stack, handled: false));
```

- [ ] **Step 4: Sync distinct_id + observe the diagnostics toggle.** In `_wireAnalyticsObservers` (in `_MyAppState`), add a listen for the diagnostics toggle and extend the identify observer:

```dart
// diagnostics opt-out:
ref.listenManual<bool>(
  globalPreferencesControllerProvider.select((p) => p.shareDiagnostics),
  (prev, next) => ref.read(diagnosticsServiceProvider).setEnabled(next),
);

// inside the existing identify observer, after analytics.identify(next.claims.sub):
ref.read(diagnosticsServiceProvider).setDistinctId(next.claims.sub);
ref.read(feedbackServiceProvider); // feedback sink id sync: add setDistinctId below
```

For the feedback sink to also follow identify, add a `setDistinctId(String)` passthrough to `FeedbackService` (one line delegating to `_sink.setDistinctId`) and call it here. Add that method in Task 7's class if not already present.

- [ ] **Step 5: Flush diagnostics + feedback on close.** Find the existing `analyticsServiceProvider).flush()` on lifecycle detach (~line 605) and add alongside:

```dart
unawaited(ref.read(diagnosticsServiceProvider).flush());
unawaited(ref.read(feedbackServiceProvider).dispose()); // or flush; dispose also flushes
```

- [ ] **Step 6: Add one manual capture at the export-failure arm.** In `lib/ui/screens/playback_screen.dart`, in the `case ExportFailure(:final error):` arm (currently ~line 2144, right after the `AnalyticsEvents.exportFailed` capture and before `AppAlerts.error`), add:

```dart
ref.read(diagnosticsServiceProvider).captureException(
  error,
  StackTrace.current,
  handled: true,
  context: {'phase': 'export', 'format': settings.format.name},
);
```

- [ ] **Step 7: Build the app to verify wiring compiles.**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: build succeeds. (If the dev env can't build macOS, fall back to `flutter analyze` with zero new errors.)

- [ ] **Step 8: Commit.**

```bash
git add packages/screen_recorder/lib/main.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: wire diagnostics + feedback services and global error handlers"
```

---

### Task 10: Settings toggle + "Send feedback" entry

**Files:**
- Modify: `lib/ui/screens/settings_screen.dart`
- Test: `test/ui/settings_diagnostics_toggle_test.dart`

**Interfaces:**
- Consumes: `shareDiagnostics` (Task 5), `FeedbackSheet` (Task 11 — build Task 11 first or stub the row's `onTap` to open it once it exists).

- [ ] **Step 1: Write the failing widget test.** Create `test/ui/settings_diagnostics_toggle_test.dart` that pumps the privacy card region with both toggles overridden and asserts the diagnostics switch flips the controller. Model it on the existing analytics-toggle coverage; assert the new `SwitchListTile` titled "Send crash & error reports" calls `setShareDiagnostics`.

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// import the settings screen + providers; override globalPreferencesController
// with a fake initial GlobalPreferences(shareDiagnostics: true), pump the
// settings screen, tap the "Send crash & error reports" switch, and assert
// the controller's state.shareDiagnostics flipped to false.

void main() {
  testWidgets('diagnostics toggle flips shareDiagnostics', (tester) async {
    // Arrange providers + pump SettingsScreen (follow the existing test setup
    // pattern used for other settings widget tests in this package).
    // Act: await tester.tap(find.text('Send crash & error reports'));
    // Assert: read the controller and expect shareDiagnostics == false.
  });
}
```

Note: fill the test body using the same ProviderScope + pump setup other `test/ui/**` widget tests in this package already use (there is precedent for overriding `globalPreferencesControllerProvider` and `globalPreferencesStoreProvider`). Assert on the controller state after the tap.

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/ui/settings_diagnostics_toggle_test.dart`
Expected: FAIL — the new toggle doesn't exist yet.

- [ ] **Step 3: Implement the toggle + feedback row.** In `settings_screen.dart`, extend `_privacyCard()` to a `Column` with the existing analytics `SwitchListTile` plus a second:

```dart
SwitchListTile(
  contentPadding: EdgeInsets.zero,
  title: Text('Send crash & error reports',
      style: TextStyle(color: context.palette.textPrimary)),
  subtitle: Text(
    'Sends anonymized error and crash reports so we can fix problems. '
    'File paths are stripped and your recordings are never included.',
    style: TextStyle(color: context.palette.textSecondary),
  ),
  value: ref.watch(globalPreferencesControllerProvider
      .select((p) => p.shareDiagnostics)),
  onChanged: (v) => ref
      .read(globalPreferencesControllerProvider.notifier)
      .setShareDiagnostics(v),
),
```

Add a "Send feedback" `ListTile` (mirroring the "Theme playground" row style) whose `onTap` opens the feedback form:

```dart
ListTile(
  leading: Icon(Icons.feedback_outlined, color: context.palette.textPrimary),
  title: Text('Send feedback',
      style: TextStyle(color: context.palette.textPrimary)),
  subtitle: Text('Share an idea or report a problem',
      style: TextStyle(color: context.palette.textSecondary)),
  trailing: Icon(Icons.chevron_right, color: context.palette.textSecondary),
  contentPadding: EdgeInsets.zero,
  onTap: () => FeedbackSheet.show(context),
),
```

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/ui/settings_diagnostics_toggle_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/ui/screens/settings_screen.dart \
        packages/screen_recorder/test/ui/settings_diagnostics_toggle_test.dart
git commit -m "feat: add diagnostics toggle and feedback entry to Settings"
```

---

### Task 11: `FeedbackSheet` form

Build this before Task 10 Step 3 (the settings row references `FeedbackSheet.show`). Ordered after for narrative flow; if executing strictly top-to-bottom, stub the `onTap` and fill it once this task lands.

**Files:**
- Create: `lib/ui/feedback/feedback_sheet.dart`
- Test: `test/ui/feedback_sheet_test.dart`

**Interfaces:**
- Consumes: `FeedbackService` + `feedbackServiceProvider` (Task 7), `FeedbackType`, `FeedbackReport`, `AppAlerts` (`AppAlerts.success(String)`).
- Produces: `class FeedbackSheet` with `static Future<void> show(BuildContext context)`.

- [ ] **Step 1: Write the failing widget test.** Create `test/ui/feedback_sheet_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/feedback/feedback_service.dart';
import 'package:screen_recorder/ui/feedback/feedback_sheet.dart';

class _FakeFeedback implements FeedbackService {
  FeedbackReport? submitted;
  @override
  Future<void> submit(FeedbackReport report) async => submitted = report;
  @override
  Future<void> load() async {}
  @override
  Future<void> dispose() async {}
  @override
  void setDistinctId(String id) {}
}

void main() {
  testWidgets('submitting sends type + message through the service', (tester) async {
    final fake = _FakeFeedback();
    await tester.pumpWidget(ProviderScope(
      overrides: [feedbackServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
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
  });
}
```

- [ ] **Step 2: Run it, expect failure.**

Run: `cd packages/screen_recorder && flutter test test/ui/feedback_sheet_test.dart`
Expected: FAIL — `FeedbackSheet` not found.

- [ ] **Step 3: Implement the form.** Create `lib/ui/feedback/feedback_sheet.dart`: a `ConsumerStatefulWidget` shown via `showModalBottomSheet` (or a dialog) from `FeedbackSheet.show`. Contents: a segmented Idea/Problem selector (default Problem) bound to `FeedbackType`, a required multiline message `TextField`, an optional email `TextField`, an "Attach diagnostics" `CheckboxListTile` with a one-line note ("Includes app version, OS, and recent activity logs — no recordings or file paths."), a Cancel and a Send button. On Send with a non-empty message: call `ref.read(feedbackServiceProvider).submit(FeedbackReport(...))`, close the sheet, then `AppAlerts.success('Thanks — feedback sent.')`. Disable Send while the message is empty. Follow existing dark-theme `context.palette.*` tokens.

- [ ] **Step 4: Run tests, expect pass.**

Run: `cd packages/screen_recorder && flutter test test/ui/feedback_sheet_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit.**

```bash
git add packages/screen_recorder/lib/ui/feedback/feedback_sheet.dart \
        packages/screen_recorder/test/ui/feedback_sheet_test.dart
git commit -m "feat: add in-app feedback form"
```

---

### Task 12: Full-suite regression + live verification

**Files:** none (verification only).

- [ ] **Step 1: Run the whole package suite.**

Run: `cd packages/screen_recorder && flutter test`
Expected: PASS, including the unchanged analytics tests (refactor guard) and all new tests.

- [ ] **Step 2: Run the engine suite** (AppLogger change).

Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS.

- [ ] **Step 3: Static analysis.**

Run: `cd packages/screen_recorder && flutter analyze`
Expected: no new warnings/errors from the added files.

- [ ] **Step 4: Live PostHog verification (the spec's "done" gate).** Build a debug app with a dev PostHog key and confirm real ingestion:

```bash
cd packages/screen_recorder && flutter run -d macos \
  --dart-define=SLIPREEL_POSTHOG_KEY=phc_DEV_KEY \
  --dart-define=SLIPREEL_POSTHOG_HOST=https://us.i.posthog.com
```

Then, with the running app:
- Trigger a caught exception (or temporarily throw in a debug-only action) and confirm an `$exception` appears under PostHog **Error Tracking** as a grouped **issue** (not just a raw event) — this validates the `$exception_list` shape.
- Open Settings → Send feedback, submit a "problem" with "attach diagnostics" ticked, and confirm a `feedback_submitted` event appears with `breadcrumbs` + `app_version`.
- Toggle "Send crash & error reports" off, trigger another exception, and confirm nothing new arrives.

Record the outcomes (issue grouped: yes/no; feedback event: yes/no; opt-out respected: yes/no) in the PR description. If the `$exception` lands but does not group into an issue, adjust the `$exception_list` shape in `ExceptionEventBuilder` (property names must match PostHog's ingestion contract exactly) and repeat.

- [ ] **Step 5: Final commit / open PR.** With all suites green and live verification recorded, the branch `feat/error-tracking-feedback` is ready for a PR to `main`.

---

## Self-Review Notes

- **Spec coverage:** §3 sink extraction → Task 1; §4.4 scrubber → Task 2; §4.5 breadcrumbs → Task 3; §4.4 builder → Task 4; §4.9 consent → Task 5; §4.3 DiagnosticsService → Task 6; §4.7 FeedbackService → Task 7; §4.8 handlers → Tasks 8–9; §4.9/§4.10 UI → Tasks 10–11; §5 verification → Task 12. Native crash forwarding (§4.6, §2 v1b) is intentionally out of scope here.
- **distinct_id sync (§8):** Task 9 Step 4 keeps diagnostics + feedback ids in step with analytics identify.
- **Flood control (§4.3):** Task 6 (session cap + fingerprint dedupe window).
- **Known follow-ups for v1b:** `NativeCrashScanner`, watermark store, `.ips` parsing — separate plan.
