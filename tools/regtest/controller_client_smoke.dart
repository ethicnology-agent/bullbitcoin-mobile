import 'dart:io';

import '../../integration_test/support/regtest_controller.dart';

/// Exercise the actual Dart request framing before the phone wallet suite.
Future<void> main() async {
  try {
    final controller = RegtestController();
    await controller.verify();
    await controller.invoice(amountSat: 1000);
    stdout.writeln('Dart controller GET and bounded POST passed');
  } catch (error) {
    stderr.writeln(
      'Controller client fixture failed category=${error.runtimeType}',
    );
    exitCode = 1;
  }
}
