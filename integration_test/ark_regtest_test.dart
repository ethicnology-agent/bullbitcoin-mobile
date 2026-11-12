import 'package:bb_mobile/core/wallet/data/repositories/wallet_address_repository.dart';
import 'package:bb_mobile/core/wallet/domain/repositories/wallet_utxo_repository.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/locator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primitives/primitives.dart' show Err;

import 'support/integration_harness.dart';
import 'support/wallet_payments.dart';

Future<void> main({bool isInitialized = false}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!isInitialized) await IntegrationHarness.init();

  test(
    'BULL confirms a Bark deposit and receives a selected-VTXO offboard',
    () async {
      final sender = await IntegrationHarness.fundedWallet();
      final receiver = await IntegrationHarness.newWallet();
      final fixture = await IntegrationHarness.controller.arkFundingAddress();
      final deposit = await sendRegtestPayment(sender, fixture.address, 150000);
      await IntegrationHarness.controller.mine(count: 3);
      await IntegrationHarness.controller.boardArk(fixture.runId, deposit);

      final address = await locator<WalletAddressRepository>()
          .generateNewReceiveAddress(walletId: receiver.id);
      final offboard = await IntegrationHarness.controller.offboardArk(
        fixture.runId,
        address.address,
      );
      await IntegrationHarness.controller.mine(count: 3);
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (DateTime.now().isBefore(deadline)) {
        final result = await locator<WalletRepository>().getWallet(
          receiver.id,
          sync: true,
        );
        if (result case Err(:final failure)) {
          fail('Ark payout sync failed: ${failure.runtimeType}');
        }
        final coins = await locator<WalletUtxoRepository>().getWalletUtxos(
          walletId: receiver.id,
        );
        final received = coins.where((coin) => coin.txId == offboard).toList();
        if (received.isNotEmpty) {
          expect(received, hasLength(1));
          expect(received.single.amountSat, greaterThan(BigInt.from(90000)));
          expect(received.single.confirmations, greaterThan(0));
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      fail('The actual BULL wallet did not observe the confirmed Ark offboard');
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip: IntegrationHarness.isRegtest
        ? null
        : 'Requires the isolated BULL Bitcoin and Bark fixture',
  );
}
