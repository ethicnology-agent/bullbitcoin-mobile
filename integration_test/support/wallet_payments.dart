import 'package:primitives/primitives.dart'
    show BitcoinTransactionRecipient, Sats, Ok, Err;

import 'package:bb_mobile/core/fees/domain/fees_entity.dart';
import 'package:bb_mobile/features/send/domain/usecases/broadcast_bitcoin_transaction_usecase.dart';
import 'package:bb_mobile/features/send/domain/usecases/broadcast_liquid_transaction_usecase.dart';
import 'package:bb_mobile/features/send/domain/usecases/prepare_liquid_send_usecase.dart';
import 'package:bb_mobile/features/send/domain/usecases/sign_bitcoin_tx_usecase.dart';
import 'package:bb_mobile/features/send/domain/usecases/sign_liquid_tx_usecase.dart';
import 'package:bb_mobile/features/wallet/domain/usecases/prepare_bitcoin_send_usecase.dart';
import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bb_mobile/locator.dart';

Future<String> sendRegtestPayment(
  Wallet wallet,
  String address,
  int amountSat,
) async {
  if (wallet.network != Network.bitcoinRegtest &&
      wallet.network != Network.liquidRegtest) {
    throw StateError(
      'Regtest wallet payment requires a concrete regtest wallet',
    );
  }
  if (wallet.network == Network.liquidRegtest) {
    final preparation = await locator<PrepareLiquidSendUsecase>().execute(
      walletId: wallet.id,
      address: address,
      amountSat: amountSat,
      feeRate: NetworkFee.relativeFromSatPerVbyte(0.1),
    );
    final unsigned = switch (preparation) {
      Ok(:final value) => value,
      Err(:final failure) => throw StateError(
        'Liquid preparation failed: ${failure.runtimeType}',
      ),
    };
    final signed = await locator<SignLiquidTxUsecase>().execute(
      pset: unsigned,
      walletId: wallet.id,
    );
    return locator<BroadcastLiquidTransactionUsecase>().execute(
      signed,
      network: wallet.network,
    );
  }
  final preparation = await locator<PrepareBitcoinSendUsecase>().execute(
    walletId: wallet.id,
    recipients: [
      BitcoinTransactionRecipient.fixed(
        address: address,
        amountSat: Sats.fromInt(amountSat),
      ),
    ],
    networkFee: NetworkFee.relativeFromSatPerVbyte(2),
  );
  final unsigned = switch (preparation) {
    Ok(:final value) => value,
    Err(:final failure) => throw StateError(
      'Bitcoin preparation failed: ${failure.runtimeType}',
    ),
  };
  final signed = await locator<SignBitcoinTxUsecase>().execute(
    psbt: unsigned.unsignedPsbt,
    walletId: wallet.id,
  );
  return locator<BroadcastBitcoinTransactionUsecase>().execute(
    signed.signedPsbt,
    isPsbt: true,
    network: wallet.network,
  );
}
