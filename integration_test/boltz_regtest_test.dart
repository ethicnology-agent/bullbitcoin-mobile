import 'dart:io';
import 'dart:math';

import 'package:bb_mobile/core/wallet/data/repositories/wallet_address_repository.dart';
import 'package:bb_mobile/core/wallet/domain/repositories/wallet_utxo_repository.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bb_mobile/locator.dart';
import 'package:bull_sdk/boltz.dart' as boltz;
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:primitives/primitives.dart' show BitcoinNetwork, Ok, Err;
import 'package:secrets/secrets.dart' as custody;

import 'support/encrypted_swap_store.dart';
import 'support/integration_harness.dart';
import 'support/wallet_payments.dart';

const _url = 'http://127.0.0.1:9001/v2';
const _btc = boltz.ElectrumSettings(
  url: '127.0.0.1:50000',
  tls: false,
  validateDomain: false,
  timeout: 10,
);
const _liquid = boltz.ElectrumSettings(
  url: '127.0.0.1:50001',
  tls: false,
  validateDomain: false,
  timeout: 10,
);

Future<void> main({bool isInitialized = false}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!isInitialized) await IntegrationHarness.init();

  test(
    'BULL wallets settle all six Boltz routes and recover encrypted swap state',
    () async {
      final secret = await IntegrationHarness.generateSecret();
      final derived = switch (await secret.derive.swapKey(
        network: BitcoinNetwork.regtest,
      )) {
        Ok(:final value) => value,
        Err(:final failure) => fail(
          'Swap capability failed: ${failure.runtimeType}',
        ),
      };
      final key = boltz.SwapMasterKey(
        xprv: derived.xprv,
        xpub: derived.xpub,
        mnemonic: derived.mnemonic,
        fingerprint: derived.fingerprint.hex,
        network: boltz.Network.regtest,
      );
      final name = 'boltz${Random.secure().nextInt(0x7fffffff)}';
      final keys = locator<custody.Secrets>().databaseKeys(
        module: 'regtest_validation',
      );
      final databaseKey = switch (await keys.getOrCreate(name: name)) {
        Ok(:final value) => value,
        Err(:final failure) => fail(
          'Recovery encryption failed: ${failure.runtimeType}',
        ),
      };
      final temporary = await getTemporaryDirectory();
      final directory = await Directory(
        temporary.path,
      ).createTemp('boltz-regtest-');
      final store = EncryptedSwapStore(
        directory: directory,
        scope: 'regtest:$name',
        key: databaseKey.bytes,
      );
      final client = Dio(
        BaseOptions(
          baseUrl: _url,
          followRedirects: false,
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 10),
        ),
      );
      addTearDown(() async {
        client.close(force: true);
        store.dispose();
        await directory.delete(recursive: true);
        final reset = await keys.reset(name: name);
        if (reset case Err(:final failure)) {
          fail('Recovery fixture cleanup failed: ${failure.runtimeType}');
        }
      });

      Future<String> waitStatus(String id, Set<String> accepted) async {
        final deadline = DateTime.now().add(const Duration(seconds: 120));
        while (DateTime.now().isBefore(deadline)) {
          final response = await client.get<Map<String, dynamic>>('/swap/$id');
          final status = response.data?['status'];
          if (status is String && accepted.contains(status)) return status;
          if (status == 'invoice.failedToPay' ||
              status == 'transaction.failed' ||
              status == 'transaction.lockupFailed') {
            fail('Boltz rejected the fixture operation: $status');
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        fail('Boltz status deadline exceeded');
      }

      Future<dynamic> reload(dynamic swap, bool liquid) async {
        final record = 'swap-${swap.id}';
        await store.write(record, await swap.toJson() as String);
        final encoded = await store.read(record);
        return liquid
            ? boltz.LbtcLnSwap.fromJson(jsonStr: encoded)
            : boltz.BtcLnSwap.fromJson(jsonStr: encoded);
      }

      Future<String> address(Wallet wallet) async =>
          (await locator<WalletAddressRepository>().generateNewReceiveAddress(
            walletId: wallet.id,
          )).address;

      Future<void> received(
        Wallet wallet,
        String txid, {
        int minimum = 90000,
      }) async {
        final deadline = DateTime.now().add(const Duration(seconds: 60));
        while (DateTime.now().isBefore(deadline)) {
          final result = await locator<WalletRepository>().getWallet(
            wallet.id,
            sync: true,
          );
          if (result case Err(:final failure)) {
            fail('Swap payout sync failed: ${failure.runtimeType}');
          }
          final coins = await locator<WalletUtxoRepository>().getWalletUtxos(
            walletId: wallet.id,
          );
          if (coins.any(
            (coin) =>
                coin.txId == txid &&
                coin.isConfirmed &&
                coin.amountSat >= BigInt.from(minimum),
          )) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
        fail('The BULL wallet did not observe the confirmed swap payout');
      }

      var stage = 'creation';
      try {
        for (final liquid in [false, true]) {
          stage = '${liquid ? 'Liquid' : 'Bitcoin'} submarine';
          final invoice = await IntegrationHarness.controller.invoice();
          final index = await store.allocateIndex();
          dynamic swap = liquid
              ? await boltz.LbtcLnSwap.newSubmarine(
                  swapMasterKey: key,
                  index: index,
                  invoice: invoice,
                  network: boltz.Chain.liquidRegtest,
                  electrumUrl: _liquid.url,
                  boltzUrl: _url,
                )
              : await boltz.BtcLnSwap.newSubmarine(
                  swapMasterKey: key,
                  index: index,
                  invoice: invoice,
                  network: boltz.Chain.bitcoinRegtest,
                  electrumUrl: _btc.url,
                  boltzUrl: _url,
                );
          swap = await reload(swap, liquid);
          expect(
            swap.network ==
                (liquid
                    ? boltz.Chain.liquidRegtest
                    : boltz.Chain.bitcoinRegtest),
            isTrue,
          );
          final sender = await IntegrationHarness.fundedWallet(liquid: liquid);
          await sendRegtestPayment(
            sender,
            swap.scriptAddress as String,
            (swap.outAmount as BigInt).toInt(),
          );
          await IntegrationHarness.controller.mine(liquid: liquid);
          final status = await waitStatus(swap.id as String, {
            'transaction.claimed',
            'transaction.claim.pending',
          });
          if (status != 'transaction.claimed') {
            await swap.coopCloseSubmarine();
            await waitStatus(swap.id as String, {'transaction.claimed'});
          }
          final preimage = await swap.getCompletedSubmarinePreimage() as String;
          expect(preimage.length, 64);
        }
        for (final liquid in [false, true]) {
          stage = '${liquid ? 'Liquid' : 'Bitcoin'} reverse';
          final index = await store.allocateIndex();
          dynamic swap = liquid
              ? await boltz.LbtcLnSwap.newReverse(
                  swapMasterKey: key,
                  index: index,
                  outAmount: BigInt.from(100000),
                  network: boltz.Chain.liquidRegtest,
                  electrumUrl: _liquid.url,
                  boltzUrl: _url,
                )
              : await boltz.BtcLnSwap.newReverse(
                  swapMasterKey: key,
                  index: index,
                  outAmount: BigInt.from(100000),
                  network: boltz.Chain.bitcoinRegtest,
                  electrumUrl: _btc.url,
                  boltzUrl: _url,
                );
          swap = await reload(swap, liquid);
          final receiver = await IntegrationHarness.newWallet(liquid: liquid);
          // Attach the error handler immediately while the claim runs in parallel.
          final payment = IntegrationHarness.controller
              .pay(swap.invoice as String)
              .then<Object?>((_) => null, onError: (Object error) => error);
          try {
            await waitStatus(swap.id as String, {
              'transaction.mempool',
              'transaction.confirmed',
            });
            await IntegrationHarness.controller.mine(liquid: liquid);
            final signed =
                await swap.claim(
                      outAddress: await address(receiver),
                      minerFee: const boltz.TxFee.relative(1),
                      tryCooperate: true,
                      electrumSettings: liquid ? _liquid : _btc,
                    )
                    as String;
            final txid =
                await swap.broadcastLocal(
                      signedHex: signed,
                      electrumSettings: liquid ? _liquid : _btc,
                    )
                    as String;
            await IntegrationHarness.controller.mine(liquid: liquid);
            if (await payment != null) {
              fail('The regtest Lightning payer did not settle');
            }
            await received(receiver, txid);
          } finally {
            await payment;
          }
        }
        for (final direction in boltz.ChainSwapDirection.values) {
          stage = 'chain ${direction.name}';
          final fromLiquid = direction == boltz.ChainSwapDirection.lbtcToBtc;
          var swap = await boltz.ChainSwap.newSwap(
            direction: direction,
            swapMasterKey: key,
            index: await store.allocateIndex(count: 2),
            amount: BigInt.from(100000),
            network: boltz.Network.regtest,
            btcElectrumUrl: _btc.url,
            lbtcElectrumUrl: _liquid.url,
            boltzUrl: _url,
          );
          await store.write('swap-${swap.id}', await swap.toJson());
          swap = await boltz.ChainSwap.fromJson(
            jsonStr: await store.read('swap-${swap.id}'),
          );
          expect(swap.network, boltz.Network.regtest);
          final sender = await IntegrationHarness.fundedWallet(
            liquid: fromLiquid,
          );
          final receiver = await IntegrationHarness.newWallet(
            liquid: !fromLiquid,
          );
          await sendRegtestPayment(
            sender,
            swap.scriptAddress,
            swap.outAmount.toInt(),
          );
          await IntegrationHarness.controller.mine(liquid: fromLiquid);
          await waitStatus(swap.id, {
            'transaction.server.mempool',
            'transaction.server.confirmed',
          });
          await IntegrationHarness.controller.mine(liquid: !fromLiquid);
          final signed = await swap.claim(
            outAddress: await address(receiver),
            minerFee: const boltz.TxFee.relative(1),
            tryCooperate: true,
            btcElectrumSettings: _btc,
            lbtcElectrumSettings: _liquid,
          );
          final txid = await swap.broadcastLocal(
            signedHex: signed,
            kind: boltz.SwapTxKind.claim,
            electrumSettings: fromLiquid ? _btc : _liquid,
          );
          await IntegrationHarness.controller.mine(liquid: !fromLiquid);
          await received(receiver, txid);
        }
        stage = 'cooperative refund';
        var refund = await boltz.BtcLnSwap.newSubmarine(
          swapMasterKey: key,
          index: await store.allocateIndex(),
          invoice: await IntegrationHarness.controller.invoice(),
          network: boltz.Chain.bitcoinRegtest,
          electrumUrl: _btc.url,
          boltzUrl: _url,
        );
        await store.write('swap-${refund.id}', await refund.toJson());
        refund = await boltz.BtcLnSwap.fromJson(
          jsonStr: await store.read('swap-${refund.id}'),
        );
        final sender = await IntegrationHarness.fundedWallet();
        await sendRegtestPayment(sender, refund.scriptAddress, 1000);
        await IntegrationHarness.controller.mine();
        await waitStatus(refund.id, {'transaction.lockupFailed'});
        final receiver = await IntegrationHarness.newWallet();
        final signed = await refund.refund(
          outAddress: await address(receiver),
          minerFee: const boltz.TxFee.relative(1),
          tryCooperate: true,
          electrumSettings: _btc,
        );
        final txid = await refund.broadcastLocal(
          signedHex: signed,
          electrumSettings: _btc,
        );
        await IntegrationHarness.controller.mine();
        await received(receiver, txid, minimum: 1);
      } on boltz.BoltzError catch (error) {
        fail('Boltz regtest failed at $stage: ${error.kind}');
      } catch (error) {
        // Foreign diagnostics can contain private recovery state. Keep them out
        // of test logs; node/status checks provide the public diagnosis.
        fail('Boltz regtest failed at $stage: ${error.runtimeType}');
      }
    },
    skip: IntegrationHarness.isRegtest
        ? null
        : 'Requires the isolated regtest stack',
    timeout: const Timeout(Duration(minutes: 18)),
  );
}
