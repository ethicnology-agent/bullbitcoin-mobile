import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/price/data/bitcoin_price_repository_impl.dart';
import 'package:bb_mobile/core/price/data/datasources/bullbitcoin_price_datasource.dart';
import 'package:bb_mobile/core/price/domain/price_failure.dart';
import 'package:bb_mobile/core/price/domain/price_unavailable_exception.dart';
import 'package:bb_mobile/core/price/domain/repositories/bitcoin_price_repository.dart';
import 'package:bb_mobile/core/price/domain/usecases/convert_currency_to_sats_amount_usecase.dart';
import 'package:bb_mobile/core/price/domain/usecases/convert_sats_to_currency_amount_usecase.dart';
import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSettingsRepository extends Mock implements SettingsRepository {}

const _settings = SettingsEntity(
  environment: Environment.mainnet,
  bitcoinUnit: BitcoinUnit.sats,
  currencyCode: 'CAD',
);

Map<String, dynamic> _rateBody() => {
  'jsonrpc': '2.0',
  'id': 1,
  'result': {
    'element': {
      'fromCurrency': 'BTC',
      'toCurrency': 'CAD',
      'indexPrice': 11751892,
      'precision': 2,
    },
  },
};

/// The real repository over a stubbed pricer: the legacy use cases are the
/// boundary under test, so nothing between them and the wire is faked.
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
  late _MockSettingsRepository settingsRepository;

  setUp(() {
    settingsRepository = _MockSettingsRepository();
    when(settingsRepository.fetch).thenAnswer((_) async => _settings);
  });

  ConvertSatsToCurrencyAmountUsecase satsToCurrency(
    HttpClientAdapter adapter,
  ) => ConvertSatsToCurrencyAmountUsecase(
    mainnetBitcoinPriceRepository: _repository(adapter),
    testnetBitcoinPriceRepository: _repository(_ConnectionErrorAdapter()),
    settingsRepository: settingsRepository,
  );

  ConvertCurrencyToSatsAmountUsecase currencyToSats(
    HttpClientAdapter adapter,
  ) => ConvertCurrencyToSatsAmountUsecase(
    mainnetBitcoinPriceRepository: _repository(adapter),
    testnetBitcoinPriceRepository: _repository(_ConnectionErrorAdapter()),
    settingsRepository: settingsRepository,
  );

  group('ConvertSatsToCurrencyAmountUsecase', () {
    // Names no new type: on the use case as it was, a rate-limited pricer
    // resolved to 0.0 here and the amount screens showed it as a price.
    test('HTTP 429 throws instead of resolving to zero', () async {
      final usecase = satsToCurrency(
        _StubAdapter(body: 'Too Many Requests', statusCode: 429),
      );

      await expectLater(usecase.execute(), throwsA(isA<Exception>()));
    });

    test('HTTP 429 throws the typed rate-limited failure', () async {
      final usecase = satsToCurrency(
        _StubAdapter(
          body: 'Too Many Requests',
          statusCode: 429,
          headers: {
            'retry-after': ['30'],
          },
        ),
      );

      await expectLater(
        usecase.execute(currencyCode: 'CAD'),
        throwsA(
          isA<PriceUnavailableException>().having(
            (e) => e.failure,
            'failure',
            isA<PriceRateLimitedFailure>().having(
              (f) => f.retryAfter,
              'retryAfter',
              '30',
            ),
          ),
        ),
      );
    });

    test('a transport failure throws the typed unavailable failure', () async {
      final usecase = satsToCurrency(_ConnectionErrorAdapter());

      await expectLater(
        usecase.execute(),
        throwsA(
          isA<PriceUnavailableException>().having(
            (e) => e.failure,
            'failure',
            isA<PriceUnavailableFailure>(),
          ),
        ),
      );
    });

    test('an unsupported currency keeps its legacy exception', () async {
      final usecase = satsToCurrency(_StubAdapter(body: _rateBody()));

      await expectLater(
        usecase.execute(currencyCode: 'XXX'),
        throwsA(isA<ConvertSatsToCurrencyAmountException>()),
      );
    });

    test('a valid rate prices one bitcoin by default', () async {
      final usecase = satsToCurrency(_StubAdapter(body: _rateBody()));

      expect(await usecase.execute(), closeTo(117518.92, 1e-9));
    });

    test('a valid rate prices the given sats', () async {
      final usecase = satsToCurrency(_StubAdapter(body: _rateBody()));

      expect(
        await usecase.execute(amountSat: BigInt.from(50000000)),
        closeTo(58759.46, 1e-9),
      );
    });
  });

  group('ConvertCurrencyToSatsAmountUsecase', () {
    test('HTTP 429 throws instead of resolving to a sats amount', () async {
      final usecase = currencyToSats(
        _StubAdapter(body: 'Too Many Requests', statusCode: 429),
      );

      await expectLater(
        usecase.execute(amountFiat: 100),
        throwsA(
          isA<PriceUnavailableException>().having(
            (e) => e.failure,
            'failure',
            isA<PriceRateLimitedFailure>(),
          ),
        ),
      );
    });

    test('a valid rate converts fiat to sats', () async {
      final usecase = currencyToSats(_StubAdapter(body: _rateBody()));

      expect(
        await usecase.execute(amountFiat: 117518.92),
        BigInt.from(100000000),
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
