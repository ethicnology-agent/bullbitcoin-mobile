import 'package:bb_mobile/core/failures/failure.dart';

/// Why a rate could not be obtained from the pricer.
///
/// A rate is either a finite, positive number or one of these: the repository
/// never hands out a zero or a sentinel in place of a price (#3011).
sealed class PriceFailure extends Failure {
  const PriceFailure([super.logMessage]);
}

/// The pricer refused the request with HTTP 429.
///
/// [retryAfter] is the raw `Retry-After` header when the server sent one,
/// left unparsed: the header may be a delay in seconds or an HTTP date, and
/// no caller interprets it yet.
final class PriceRateLimitedFailure extends PriceFailure {
  final String? retryAfter;

  const PriceRateLimitedFailure({this.retryAfter, String? logMessage})
    : super(logMessage);
}

/// The pricer could not be reached or answered with an error status other
/// than 429: transport failure, timeout, server error, or a JSON-RPC error.
final class PriceUnavailableFailure extends PriceFailure {
  const PriceUnavailableFailure([super.logMessage]);
}

/// The pricer answered, but not with a usable rate: a body of the wrong
/// shape, or a rate that is not a finite positive number.
final class PriceInvalidResponseFailure extends PriceFailure {
  const PriceInvalidResponseFailure([super.logMessage]);
}
