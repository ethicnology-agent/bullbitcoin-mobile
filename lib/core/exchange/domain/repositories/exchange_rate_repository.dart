import 'package:bb_mobile/core/exchange/domain/entity/exchange_rate.dart';
import 'package:bb_mobile/core/exchange/domain/exchange_rate_failure.dart';
import 'package:meta/meta.dart';
import 'package:primitives/primitives.dart';

abstract interface class ExchangeRateRepository {
  @useResult
  Future<Result<ExchangeRate, ExchangeRateFailure>> getRate(
    String currencyCode,
  );
}
