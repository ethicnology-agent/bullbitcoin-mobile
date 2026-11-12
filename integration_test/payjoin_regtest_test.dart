import 'package:flutter_test/flutter_test.dart';
import 'support/integration_harness.dart';
import 'package:bb_mobile/locator.dart';
import 'package:bull_payjoin/bull_payjoin.dart';
import 'package:primitives/primitives.dart' show Err;
import 'support/payjoin_regtest.dart';

Future<void> main({bool isInitialized = false}) async {
  if (!IntegrationHarness.isRegtest) return;
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!isInitialized) await IntegrationHarness.init();
  setUpAll(() async {
    for (final action in [PayjoinAction.send, PayjoinAction.receive]) {
      final result = await locator<PayjoinPolicyAccess>().setActionEnabled(
        action,
        enabled: true,
      );
      if (result case Err(:final failure)) {
        fail('Payjoin consent setup failed: ${failure.runtimeType}');
      }
    }
  });
  registerRegtestPayjoinScenarios();
}
