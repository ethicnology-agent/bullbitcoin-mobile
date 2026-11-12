import 'dart:typed_data';
import 'package:convert/convert.dart';
import 'package:bb_mobile/features/wallet/data/bdk_wallet_datasource.dart';
import 'package:bb_mobile/features/wallet/data/models/wallet_model.dart';
import 'package:bb_mobile/core/wallet/domain/wallet_failure.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet_utxo.dart';
import 'package:bb_mobile/core/fees/domain/fees_entity.dart';
import 'package:bb_mobile/core/transactions/domain/entities/transaction.dart';
import 'package:bb_mobile/core/transactions/domain/transaction_port.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_address_repository.dart';
import 'package:bb_mobile/core/wallet/domain/repositories/wallet_utxo_repository.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bb_mobile/features/wallet/domain/usecases/prepare_bitcoin_send_usecase.dart';
import 'package:bb_mobile/locator.dart';
import 'package:bull_payjoin/bull_payjoin.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primitives/primitives.dart' hide Network, ScriptType;

import 'integration_harness.dart';

Future<PayjoinReceiverSession> _receiver(Wallet wallet) async {
  final address = await locator<WalletAddressRepository>()
      .generateNewReceiveAddress(walletId: wallet.id);
  return switch (await locator<PayjoinReceiver>().start(
    StartPayjoinReceiver(
      walletId: wallet.id,
      network: BitcoinNetwork.regtest,
      address: address.address,
      amount: Sats.fromInt(10000),
      expiresAt: DateTime.now().add(
        PayjoinPolicy.minimumSessionLifetime + const Duration(seconds: 1),
      ),
    ),
  )) {
    Ok(:final value) => value,
    Err(:final failure) => fail(
      'Receiver start failed: ${failure.runtimeType}',
    ),
  };
}

Future<PayjoinSenderSession> _sender(
  Wallet wallet,
  PayjoinReceiverSession receiver, {
  WalletUtxo? input,
}) async {
  final address = Uri.parse(receiver.pjUri).path;
  final prepared = await locator<PrepareBitcoinSendUsecase>().execute(
    walletId: wallet.id,
    recipients: [
      BitcoinTransactionRecipient.fixed(
        address: address,
        amountSat: Sats.fromInt(10000),
      ),
    ],
    networkFee: NetworkFee.relativeFromSatPerVbyte(2),
    selectedInputs: input == null ? null : [input],
  );
  final original = switch (prepared) {
    Ok(:final value) => value,
    Err(:final failure) => fail(
      'Payjoin preparation failed: ${failure.runtimeType}',
    ),
  };
  return switch (await locator<PayjoinSender>().start(
    StartPayjoinSender(
      walletId: wallet.id,
      network: BitcoinNetwork.regtest,
      bip21Uri: receiver.pjUri,
      unsignedOriginalPsbt: original.unsignedPsbt,
      amount: Sats.fromInt(10000),
      expiresAt: DateTime.now().add(
        PayjoinPolicy.minimumSessionLifetime + const Duration(seconds: 1),
      ),
      feeRate: FeeRate(2),
    ),
  )) {
    Ok(:final value) => value,
    Err(:final failure) => fail('Sender start failed: ${failure.runtimeType}'),
  };
}

