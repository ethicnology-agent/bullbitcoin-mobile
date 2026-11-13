import 'package:flutter_test/flutter_test.dart';

import '../packages/bull_payjoin/test/payjoin_runtime_test.dart' as custody;
import 'support/integration_harness.dart';

Future<void> main({bool isInitialized = false}) async {
  if (!IntegrationHarness.isRegtest) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!isInitialized) await IntegrationHarness.init();

  // Run the same real SQLite lock and preservation checks on the device.
  group('Payjoin native custody', () {
    var suspended = false;
    setUpAll(() async {
      await IntegrationHarness.suspendPayjoin();
      suspended = true;
    });
    tearDownAll(() async {
      if (suspended) await IntegrationHarness.resumePayjoin();
    });
    custody.main();
  });
}
