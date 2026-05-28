import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/onboarding/onboarding_store.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';
import 'pages/permissions_page.dart';
import 'pages/ready_page.dart';
import 'pages/welcome_page.dart';

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _page = 0;

  void _next() {
    _pageController.animateToPage(
      _page + 1,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _finish() async {
    await ref.read(onboardingStoreProvider).markComplete();
    if (!mounted) return;
    unawaited(
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const RecordingBarScreen()),
      ),
    );
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                WelcomePage(onNext: _next),
                PermissionsPage(onNext: _next),
                ReadyPage(onFinish: _finish),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final active = i == _page;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: active ? 24 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: active ? Colors.white : Colors.white24,
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}
