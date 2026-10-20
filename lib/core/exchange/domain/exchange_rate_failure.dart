import 'package:primitives/primitives.dart';

sealed class ExchangeRateFailure extends Failure {
  const ExchangeRateFailure([super.logMessage]);
}

final class ExchangeRateUnavailableFailure extends ExchangeRateFailure {
  const ExchangeRateUnavailableFailure([super.logMessage]);
}

final class ExchangeRateUnauthenticatedFailure extends ExchangeRateFailure {
  const ExchangeRateUnauthenticatedFailure();
}

final class ExchangeRateLimitedFailure extends ExchangeRateFailure {
  final String? retryAfter;

  const ExchangeRateLimitedFailure({this.retryAfter});
}

final class ExchangeRateInvalidResponseFailure extends ExchangeRateFailure {
  const ExchangeRateInvalidResponseFailure();
}
