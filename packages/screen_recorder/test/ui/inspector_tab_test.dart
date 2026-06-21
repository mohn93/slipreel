import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_tab.dart';

void main() {
  test('Device tab hidden for screen recordings, shown for device captures', () {
    expect(visibleInspectorTabs(isDevice: false),
        isNot(contains(InspectorTab.device)));
    expect(visibleInspectorTabs(isDevice: true), contains(InspectorTab.device));

    // Every non-device tab is always present, both ways.
    for (final t in InspectorTab.values) {
      if (t == InspectorTab.device) continue;
      expect(visibleInspectorTabs(isDevice: false), contains(t));
      expect(visibleInspectorTabs(isDevice: true), contains(t));
    }

    // Order is preserved (Device sits right after Background when shown).
    final shown = visibleInspectorTabs(isDevice: true);
    expect(shown.indexOf(InspectorTab.device),
        shown.indexOf(InspectorTab.background) + 1);
  });
}
