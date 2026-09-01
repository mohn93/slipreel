import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder/analytics/analytics_events.dart';
import 'package:screen_recorder/analytics/analytics_service.dart';
import 'package:screen_recorder/onboarding/onboarding_store.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'pages/features_page.dart';
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

  @override
  void initState() {
    super.initState();
    ref.captureAnalytics(AnalyticsEvents.screenViewed,
        properties: {'screen': 'onboarding'});
    // Default app window is the 68px-tall recording bar; onboarding needs the
    // full panel chrome so its pages aren't clipped. RecordingBarScreen
    // restores `bar` mode in its own initState after _finish navigates.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(windowModeControllerProvider.notifier).showPanel();
    });
  }

  // Material-3 "emphasized" easing: quick to leave, luxuriously slow to settle.
  static const _pageCurve = Cubic(0.05, 0.7, 0.1, 1.0);

  void _next() {
    _pageController.animateToPage(
      _page + 1,
      duration: const Duration(milliseconds: 560),
      curve: _pageCurve,
    );
  }

  // Per-page fade + scale + gentle parallax driven by the scroll offset, so
  // pages don't just slide flatly — the incoming one settles in with depth.
  Widget _pageFx(int index, Widget child) {
    return AnimatedBuilder(
      animation: _pageController,
      child: child,
      builder: (context, child) {
        var page = _page.toDouble();
        if (_pageController.hasClients &&
            _pageController.position.haveDimensions) {
          page = _pageController.page ?? page;
        }
        final delta = index - page; // 0 centered, ±1 fully off to a side
        final t = delta.abs().clamp(0.0, 1.0);
        final eased = Curves.easeOutCubic.transform(1 - t); // 1 centered → 0
        final opacity = eased;
        final scale = 0.90 + 0.10 * eased;
        final dx = delta * 28.0; // subtle parallax: content trails the slide
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(dx, 0),
            child: Transform.scale(
              scale: scale,
              child: child,
            ),
          ),
        );
      },
    );
  }

  Future<void> _finish() async {
    try {
      await ref.read(onboardingStoreProvider).markComplete();
    } catch (_) {
      if (mounted) {
        AppAlerts.error(
          "Couldn't save onboarding state — you may see this screen again next launch.",
        );
      }
    }
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
      body: Stack(
        children: [
          // Welcome wallpaper, full-bleed behind everything (page-dot strip
          // included), fading out as the user leaves the first page.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _pageController,
              builder: (context, _) {
                var page = _page.toDouble();
                if (_pageController.hasClients &&
                    _pageController.position.haveDimensions) {
                  page = _pageController.page ?? page;
                }
                final opacity = (1 - page).clamp(0.0, 1.0);
                if (opacity <= 0) return const SizedBox.shrink();
                return Opacity(
                  opacity: opacity,
                  child: const WelcomeBackground(),
                );
              },
            ),
          ),
          Column(
        children: [
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              onPageChanged: (i) => setState(() => _page = i),
              children: [
                _pageFx(0, WelcomePage(onNext: _next)),
                _pageFx(1, FeaturesPage(onNext: _next)),
                _pageFx(2, PermissionsPage(onNext: _next)),
                _pageFx(3, ReadyPage(onFinish: _finish)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 24, top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(4, (i) {
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
        ],
      ),
    );
  }
}
