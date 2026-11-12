import 'package:bb_mobile/core/wallet/data/repositories/wallet_address_repository.dart';
import 'package:bb_mobile/core/wallet/domain/repositories/wallet_utxo_repository.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bb_mobile/locator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primitives/primitives.dart' show Ok;

import 'support/integration_harness.dart';
import 'support/wallet_payments.dart';

Future<void> main({bool isInitialized = false}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!isInitialized) await IntegrationHarness.init();

  group(
    'regtest wallet lifecycle',
    () {
      for (final liquid in [false, true]) {
        test(
          '${liquid ? 'Liquid' : 'Bitcoin'} prepares, signs and receives a confirmed payment',
          () async {
            final sender = await IntegrationHarness.fundedWallet(
              liquid: liquid,
            );
            final receiver = await IntegrationHarness.fundedWallet(
              liquid: liquid,
            );
            expect(sender.id, isNot(receiver.id));
            final address = await locator<WalletAddressRepository>()
                .generateNewReceiveAddress(walletId: receiver.id);
            final txid = await sendRegtestPayment(
              sender,
              address.address,
              10000,
            );
            await IntegrationHarness.controller.mine(liquid: liquid);
            final repository = locator<WalletRepository>();
            final deadline = DateTime.now().add(const Duration(seconds: 60));
            Wallet? received;
            while (DateTime.now().isBefore(deadline)) {
              final result = await repository.getWallet(
                receiver.id,
                sync: true,
              );
              if (result case Ok(
                :final value,
              ) when value.balanceSat == BigInt.from(210000)) {
                received = value;
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 500));
            }
            expect(
              received,
              isNotNull,
              reason:
                  'The app must observe the payment, not only a successful broadcast',
            );
            final coins = await locator<WalletUtxoRepository>().getWalletUtxos(
              walletId: receiver.id,
            );
            final payment = coins.where((coin) => coin.txId == txid).toList();
            expect(payment, hasLength(1));
            expect(payment.single.amountSat, BigInt.from(10000));
            expect(payment.single.isConfirmed, isTrue);
          },
          timeout: const Timeout(Duration(minutes: 4)),
        );
      }
    },
    skip: IntegrationHarness.isRegtest
        ? null
        : 'Run make integration-test-regtest against the local stack',
  );
}
