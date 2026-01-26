import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:screen_recorder_macos/screen_recorder_macos.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('plugin can be registered', (WidgetTester tester) async {
    ScreenRecorderMacos.registerWith();
    expect(ScreenRecorderPlatform.instance, isNotNull);
  });
}
