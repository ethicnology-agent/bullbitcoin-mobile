import 'dart:convert';
import 'dart:typed_data';

import 'package:bb_mobile/core/price/data/bitcoin_price_repository_impl.dart';
import 'package:bb_mobile/core/price/data/datasources/bullbitcoin_price_datasource.dart';
import 'package:bb_mobile/core/price/domain/usecases/convert_sats_to_currency_amount_usecase.dart';
import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/settings/domain/settings_entity.dart';
import 'package:bb_mobile/features/receive/domain/receive_failure.dart';
import 'package:bb_mobile/features/receive/domain/usecases/convert_receive_amount_usecase.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:primitives/primitives.dart';

class _MockSettings extends Mock implements SettingsRepository {}

class _RateResponse implements HttpClientAdapter {
  final int status;
  final Object body;

  _RateResponse(this.status, this.body);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

void main() {
  Future<Result<double, ReceiveFailure>> convert(int status, Object body) {
    final dio = Dio(BaseOptions(baseUrl: 'https://pricer.invalid'));
    dio.httpClientAdapter = _RateResponse(status, body);
    addTearDown(dio.close);
    final repository = BitcoinPriceRepositoryImpl(
      bullbitcoinPriceDatasource: BullbitcoinPriceDatasource(
        bullbitcoinApiHttpClient: dio,
      ),
    );
    final settings = _MockSettings();
    when(settings.fetch).thenAnswer(
      (_) async => const SettingsEntity(
        environment: Environment.testnet,
        bitcoinUnit: BitcoinUnit.sats,
        currencyCode: 'USD',
      ),
    );
    final usecase = ConvertReceiveAmountUsecase(
      ConvertSatsToCurrencyAmountUsecase(
        mainnetBitcoinPriceRepository: repository,
        testnetBitcoinPriceRepository: repository,
        settingsRepository: settings,
      ),
    );
    return usecase.execute(
      amountSat: BigInt.from(100000000),
      currencyCode: 'USD',
    );
  }

  test(
    'a rate-limited pricer is unavailable, never a successful zero amount',
    () async {
      expect(
        await convert(429, {'error': 'rate limited'}),
        isA<Err<double, ReceiveFailure>>(),
      );
    },
  );

  test(
    'a malformed pricer response is unavailable, never a successful zero amount',
    () async {
      expect(
        await convert(200, {'result': {}}),
        isA<Err<double, ReceiveFailure>>(),
      );
    },
  );

  test(
    'a negative precision is unavailable, never a scaled positive quote',
    () async {
      expect(
        await convert(200, {
          'result': {
            'element': {'indexPrice': 10000000, 'precision': -1},
          },
        }),
        isA<Err<double, ReceiveFailure>>(),
      );
    },
  );

  test('a valid positive price keeps the public wallet conversion', () async {
    final result = await convert(200, {
      'result': {
        'element': {'indexPrice': 10000000, 'precision': 2},
      },
    });
    expect((result as Ok<double, ReceiveFailure>).value, 100000);
  });
}