Future<PayjoinSession> _terminal(String id, {int seconds = 150}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (DateTime.now().isBefore(deadline)) {
    final session = switch (await locator<PayjoinSessions>().byId(id)) {
      Ok(:final value) => value,
      Err(:final failure) => fail(
        'Session lookup failed: ${failure.runtimeType}',
      ),
    };
    if (session == null) fail('A persisted Payjoin session disappeared');
    if (!session.isOngoing) return session;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail('Payjoin did not reach a terminal state');
}

Future<Transaction> _confirmed(PayjoinSession session) async {
  expect(session.status, PayjoinStatus.completed);
  expect(session.transactionId, isNotNull);
  expect(session.transactionId == session.originalTransactionId, isFalse);
  expect(
    session.ownership?.inputs,
    containsAll([PayjoinParty.sender, PayjoinParty.recipient]),
  );
  return _confirmedTransaction(switch (session.transactionId) {
    final String id => id,
    _ => fail('Missing negotiated txid'),
  }, session.walletId);
}

Future<Transaction> _confirmedTransaction(String txid, String walletId) async {
  await IntegrationHarness.controller.mine();
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  while (DateTime.now().isBefore(deadline)) {
    final read = await locator<WalletRepository>().getWallet(
      walletId,
      sync: true,
    );
    if (read case Err(:final failure)) {
      fail('Wallet synchronization failed: ${failure.runtimeType}');
    }
    final coins = await locator<WalletUtxoRepository>().getWalletUtxos(
      walletId: walletId,
    );
    if (coins.any((coin) => coin.txId == txid && coin.isConfirmed)) {
      return locator<TransactionPort>().fetch(txid: txid);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  fail('The app did not observe its confirmed negotiated payment');
}

Set<Outpoint> _inputs(Transaction transaction) => transaction.inputs
    .map((input) => (txId: input.previousTxId, vout: input.previousVout))
    .toSet();

void registerRegtestPayjoinScenarios() {
  test(
    'a negotiated payment credits the receiver with explicit fee accounting',
    () async {
      final sender = await IntegrationHarness.fundedWallet();
      final receiver = await IntegrationHarness.fundedWallet();
      final coins = locator<WalletUtxoRepository>();
      final senderCoins = await coins.getWalletUtxos(walletId: sender.id);
      final receiverCoins = await coins.getWalletUtxos(walletId: receiver.id);
      final request = await _receiver(receiver);
      final started = await _sender(sender, request);
      final completed = await _terminal(started.id);
      final transaction = await _confirmed(completed);
      final txid = switch (completed.transactionId) {
        final String value => value,
        _ => fail('Missing negotiated transaction'),
      };
      await _confirmedTransaction(txid, receiver.id);
      final inputPoints = _inputs(transaction);
      final senderPoints = senderCoins.map((c) => c.outpoint).toSet();
      final receiverPoints = receiverCoins.map((c) => c.outpoint).toSet();
      expect(inputPoints.intersection(senderPoints), isNotEmpty);
      expect(inputPoints.intersection(receiverPoints), isNotEmpty);
      expect(
        inputPoints.difference(senderPoints.union(receiverPoints)),
        isEmpty,
      );
      final inputValues = {
        for (final coin in [...senderCoins, ...receiverCoins])
          coin.outpoint: coin.amountSat.toInt(),
      };
      var totalIn = 0;
      var receiverIn = 0;
      for (final input in inputPoints) {
        final value = inputValues[input];
        if (value == null) fail('Negotiation used an unknown input');
        totalIn += value;
        if (receiverPoints.contains(input)) receiverIn += value;
      }
      final owns = await locator<BdkWalletDatasource>().createIsMineChecker(
        wallet: WalletModel.publicBdk(
          id: receiver.id,
          network: receiver.network,
          externalDescriptor: receiver.externalPublicDescriptor,
          internalDescriptor: receiver.internalPublicDescriptor,
        ),
      );
      var receiverOut = 0;
      for (final output in transaction.outputs) {
        if (owns(Uint8List.fromList(hex.decode(output.scriptPubKeyHex)))) {
          receiverOut += output.valueSat;
        }
      }
      final totalFee = totalIn - transaction.totalOutputsSat;
      final receiverFee = receiverIn + 10000 - receiverOut;
      expect(totalFee, greaterThanOrEqualTo(0));
      expect(receiverFee, inInclusiveRange(0, totalFee));
      expect(completed.amount?.value, BigInt.from(10000));
      final read = await locator<WalletRepository>().getWallet(
        receiver.id,
        sync: true,
      );
      final refreshed = switch (read) {
        Ok(:final value) => value,
        Err(:final failure) => fail(
          'Receiver read failed: ${failure.runtimeType}',
        ),
      };
      expect(refreshed.balanceSat, switch (receiver.balanceSat) {
        final BigInt before => before + BigInt.from(10000 - receiverFee),
        _ => fail('Missing initial receiver balance'),
      });
      final receiverSession = switch (await locator<PayjoinSessions>().byId(
        request.id,
      )) {
        Ok(:final value) => value,
        Err(:final failure) => fail(
          'Receiver session failed: ${failure.runtimeType}',
        ),
      };
      expect(receiverSession?.transactionId, txid);
      expect(receiverSession?.status, PayjoinStatus.completed);
      final reserved = switch (await locator<PayjoinSessions>()
          .reservedOutpoints()) {
        Ok(:final value) => value,
        Err(:final failure) => fail(
          'Reservation lookup failed: ${failure.runtimeType}',
        ),
      };
      expect(reserved.intersection(inputPoints), isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('an unfunded sender is refused before session creation', () async {
    final sender = await IntegrationHarness.newWallet();
    final receiver = await IntegrationHarness.fundedWallet();
    final address = await locator<WalletAddressRepository>()
        .generateNewReceiveAddress(walletId: receiver.id);
    final result = await locator<PrepareBitcoinSendUsecase>().execute(
      walletId: sender.id,
      recipients: [
        BitcoinTransactionRecipient.fixed(
          address: address.address,
          amountSat: Sats.fromInt(10000),
        ),
      ],
      networkFee: NetworkFee.relativeFromSatPerVbyte(2),
    );
    expect(
      result,
      isA<Err>().having(
        (r) => r.failure,
        'failure',
        isA<WalletNoSpendableInputsFailure>(),
      ),
    );
    final sessions = switch (await locator<PayjoinSessions>().list(
      PayjoinSessionFilter(walletId: sender.id),
    )) {
      Ok(:final value) => value,
      Err(:final failure) => fail(
        'Session lookup failed: ${failure.runtimeType}',
      ),
    };
    expect(sessions, isEmpty);
    expect(
      await locator<WalletUtxoRepository>().getWalletUtxos(walletId: sender.id),
      isEmpty,
    );
  });

  test(
    'an unfunded receiver never contributes funds to a negotiated transaction',
    () async {
      final sender = await IntegrationHarness.fundedWallet();
      final receiver = await IntegrationHarness.newWallet();
      final originalCoins = await locator<WalletUtxoRepository>()
          .getWalletUtxos(walletId: sender.id);
      final allowedInputs = originalCoins.map((coin) => coin.outpoint).toSet();
      final request = await _receiver(receiver);
      final session = await _sender(sender, request);
      final outcome = await _terminal(session.id, seconds: 260);
      expect(
        outcome.status,
        isIn([PayjoinStatus.aborted, PayjoinStatus.expired]),
      );
      expect(outcome.hasProposal, isFalse);
      expect(outcome.transactionId, isNull);
      if (outcome.status == PayjoinStatus.aborted) {
        final transaction = await _confirmedTransaction(
          switch (outcome.originalTransactionId) {
            final String id => id,
            _ => fail('Fallback lost its original txid'),
          },
          receiver.id,
        );
        expect(_inputs(transaction).difference(allowedInputs), isEmpty);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'concurrent Payjoins spend distinct sender and receiver outpoints',
    () async {
      final sender = await IntegrationHarness.fundedWallet();
      final receiver = await IntegrationHarness.fundedWallet();
      final receiverCoins = await locator<WalletUtxoRepository>()
          .getWalletUtxos(walletId: receiver.id);
      final receiverInputs = receiverCoins.map((coin) => coin.outpoint).toSet();
      final senderCoins = await locator<WalletUtxoRepository>().getWalletUtxos(
        walletId: sender.id,
      );
      expect(senderCoins.length, greaterThanOrEqualTo(2));
      final requests = [await _receiver(receiver), await _receiver(receiver)];
      final senders = [
        await _sender(sender, requests[0], input: senderCoins[0]),
        await _sender(sender, requests[1], input: senderCoins[1]),
      ];
      final finished = await Future.wait(
        senders.map((session) => _terminal(session.id)),
      );
      final transactions = <Transaction>[];
      for (final session in finished) {
        transactions.add(await _confirmed(session));
      }
      expect(transactions[0].txid, isNot(transactions[1].txid));
      final first = _inputs(transactions[0]);
      final second = _inputs(transactions[1]);
      expect(first.intersection(second), isEmpty);
      expect(first.intersection(receiverInputs), isNotEmpty);
      expect(second.intersection(receiverInputs), isNotEmpty);
      final reserved = await locator<PayjoinSessions>().reservedOutpoints();
      switch (reserved) {
        case Ok(:final value):
          expect(value.intersection(first.union(second)), isEmpty);
        case Err(:final failure):
          fail('Reservation lookup failed: ${failure.runtimeType}');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // Keep this last: it replaces the package roles, preserving the existing
  // wallet and custody capabilities while reopening the real session DB.
  test(
    'an active receiver resumes after reopening the Payjoin runtime and database',
    () async {
      final sender = await IntegrationHarness.fundedWallet();
      final receiver = await IntegrationHarness.fundedWallet();
      final request = await _receiver(receiver);
      await IntegrationHarness.reopenPayjoin();
      final restored = await locator<PayjoinSessions>().byId(request.id);
      switch (restored) {
        case Ok(:final value):
          expect(value?.id, request.id);
          expect(value?.network, BitcoinNetwork.regtest);
          expect(value?.isOngoing, isTrue);
        case Err(:final failure):
          fail('Restored session lookup failed: ${failure.runtimeType}');
      }
      final session = await _sender(sender, request);
      await _confirmed(await _terminal(session.id));
      final receivers = await locator<PayjoinSessions>().list(
        PayjoinSessionFilter(walletId: receiver.id),
      );
      switch (receivers) {
        case Ok(:final value):
          expect(
            value.where((session) => session.id == request.id),
            hasLength(1),
          );
        case Err(:final failure):
          fail('Restored session listing failed: ${failure.runtimeType}');
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
