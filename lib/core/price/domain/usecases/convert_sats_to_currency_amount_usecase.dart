import 'package:bb_mobile/core/errors/bull_exception.dart';
import 'package:bb_mobile/core/price/domain/price_failure.dart';
import 'package:bb_mobile/core/price/domain/price_unavailable_exception.dart';
import 'package:bb_mobile/core/price/domain/repositories/bitcoin_price_repository.dart';
import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:bb_mobile/core/utils/result.dart';

class ConvertSatsToCurrencyAmountUsecase {
  final BitcoinPriceRepository _mainnetBitcoinPriceRepository;
  final BitcoinPriceRepository _testnetBitcoinPriceRepository;
  final SettingsRepository _settingsRepository;

  ConvertSatsToCurrencyAmountUsecase({
    required this._mainnetBitcoinPriceRepository,
    required this._testnetBitcoinPriceRepository,
    required this._settingsRepository,
  });

  /// Throws [PriceUnavailableException] when the pricer gives no usable rate
  /// and [ConvertSatsToCurrencyAmountException] for anything else. A
  /// failed read never comes back as 0.
  Future<double> execute({BigInt? amountSat, String? currencyCode}) async {
    final Result<double, PriceFailure> converted;
    try {
      final settings = await _settingsRepository.fetch();
      final currency = currencyCode ?? settings.currencyCode;
      final isTestnet = settings.environment.isTestnet;
      final repo = isTestnet
          ? _testnetBitcoinPriceRepository
          : _mainnetBitcoinPriceRepository;
      final availableCurrencies = await repo.availableCurrencies;

      if (!availableCurrencies.contains(currency)) {
        throw ConvertSatsToCurrencyAmountException('Currency not available');
      }

      // If no amount is specified, return the price of one Bitcoin
      converted = await repo.getCurrencyValue(
        amountSat: amountSat ?? ConversionConstants.satsAmountOfOneBitcoin,
        currency: currency,
      );
    } catch (e) {
      throw ConvertSatsToCurrencyAmountException(e.toString());
    }
    return switch (converted) {
      Ok(:final value) => value,
      Err(:final failure) => throw PriceUnavailableException(failure),
    };
  }
}

class ConvertSatsToCurrencyAmountException extends BullException {
  ConvertSatsToCurrencyAmountException(super.message);
}
