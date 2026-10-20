import 'dart:math' show pow;

import 'package:bb_mobile/core/price/data/models/rate_history_request_model.dart';
import 'package:bb_mobile/core/price/data/models/rate_model.dart';
import 'package:bb_mobile/core/price/data/models/rate_request_model.dart';
import 'package:bb_mobile/core/price/domain/rate.dart';
import 'package:bb_mobile/core/utils/constants.dart';
import 'package:dio/dio.dart';

/// Thrown by [BullbitcoinPriceDatasource.getPrice] when no usable rate came
/// back. Caught by the price repository, which maps each case to a
/// `PriceFailure`; nothing above the repository sees these.
sealed class PriceException implements Exception {
  final String message;

  const PriceException(this.message);

  @override
  String toString() => 'PriceException: $message';
}

/// HTTP 429. [retryAfter] is the raw `Retry-After` header, if any.
final class PriceRateLimitedException extends PriceException {
  final String? retryAfter;

  const PriceRateLimitedException({this.retryAfter})
    : super('Pricer rate limited (429)');
}

/// Any other non-200 status.
final class PriceHttpException extends PriceException {
  final int? statusCode;

  const PriceHttpException(this.statusCode)
    : super('Pricer answered with status $statusCode');
}

/// No HTTP answer at all: connection, timeout, TLS, cancellation.
final class PriceTransportException extends PriceException {
  const PriceTransportException(super.message);
}

/// A 200 whose JSON-RPC envelope carries an `error` instead of a result.
final class PriceRpcErrorException extends PriceException {
  final String? code;

  const PriceRpcErrorException(this.code)
    : super('Pricer returned a JSON-RPC error: $code');
}

/// A 200 whose body does not describe a finite positive rate.
final class PriceInvalidResponseException extends PriceException {
  const PriceInvalidResponseException(super.message);
}

class BullbitcoinPriceDatasource {
  final Dio _http;
  final _pricePath = '/public/price';

  BullbitcoinPriceDatasource({required Dio bullbitcoinApiHttpClient})
    : _http = bullbitcoinApiHttpClient;

  Future<List<String>> get availableCurrencies async {
    // TODO: fetch the actual list of currencies from the api
    return CurrencyConstants.supportedFiat;
  }

  /// The price of one bitcoin in [currencyCode], always a finite positive
  /// number.
  ///
  /// Throws a [PriceException] otherwise. A rate of zero used to stand in for
  /// every failure here, so a rate-limited pricer (#3011) showed up as a
  /// price of 0 rather than as an error the caller could act on.
  Future<double> getPrice(String currencyCode) async {
    final requestModel = RateRequestModel(
      fromCurrency: 'BTC',
      toCurrency: currencyCode.toUpperCase(),
    );

    final Response<dynamic> resp;
    try {
      resp = await _http.post(
        _pricePath,
        data: {
          'id': 1,
          'jsonrpc': '2.0',
          'method': 'getRate',
          'params': requestModel.toApiParams(),
        },
      );
    } on DioException catch (e) {
      final response = e.response;
      if (response != null) throw _statusException(response);
      // Dio wraps a body it could not decode the same way as a lost
      // connection; only the former is the pricer's fault.
      if (e.error is FormatException) {
        throw PriceInvalidResponseException('Body is not valid JSON');
      }
      throw PriceTransportException('Transport failure: ${e.type.name}');
    }

    final statusCode = resp.statusCode;
    if (statusCode != 200) throw _statusException(resp);

    final data = resp.data;
    if (data is! Map<String, dynamic>) {
      throw const PriceInvalidResponseException('Body is not a JSON object');
    }
    final error = data['error'];
    if (error != null) {
      throw PriceRpcErrorException(_rpcErrorCode(error));
    }
    final result = data['result'];
    final element = result is Map<String, dynamic> ? result['element'] : null;
    if (element is! Map<String, dynamic>) {
      throw const PriceInvalidResponseException('Missing result.element');
    }

    final indexPrice = element['indexPrice'];
    if (indexPrice is! num) {
      throw const PriceInvalidResponseException('Missing indexPrice');
    }
    final precision = switch (element['precision']) {
      null => 2,
      final int value when value >= 0 => value,
      _ => throw const PriceInvalidResponseException(
        'precision is not a non-negative int',
      ),
    };

    // The API sends the price as an integer scaled by `precision`:
    // 11751892 with precision 2 is 117518.92. Scaled in doubles: an int
    // power wraps past 2^63 instead of overflowing to infinity.
    final rate = indexPrice.toDouble() / pow(10.0, precision);
    if (!rate.isFinite || rate <= 0) {
      throw PriceInvalidResponseException('Rate is not positive: $rate');
    }
    return rate;
  }

