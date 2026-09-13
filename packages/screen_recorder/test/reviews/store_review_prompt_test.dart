import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/reviews/store_review_prompt.dart';

void main() {
  test('requests once and remembers across launches', () async {
    var remembered = false;
    var requests = 0;
    StoreReviewPrompt make() => StoreReviewPrompt(
      isStore: true,
      wasRequested: () async => remembered,
      rememberRequest: () async {
        remembered = true;
      },
      requestNative: () async {
        requests++;
        return true;
      },
      wait: () async {},
    );
    final prompt = make();
    await prompt.afterSuccessfulExport(isIdle: () => true);
    await prompt.afterSuccessfulExport(isIdle: () => true);
    await make().afterSuccessfulExport(isIdle: () => true);
    expect(requests, 1);
    expect(remembered, isTrue);
  });
  test('website editions never request or write review state', () async {
    final prompt = StoreReviewPrompt(
      isStore: false,
      wasRequested: () async => throw StateError('Must not read'),
      rememberRequest: () async => fail('Must not write'),
      requestNative: () async {
        fail('Must not invoke StoreKit');
      },
      wait: () async {},
    );
    await prompt.afterSuccessfulExport(isIdle: () => true);
  });
  test('rechecks idle after the delay and retries on a later export', () async {
    var requests = 0;
    var idle = true;
    final pause = Completer<void>();
    final prompt = StoreReviewPrompt(
      isStore: true,
      wasRequested: () async => false,
      rememberRequest: () async {},
      requestNative: () async {
        requests++;
        return true;
      },
      wait: () => pause.future,
    );
    final first = prompt.afterSuccessfulExport(isIdle: () => idle);
    idle = false;
    pause.complete();
    await first;
    expect(requests, 0);
    idle = true;
    await prompt.afterSuccessfulExport(isIdle: () => idle);
    expect(requests, 1);
  });
  test('concurrent exports cannot double request', () async {
    final pause = Completer<void>();
    var requests = 0;
    final prompt = StoreReviewPrompt(
      isStore: true,
      wasRequested: () async => false,
      rememberRequest: () async {},
      requestNative: () async {
        requests++;
        return true;
      },
      wait: () => pause.future,
    );
    final first = prompt.afterSuccessfulExport(isIdle: () => true);
    final second = prompt.afterSuccessfulExport(isIdle: () => true);
    pause.complete();
    await Future.wait([first, second]);
    expect(requests, 1);
  });
  test('native unavailability does not consume the opportunity', () async {
    var remembered = false;
    var available = false;
    final prompt = StoreReviewPrompt(
      isStore: true,
      wasRequested: () async => remembered,
      rememberRequest: () async {
        remembered = true;
      },
      requestNative: () async => available,
      wait: () async {},
    );
    await prompt.afterSuccessfulExport(isIdle: () => true);
    expect(remembered, false);
    available = true;
    await prompt.afterSuccessfulExport(isIdle: () => true);
    expect(remembered, true);
  });
  test('native errors never turn successful exports into failures', () async {
    final prompt = StoreReviewPrompt(
      isStore: true,
      wasRequested: () async => false,
      rememberRequest: () async => fail('Must not remember'),
      requestNative: () async => throw StateError('Unavailable'),
      wait: () async {},
    );
    await prompt.afterSuccessfulExport(isIdle: () => true);
  });
}
