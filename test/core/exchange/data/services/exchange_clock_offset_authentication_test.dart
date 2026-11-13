import 'dart:typed_data';

import 'package:bb_mobile/core/exchange/data/exchange_authentication.dart';
import 'package:bb_mobile/core/exchange/data/http/exchange_authentication_interceptor.dart';
import 'package:bb_mobile/core/exchange/data/services/exchange_clock_offset.dart';
import 'package:bb_mobile/core/exchange/domain/exchange_api_key_failure.dart';
import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primitives/primitives.dart';

class _Adapter implements HttpClientAdapter {
  final keys = <Object?>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    keys.add(options.headers['X-API-Key']);
    return ResponseBody.fromString(
      '{}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        'date': ['Fri, 06 Nov 2026 12:00:00 GMT'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('clock observation preserves credential rotation and refusal', () async {
    final offset = ExchangeClockOffset();
    final adapter = _Adapter();
    final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'))
      ..httpClientAdapter = adapter;
    addTearDown(dio.close);

    var reads = 0;
    addExchangeAuthentication(dio, () async {
      reads++;
      if (reads == 1) return const Ok('key1');
      if (reads == 2) return const Ok('key2');
      return const Err(ExchangeApiKeyReadFailure());
    });
    dio.interceptors.add(offset.interceptor);

    await withClock(Clock.fixed(DateTime.utc(2026, 11, 6, 12, 30)), () async {
      await dio.get<dynamic>('/probe');
      await dio.get<dynamic>('/probe');

      expect(adapter.keys, ['key1', 'key2']);
      expect(offset.offset, const Duration(minutes: -30));

      await expectLater(
        dio.get<dynamic>('/probe'),
        throwsA(
          isA<DioException>()
              .having((error) => error.response, 'response', isNull)
              .having(
                (error) => exchangeAuthenticationException(error)?.failure,
                'credential failure',
                isA<ExchangeApiKeyReadFailure>(),
              ),
        ),
      );
      expect(reads, 3);
      expect(adapter.keys, ['key1', 'key2']);
      expect(offset.offset, const Duration(minutes: -30));
    });
  });
}