  /// A non-200 answer: 429 is its own case so the caller can back off.
  static PriceException _statusException(Response<dynamic> response) {
    final statusCode = response.statusCode;
    if (statusCode == 429) {
      return PriceRateLimitedException(
        retryAfter: response.headers.value('retry-after'),
      );
    }
    return PriceHttpException(statusCode);
  }

  static String? _rpcErrorCode(Object error) {
    if (error is! Map<String, dynamic>) return null;
    final data = error['data'];
    final code = data is Map<String, dynamic> ? data['code'] : error['code'];
    return switch (code) {
      int value => value.toString(),
      String value when RegExp(r'^[A-Z][A-Z0-9_]{0,63}$').hasMatch(value) =>
        value,
      _ => null,
    };
  }

  Future<List<RateModel>> getPriceHistory({
    required String fromCurrency,
    required String toCurrency,
    required RateTimelineInterval interval,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    try {
      final requestModel = RateHistoryRequestModel(
        fromCurrency: fromCurrency,
        toCurrency: toCurrency,
        interval: interval.value,
        fromDate: fromDate,
        toDate: toDate,
      );

      final requestParams = requestModel.toApiParams();

      final resp = await _http.post(
        _pricePath,
        data: {
          'id': 1,
          'jsonrpc': '2.0',
          'method': 'getIndexRateHistory',
          'params': requestParams,
        },
      );

      if (resp.statusCode == null ||
          resp.statusCode == null ||
          resp.statusCode != 200) {
        return [];
      }

      final data = resp.data as Map<String, dynamic>;

      if (data.containsKey('error')) {
        return [];
      }

      final result = data['result'] as Map<String, dynamic>?;
      if (result == null) {
        return [];
      }

      final element = result['element'] as Map<String, dynamic>?;
      if (element == null) {
        return [];
      }

      final intervalStr = element['interval'] as String? ?? 'week';
      final precision = element['precision'] as int? ?? 2;
      final fromCurrencyValue =
          element['fromCurrency'] as String? ?? fromCurrency;
      final toCurrencyValue = element['toCurrency'] as String? ?? toCurrency;

      final ratesList = element['rates'] as List<dynamic>?;
      if (ratesList == null || ratesList.isEmpty) {
        return [];
      }

      final precisionDivisor = pow(10, precision).toDouble();

      final models = <RateModel>[];
      for (var i = 0; i < ratesList.length; i++) {
        try {
          final rateItem = ratesList[i];
          final rateData = rateItem as Map<String, dynamic>;

          final periodStart = rateData['periodStart'] as String?;
          final createdAt = rateData['createdAt'] as String?;
          final dateStr = periodStart ?? createdAt;

          if (dateStr == null) {
            continue;
          }

          final indexPriceValue = rateData['indexPrice'];
          final indexPriceInt = indexPriceValue is int ? indexPriceValue : null;
          final indexPriceDouble = indexPriceValue is double
              ? indexPriceValue
              : null;
          final indexPrice = indexPriceInt != null
              ? indexPriceInt / precisionDivisor
              : indexPriceDouble;

          final model = RateModel(
            fromCurrency: fromCurrencyValue,
            toCurrency: toCurrencyValue,
            interval: intervalStr,
            createdAt: dateStr,
            marketPrice: null,
            price: null,
            priceCurrency: null,
            precision: precision,
            indexPrice: indexPrice,
            userPrice: null,
          );

          models.add(model);
        } catch (e) {
          continue;
        }
      }

      return models;
    } catch (e) {
      return [];
    }
  }
}
