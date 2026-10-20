import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/exchange/data/datasources/bullbitcoin_api_datasource.dart';
import 'package:bb_mobile/core/exchange/data/datasources/http/authenticated_bullbitcoin_dio_factory.dart';
import 'package:bb_mobile/core/exchange/data/datasources/http/bullbitcoin_api_key_provider.dart';
import 'package:bb_mobile/core/exchange/data/exchange_rate_repository_impl.dart';
import 'package:bb_mobile/core/exchange/domain/entity/exchange_rate.dart';
import 'package:bb_mobile/core/exchange/domain/exchange_rate_failure.dart';
import 'package:bb_mobile/core/exchange/domain/repositories/exchange_rate_repository.dart';
import 'package:bb_mobile/core/exchange/domain/usecases/get_exchange_rate_usecase.dart';
import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:primitives/primitives.dart';

class _MockKeyProvider extends Mock implements BullbitcoinApiKeyProvider {}

class _MockSettings extends Mock implements SettingsRepository {}

class _MockRepository extends Mock implements ExchangeRateRepository {}

class _ResponseAdapter implements HttpClientAdapter {
  final Object body;
  final int status;
  RequestOptions? request;

  _ResponseAdapter(this.body, {this.status = 200});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    request = options;
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'retry-after': ['60'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  final validBody = {
    'result': {
      'element': {
        'fromCurrency': 'CAD',
        'toCurrency': 'BTC',
        'indexPrice': 10000000,
        'userPrice': 9700000,
        'precision': 2,
      },
    },
  };

  ExchangeRateRepository repository(
    _ResponseAdapter adapter, {
    String? key = 'fixture-key',
  }) {
    final keys = _MockKeyProvider();
    when(() => keys.getApiKey(isTestnet: true)).thenAnswer((_) async => key);
    final dio = AuthenticatedBullBitcoinDioFactory.create(
      isTestnet: true,
      apiKeyProvider: keys,
    );
    dio.httpClientAdapter = adapter;
    addTearDown(dio.close);
    return ExchangeRateRepositoryImpl(
      BullbitcoinApiDatasource(bullbitcoinApiHttpClient: dio),
    );
  }

  test('uses the authenticated pricer and preserves the index price', () async {
    final adapter = _ResponseAdapter(validBody);
    final result = await repository(adapter).getRate('cad');
    final rate = (result as Ok<ExchangeRate, ExchangeRateFailure>).value;
    expect(rate.indexPrice, 100000);
    expect(rate.userPrice, 97000);
    expect(rate.currencyCode, 'CAD');
    final request = adapter.request;
    expect(request?.headers['X-API-Key'], 'fixture-key');
    expect(request?.path, '/public/price');
    expect(request?.data, {
      'jsonrpc': '2.0',
      'id': '0',
      'method': 'getUserRate',
      'params': {
        'element': {'fromCurrency': 'CAD', 'toCurrency': 'BTC'},
      },
    });
  });

  test(
    'an omitted currency echo keeps the currency requested by the caller',
    () async {
      final result = await repository(
        _ResponseAdapter({
          'result': {
            'element': {
              'indexPrice': 10000000,
              'userPrice': 9700000,
              'precision': 2,
            },
          },
        }),
      ).getRate('CAD');
      expect(
        (result as Ok<ExchangeRate, ExchangeRateFailure>).value.currencyCode,
        'CAD',
      );
    },
  );

  test('large precision is scaled without integer overflow', () async {
    final result = await repository(
      _ResponseAdapter({
        'result': {
          'element': {
            'fromCurrency': 'CAD',
            'indexPrice': 1e21,
            'userPrice': 9.7e20,
            'precision': 20,
          },
        },
      }),
    ).getRate('CAD');
    expect(
      (result as Ok<ExchangeRate, ExchangeRateFailure>).value.indexPrice,
      10,
    );
  });

  test('a 429 remains a typed failure carrying Retry-After', () async {
    final result = await repository(
      _ResponseAdapter({}, status: 429),
    ).getRate('CAD');
    final failure = (result as Err<ExchangeRate, ExchangeRateFailure>).failure;
    expect(failure, isA<ExchangeRateLimitedFailure>());
    expect((failure as ExchangeRateLimitedFailure).retryAfter, '60');
  });

  test('a missing account fails closed before sending the request', () async {
    final adapter = _ResponseAdapter(validBody);
    final result = await repository(adapter, key: null).getRate('CAD');
    expect(
      (result as Err<ExchangeRate, ExchangeRateFailure>).failure,
      isA<ExchangeRateUnauthenticatedFailure>(),
    );
    expect(adapter.request, isNull);
  });

  for (final invalid in [
    {
      'result': {
        'element': {
          'fromCurrency': 'CAD',
          'indexPrice': 0,
          'userPrice': 1,
          'precision': 2,
        },
      },
    },
    {
      'result': {
        'element': {
          'fromCurrency': 'USD',
          'indexPrice': 1,
          'userPrice': 1,
          'precision': 2,
        },
      },
    },
    {
      'result': {
        'element': {'fromCurrency': 'CAD', 'indexPrice': 'bad', 'userPrice': 1},
      },
    },
    {
      'error': {'message': 'unavailable'},
    },
  ]) {
    test(
      'invalid exchange prices are failures, never usable rates: $invalid',
      () async {
        final result = await repository(
          _ResponseAdapter(invalid),
        ).getRate('CAD');
        expect(
          (result as Err<ExchangeRate, ExchangeRateFailure>).failure,
          isA<ExchangeRateInvalidResponseFailure>(),
        );
      },
    );
  }

  test(
    'the use case selects the account network and configured currency',
    () async {
      final mainnet = _MockRepository();
      final testnet = _MockRepository();
      final settings = _MockSettings();
      when(settings.fetch).thenAnswer(
        (_) async => const SettingsEntity(
          environment: Environment.testnet,
          bitcoinUnit: BitcoinUnit.sats,
          currencyCode: 'CAD',
        ),
      );
      final rate = ExchangeRate(
        currencyCode: 'CAD',
        indexPrice: 100000,
        userPrice: 97000,
      );
      when(() => testnet.getRate('CAD')).thenAnswer((_) async => Ok(rate));
      final usecase = GetExchangeRateUsecase(
        mainnetRepository: mainnet,
        testnetRepository: testnet,
        settingsRepository: settings,
      );
      expect(
        (await usecase.execute() as Ok<ExchangeRate, ExchangeRateFailure>)
            .value,
        same(rate),
      );
      verifyNever(() => mainnet.getRate(any()));
    },
  );
}
