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
  const OnboardingScreen({
    super.key,
    this.initialStep = OnboardingStep.welcome,
  });

  final OnboardingStep initialStep;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  late final PageController _pageController;
  late int _page;

  @override
  void initState() {
    super.initState();
    _page = widget.initialStep.index;
    _pageController = PageController(initialPage: _page);
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

  // The live scroll position as a page index (fractional mid-transition),
  // falling back to the settled page before the viewport has dimensions.
  double _currentPage() {
    if (_pageController.hasClients &&
        _pageController.position.haveDimensions) {
      return _pageController.page ?? _page.toDouble();
    }
    return _page.toDouble();
  }

  Future<void> _next() async {
    final nextPage = _page + 1;
    if (nextPage >= OnboardingStep.values.length) return;

    // Persist before moving forward. macOS may terminate and relaunch the app
    // while a permission is being granted, so the permissions page must
    // already be durable by the time its Enable buttons can be pressed.
    try {
      await ref
          .read(onboardingStoreProvider)
          .saveStep(OnboardingStep.values[nextPage]);
    } catch (_) {
      if (mounted) {
        AppAlerts.error(
          "Couldn't save onboarding progress — you may return to this screen after relaunch.",
        );
      }
    }
    if (!mounted) return;
    unawaited(
      _pageController.animateToPage(
        nextPage,
        duration: const Duration(milliseconds: 560),
        curve: _pageCurve,
      ),
    );
  }

  // Per-page fade + scale + gentle parallax driven by the scroll offset, so
  // pages don't just slide flatly — the incoming one settles in with depth.
  Widget _pageFx(int index, Widget child) {
    return AnimatedBuilder(
      animation: _pageController,
      child: child,
      builder: (context, child) {
        final page = _currentPage();
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
                final opacity = (1 - _currentPage()).clamp(0.0, 1.0);
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
                _pageFx(1, FeaturesPage(onNext: _next, active: _page == 1)),
                _pageFx(2, PermissionsPage(onNext: _next)),
                _pageFx(3, ReadyPage(onFinish: _finish, active: _page == 3)),
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
