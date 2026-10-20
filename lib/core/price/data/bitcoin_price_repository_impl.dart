import 'package:bb_mobile/core/price/data/datasources/bullbitcoin_price_datasource.dart';
import 'package:bb_mobile/core/price/domain/price_failure.dart';
import 'package:bb_mobile/core/price/domain/repositories/bitcoin_price_repository.dart';
import 'package:bb_mobile/core/utils/result.dart';
import 'package:bull_logger/bull_logger.dart' show log;

class BitcoinPriceRepositoryImpl implements BitcoinPriceRepository {
  final BullbitcoinPriceDatasource _bullbitcoinPrice;

  BitcoinPriceRepositoryImpl({
    required BullbitcoinPriceDatasource bullbitcoinPriceDatasource,
  }) : _bullbitcoinPrice = bullbitcoinPriceDatasource;

  @override
  Future<List<String>> get availableCurrencies =>
      _bullbitcoinPrice.availableCurrencies;

  @override
  Future<Result<double, PriceFailure>> getCurrencyValue({
    required BigInt amountSat,
    required String currency,
  }) async {
    final price = await _price(currency);
    return price.map((price) {
      final amountBtc = amountSat / BigInt.from(100000000);
      return amountBtc * price;
    });
  }

  @override
  Future<Result<BigInt, PriceFailure>> getSatsValue({
    required double amountFiat,
    required String currency,
  }) async {
    final price = await _price(currency);
    // The datasource only yields finite positive rates, so the division is
    // defined and the result fits a BigInt.
    return price.map((price) {
      final amountBtc = amountFiat / price;
      return BigInt.from((amountBtc * 100000000).truncate());
    });
  }

  // NOTE: not used anywhere as of now
  @override
  Future<Result<double, PriceFailure>> convertFiatToFiat({
    required double amount,
    required String fromCurrency,
    required String toCurrency,
  }) async {
    // No conversion needed if same currency
    if (fromCurrency == toCurrency) return Ok(amount);

    // Skip API calls for zero amounts
    if (amount == 0) return const Ok(0);

    // Get BTC prices in both currencies
    final double btcInFrom;
    switch (await _price(fromCurrency)) {
      case Ok(:final value):
        btcInFrom = value;
      case Err(:final failure):
        return Err(failure);
    }
    final double btcInTo;
    switch (await _price(toCurrency)) {
      case Ok(:final value):
        btcInTo = value;
      case Err(:final failure):
        return Err(failure);
    }

    // Convert: targetValue = sourceValue * (btcPriceInTarget / btcPriceInSource)
    return Ok(amount * (btcInTo / btcInFrom));
  }

  /// The one boundary where the pricer's exceptions become failures.
  Future<Result<double, PriceFailure>> _price(String currency) async {
    try {
      return Ok(await _bullbitcoinPrice.getPrice(currency));
    } on PriceException catch (e) {
      // The reason is logged here, once, where it is known; callers only see
      // the typed failure.
      log.warning('Pricer failed for $currency', error: e);
      return Err(_toFailure(e));
    }
  }

  static PriceFailure _toFailure(PriceException e) => switch (e) {
    PriceRateLimitedException(:final retryAfter) => PriceRateLimitedFailure(
      retryAfter: retryAfter,
      logMessage: e.message,
    ),
    PriceHttpException() ||
    PriceTransportException() ||
    PriceRpcErrorException() => PriceUnavailableFailure(e.message),
    PriceInvalidResponseException() => PriceInvalidResponseFailure(e.message),
  };
}
