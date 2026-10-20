import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/price/data/bitcoin_price_repository_impl.dart';
import 'package:bb_mobile/core/price/data/datasources/bullbitcoin_price_datasource.dart';
import 'package:bb_mobile/core/price/domain/price_failure.dart';
import 'package:bb_mobile/core/price/domain/repositories/bitcoin_price_repository.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primitives/primitives.dart';

final _oneBitcoinSat = BigInt.from(100000000);

Map<String, dynamic> _rateBody({Object? indexPrice = 11751892}) => {
  'jsonrpc': '2.0',
  'id': 1,
  'result': {
    'element': {
      'fromCurrency': 'BTC',
      'toCurrency': 'CAD',
      'indexPrice': indexPrice,
      'precision': 2,
    },
  },
};

BitcoinPriceRepository _repository(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://pricer.test'));
  dio.httpClientAdapter = adapter;
  return BitcoinPriceRepositoryImpl(
    bullbitcoinPriceDatasource: BullbitcoinPriceDatasource(
      bullbitcoinApiHttpClient: dio,
    ),
  );
}

void main() {
  group('BitcoinPriceRepositoryImpl', () {
    // These first assertions only name `Err` and `Failure`, which predate this
    // change: on the repository as it was, the same calls resolved to 0.0 and
    // `BigInt.from(infinity)`.
    test('HTTP 429 is a failure, not a value of zero', () async {
      final repository = _repository(
        _StubAdapter(body: 'Too Many Requests', statusCode: 429),
      );

      final value = await repository.getCurrencyValue(
        amountSat: _oneBitcoinSat,
        currency: 'CAD',
      );

      expect(value, isA<Err<double, Failure>>());
    });

    test('a zero rate never becomes a value of zero', () async {
      final repository = _repository(
        _StubAdapter(body: _rateBody(indexPrice: 0)),
      );

      final value = await repository.getCurrencyValue(
        amountSat: _oneBitcoinSat,
        currency: 'CAD',
      );

      expect(value, isA<Err<double, Failure>>());
    });

    test('a zero rate never divides the fiat amount by zero', () async {
      final repository = _repository(
        _StubAdapter(body: _rateBody(indexPrice: 0)),
      );

      final sats = await repository.getSatsValue(
        amountFiat: 100,
        currency: 'CAD',
      );

      expect(sats, isA<Err<BigInt, Failure>>());
    });

    test('HTTP 429 maps to a rate-limited failure with Retry-After', () async {
      final repository = _repository(
        _StubAdapter(
          body: 'Too Many Requests',
          statusCode: 429,
          headers: {
            'retry-after': ['30'],
          },
        ),
      );

      final value = await repository.getCurrencyValue(
        amountSat: _oneBitcoinSat,
        currency: 'CAD',
      );

      expect(
        value,
        isA<Err<double, PriceFailure>>().having(
          (r) => r.failure,
          'failure',
          isA<PriceRateLimitedFailure>().having(
            (f) => f.retryAfter,
            'retryAfter',
            '30',
          ),
        ),
      );
    });

    test('a transport failure maps to unavailable', () async {
      final repository = _repository(_ConnectionErrorAdapter());

      final value = await repository.getCurrencyValue(
        amountSat: _oneBitcoinSat,
        currency: 'CAD',
      );

      expect(
        value,
        isA<Err<double, PriceFailure>>().having(
          (r) => r.failure,
          'failure',
          isA<PriceUnavailableFailure>(),
        ),
      );
    });

    test('a server error status maps to unavailable', () async {
      final repository = _repository(
        _StubAdapter(body: 'Bad Gateway', statusCode: 502),
      );

      final value = await repository.getCurrencyValue(
        amountSat: _oneBitcoinSat,
        currency: 'CAD',
      );

      expect(
        value,
        isA<Err<double, PriceFailure>>().having(
          (r) => r.failure,
          'failure',
          isA<PriceUnavailableFailure>(),
        ),
      );
    });

    test('a malformed body maps to an invalid response', () async {
      final repository = _repository(
        _StubAdapter(body: {'jsonrpc': '2.0', 'id': 1, 'result': null}),
      );

      final value = await repository.getCurrencyValue(
        amountSat: _oneBitcoinSat,
        currency: 'CAD',
      );

      expect(
        value,
        isA<Err<double, PriceFailure>>().having(
          (r) => r.failure,
          'failure',
          isA<PriceInvalidResponseFailure>(),
        ),
      );
    });

    test('a valid rate prices the sats amount', () async {
      final repository = _repository(_StubAdapter(body: _rateBody()));

      final oneBitcoin = await repository.getCurrencyValue(
        amountSat: _oneBitcoinSat,
        currency: 'CAD',
      );
      final halfBitcoin = await repository.getCurrencyValue(
        amountSat: BigInt.from(50000000),
        currency: 'CAD',
      );

      expect(
        oneBitcoin,
        isA<Ok<double, PriceFailure>>().having(
          (r) => r.value,
          'value',
          closeTo(117518.92, 1e-9),
        ),
      );
      expect(
        halfBitcoin,
        isA<Ok<double, PriceFailure>>().having(
          (r) => r.value,
          'value',
          closeTo(58759.46, 1e-9),
        ),
      );
    });

    test('a valid rate converts fiat to sats', () async {
      final repository = _repository(_StubAdapter(body: _rateBody()));

      final sats = await repository.getSatsValue(
        amountFiat: 117518.92,
        currency: 'CAD',
      );

      expect(
        sats,
        isA<Ok<BigInt, PriceFailure>>().having(
          (r) => r.value,
          'value',
          _oneBitcoinSat,
        ),
      );
    });

    test('fiat to fiat in the same currency needs no rate', () async {
      final repository = _repository(_ConnectionErrorAdapter());

      final value = await repository.convertFiatToFiat(
        amount: 42,
        fromCurrency: 'CAD',
        toCurrency: 'CAD',
      );

      expect(
        value,
        isA<Ok<double, PriceFailure>>().having((r) => r.value, 'value', 42),
      );
    });

    test('fiat to fiat propagates the first failed rate', () async {
      final repository = _repository(
        _StubAdapter(body: 'Too Many Requests', statusCode: 429),
      );

      final value = await repository.convertFiatToFiat(
        amount: 42,
        fromCurrency: 'CAD',
        toCurrency: 'USD',
      );

      expect(
        value,
        isA<Err<double, PriceFailure>>().having(
          (r) => r.failure,
          'failure',
          isA<PriceRateLimitedFailure>(),
        ),
      );
    });
  });
}

/// Answers every request with [body] and [statusCode], without a network.
class _StubAdapter implements HttpClientAdapter {
  final Object? body;
  final int statusCode;
  final Map<String, List<String>> headers;

  _StubAdapter({
    required this.body,
    this.statusCode = 200,
    this.headers = const {},
  });

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = this.body;
    return ResponseBody.fromString(
      body is String ? body : jsonEncode(body),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [
          body is String
              ? Headers.textPlainContentType
              : Headers.jsonContentType,
        ],
        ...headers,
      },
    );
  }
}

/// Fails the way an offline device does: a [DioException] with no response.
class _ConnectionErrorAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => throw DioException.connectionError(
    requestOptions: options,
    reason: 'Connection refused',
  );
}
