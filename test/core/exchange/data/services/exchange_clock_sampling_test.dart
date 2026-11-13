import 'dart:typed_data';

import 'package:bb_mobile/core/exchange/data/services/exchange_clock_offset.dart';
import 'package:clock/clock.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

class _SlowAdapter implements HttpClientAdapter {
  final void Function() onFetch;

  _SlowAdapter(this.onFetch);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    onFetch();
    return ResponseBody.fromString(
      'ok',
      200,
      headers: {
        'date': ['Fri, 06 Nov 2026 12:00:20 GMT'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test('a slow response retains an existing nonzero offset', () async {
    final serverNow = DateTime.utc(2026, 11, 6, 12);
    final offset = ExchangeClockOffset()
      ..observe(
        serverTime: serverNow,
        deviceTime: serverNow.add(const Duration(hours: 1)),
      );
    var deviceNow = serverNow.add(const Duration(minutes: 30));
    final dio = Dio()
      ..interceptors.add(offset.interceptor)
      ..httpClientAdapter = _SlowAdapter(
        () => deviceNow = deviceNow.add(const Duration(seconds: 40)),
      );
    addTearDown(dio.close);

    await withClock(
      Clock(() => deviceNow),
      () => dio.get<String>('https://example.invalid/probe'),
    );

    expect(offset.offset, const Duration(hours: -1));
  });
}
