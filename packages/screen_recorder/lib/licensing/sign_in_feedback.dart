import 'package:flutter/foundation.dart';

class SignInFeedback {
  const SignInFeedback(
    this.title,
    this.message, {
    this.action = 'account',
    this.exportsUnlocked = false,
  });
  final String title;
  final String message;
  final bool exportsUnlocked;
  // Fixed destinations only; never follow a URL supplied by a callback.
  final String action;
}

class SignInFeedbackController extends ChangeNotifier {
  SignInFeedback? pending;
  void show(SignInFeedback value) {
    pending = value;
    notifyListeners();
  }

  void clear() {
    pending = null;
    notifyListeners();
  }
}
