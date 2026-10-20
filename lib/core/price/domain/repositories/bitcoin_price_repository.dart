import 'package:bb_mobile/core/price/domain/price_failure.dart';
import 'package:bb_mobile/core/utils/result.dart';
import 'package:meta/meta.dart';

abstract interface class BitcoinPriceRepository {
  Future<List<String>> get availableCurrencies;

  /// The value of [amountSat] in [currency]. Never `Ok(0)` for a failed read:
  /// a pricer that is unreachable, rate limited or answering nonsense is an
  /// [Err].
  @useResult
  Future<Result<double, PriceFailure>> getCurrencyValue({
    required BigInt amountSat,
    required String currency,
  });

  /// The sats [amountFiat] in [currency] buys at the current rate.
  @useResult
  Future<Result<BigInt, PriceFailure>> getSatsValue({
    required double amountFiat,
    required String currency,
  });

  /// Convert an amount from one fiat currency to another using BTC as intermediary.
  /// Returns the converted amount in the target currency.
  @useResult
  Future<Result<double, PriceFailure>> convertFiatToFiat({
    required double amount,
    required String fromCurrency,
    required String toCurrency,
  });
}
