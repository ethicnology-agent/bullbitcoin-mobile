import 'package:bb_mobile/core/errors/exchange_errors.dart';
import 'package:bb_mobile/core/exchange/data/datasources/bullbitcoin_api_datasource.dart';
import 'package:bb_mobile/core/exchange/data/mappers/exchange_rate_mapper.dart';
import 'package:bb_mobile/core/exchange/domain/entity/exchange_rate.dart';
import 'package:bb_mobile/core/exchange/domain/exchange_rate_failure.dart';
import 'package:bb_mobile/core/exchange/domain/repositories/exchange_rate_repository.dart';
import 'package:bull_logger/bull_logger.dart';
import 'package:dio/dio.dart';
import 'package:primitives/primitives.dart';

final class ExchangeRateRepositoryImpl implements ExchangeRateRepository {
  final BullbitcoinApiDatasource _datasource;

  const ExchangeRateRepositoryImpl(this._datasource);

  @override
  Future<Result<ExchangeRate, ExchangeRateFailure>> getRate(
    String currencyCode,
  ) async {
    try {
      final model = await _datasource.getUserRate(currencyCode.toUpperCase());
      return Ok(
        ExchangeRateMapper.toEntity(model, expectedCurrency: currencyCode),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      log.warning(
        'Exchange rate request failed: kind=${error.type.name}, status=$status',
      );
      if (status == 429) {
        return Err(
          ExchangeRateLimitedFailure(
            retryAfter: error.response?.headers.value('retry-after'),
          ),
        );
      }
      if (status == 401 || status == 403 || error.error is ApiKeyException) {
        return const Err(ExchangeRateUnauthenticatedFailure());
      }
      return const Err(ExchangeRateUnavailableFailure());
    } on FormatException {
      log.warning('Exchange rate response invalid');
      return const Err(ExchangeRateInvalidResponseFailure());
    } on Exception catch (error) {
      log.warning('Exchange rate unavailable: cause=${error.runtimeType}');
      return const Err(ExchangeRateUnavailableFailure());
    }
  }
}
