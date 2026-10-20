import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/price/data/datasources/bullbitcoin_price_datasource.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rate the API sends: an integer scaled by `precision`.
Map<String, dynamic> _rateBody({
  Object? indexPrice = 11751892,
  Object? precision = 2,
}) => {
  'jsonrpc': '2.0',
  'id': 1,
  'result': {
    'element': {
      'fromCurrency': 'BTC',
      'toCurrency': 'CAD',
      'indexPrice': indexPrice,
      'precision': ?precision,
    },
  },
};

BullbitcoinPriceDatasource _datasource(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://pricer.test'));
  dio.httpClientAdapter = adapter;
  return BullbitcoinPriceDatasource(bullbitcoinApiHttpClient: dio);
}

void main() {
  group('BullbitcoinPriceDatasource.getPrice', () {
    test('a valid answer is the scaled index price', () async {
      final datasource = _datasource(_StubAdapter(body: _rateBody()));

      expect(await datasource.getPrice('cad'), closeTo(117518.92, 1e-9));
    });

    test('precision defaults to two decimals when absent', () async {
      final datasource = _datasource(
        _StubAdapter(body: _rateBody(precision: null)),
      );

      expect(await datasource.getPrice('CAD'), closeTo(117518.92, 1e-9));
    });

    // Before #3011 every failure below came back as a price of 0.0, which
    // the callers then displayed and divided by. These first assertions name
    // no new type on purpose: they are red on that behaviour as it was.
    test('HTTP 429 is an error, never a price of zero', () async {
      final datasource = _datasource(
        _StubAdapter(body: 'Too Many Requests', statusCode: 429),
      );

      await expectLater(datasource.getPrice('CAD'), throwsA(isA<Exception>()));
    });

    test('a transport failure is an error, never a price of zero', () async {
      final datasource = _datasource(_ConnectionErrorAdapter());

      await expectLater(datasource.getPrice('CAD'), throwsA(isA<Exception>()));
    });

    test('a zero index price is an error, never a price of zero', () async {
      final datasource = _datasource(
        _StubAdapter(body: _rateBody(indexPrice: 0)),
      );

      await expectLater(datasource.getPrice('CAD'), throwsA(isA<Exception>()));
    });

    test('HTTP 429 carries the raw Retry-After header', () async {
      final datasource = _datasource(
        _StubAdapter(
          body: 'Too Many Requests',
          statusCode: 429,
          headers: {
            'retry-after': ['30'],
          },
        ),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(
          isA<PriceRateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            '30',
          ),
        ),
      );
    });

    test('HTTP 429 without Retry-After leaves it null', () async {
      final datasource = _datasource(
        _StubAdapter(body: 'Too Many Requests', statusCode: 429),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(
          isA<PriceRateLimitedException>().having(
            (e) => e.retryAfter,
            'retryAfter',
            isNull,
          ),
        ),
      );
    });

    test('another error status keeps its status code', () async {
      final datasource = _datasource(
        _StubAdapter(body: 'Bad Gateway', statusCode: 502),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(
          isA<PriceHttpException>().having(
            (e) => e.statusCode,
            'statusCode',
            502,
          ),
        ),
      );
    });

    test('no HTTP answer at all is a transport error', () async {
      final datasource = _datasource(_ConnectionErrorAdapter());

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceTransportException>()),
      );
    });

    test('a JSON-RPC error envelope carries its code', () async {
      final datasource = _datasource(
        _StubAdapter(
          body: {
            'jsonrpc': '2.0',
            'id': 1,
            'error': {
              'code': -32000,
              'message': 'Internal error',
              'data': {'code': 'ERR_RATE_404'},
            },
          },
        ),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(
          isA<PriceRpcErrorException>().having(
            (e) => e.code,
            'code',
            'ERR_RATE_404',
          ),
        ),
      );
    });

    test('a body that is not a JSON object is an invalid response', () async {
      final datasource = _datasource(_StubAdapter(body: 'not json'));

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceInvalidResponseException>()),
      );
    });

    test('a result without an element is an invalid response', () async {
      final datasource = _datasource(
        _StubAdapter(
          body: {'jsonrpc': '2.0', 'id': 1, 'result': <String, dynamic>{}},
        ),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceInvalidResponseException>()),
      );
    });

    test('a non-numeric index price is an invalid response', () async {
      final datasource = _datasource(
        _StubAdapter(body: _rateBody(indexPrice: '11751892')),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceInvalidResponseException>()),
      );
    });

    test('a non-integer precision is an invalid response', () async {
      final datasource = _datasource(
        _StubAdapter(body: _rateBody(precision: '2')),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceInvalidResponseException>()),
      );
    });

    test('a negative index price is an invalid response', () async {
      final datasource = _datasource(
        _StubAdapter(body: _rateBody(indexPrice: -11751892)),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceInvalidResponseException>()),
      );
    });

    test('a precision that scales the rate to zero is invalid', () async {
      // 10.0^400 is infinite, so the scaled rate is 0: not a price.
      final datasource = _datasource(
        _StubAdapter(body: _rateBody(precision: 400)),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceInvalidResponseException>()),
      );
    });

    test('a precision that scales the rate to infinity is invalid', () async {
      // 10.0^-400 underflows to 0, so the scaled rate is infinite.
      final datasource = _datasource(
        _StubAdapter(body: _rateBody(precision: -400)),
      );

      await expectLater(
        datasource.getPrice('CAD'),
        throwsA(isA<PriceInvalidResponseException>()),
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
