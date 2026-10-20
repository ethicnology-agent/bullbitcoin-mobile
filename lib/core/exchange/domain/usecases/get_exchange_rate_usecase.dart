import 'package:bb_mobile/core/exchange/domain/entity/exchange_rate.dart';
import 'package:bb_mobile/core/exchange/domain/exchange_rate_failure.dart';
import 'package:bb_mobile/core/exchange/domain/repositories/exchange_rate_repository.dart';
import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart';
import 'package:meta/meta.dart';
import 'package:primitives/primitives.dart';

class GetExchangeRateUsecase {
  final ExchangeRateRepository _mainnetRepository;
  final ExchangeRateRepository _testnetRepository;
  final SettingsRepository _settingsRepository;

  const GetExchangeRateUsecase({
    required this._mainnetRepository,
    required this._testnetRepository,
    required this._settingsRepository,
  });

  @useResult
  Future<Result<ExchangeRate, ExchangeRateFailure>> execute({
    String? currencyCode,
  }) async {
    try {
      final settings = await _settingsRepository.fetch();
      final repository = settings.environment.isTestnet
          ? _testnetRepository
          : _mainnetRepository;
      return repository.getRate(currencyCode ?? settings.currencyCode);
    } on Exception {
      return const Err(
        ExchangeRateUnavailableFailure('Could not read price settings'),
      );
    }
  }
}
