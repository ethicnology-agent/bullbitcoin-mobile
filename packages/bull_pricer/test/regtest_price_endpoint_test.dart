import 'dart:convert';
import 'dart:io';

import 'package:bull_pricer/bull_pricer.dart';
import 'package:primitives/primitives.dart';
import 'package:test/test.dart';

void main() {
  test('regtest refuses remote origins before initializing storage', () async {
    for (final endpoint in [
      'https://api.bullbitcoin.com',
      'http://example.com',
      'http://user:password@127.0.0.1:8088',
      'http://127.0.0.1:8088?network=mainnet',
    ]) {
      await expectLater(
        Pricer.init(
          databasePath: 'must-not-be-created.sqlite',
          regtestEndpoint: Uri.parse(endpoint),
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'regtest prices and history use the explicit local HTTP service',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'regtest-pricer-',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final methods = <String>[];
      server.listen((request) async {
        expect(request.uri.path, '/public/price');
        expect(request.headers.value('X-API-Key'), isNull);
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        final method = body['method'] as String;
        methods.add(method);
        final element = method == 'getRate'
            ? <String, Object>{'indexPrice': 10000000, 'precision': 2}
            : <String, Object>{
                'precision': 2,
                'rates': [
                  {
                    'periodStart': DateTime.now().toUtc().toIso8601String(),
                    'indexPrice': 10000000,
                  },
                ],
              };
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'result': {'element': element},
          }),
        );
        await request.response.close();
      });
      try {
        await Pricer.init(
          databasePath: '${directory.path}/pricer.sqlite',
          regtestEndpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        );
        final price = await Pricer.getIndexPrice(
          network: BitcoinNetwork.regtest,
          currency: SupportedCurrency.cad,
        );
        expect(price, isA<Ok<BitcoinPrice, PricerFailure>>());
        if (price case Ok(:final value)) expect(value.fiatAmount, 100000);
        final history = await Pricer.getPriceHistory(
          network: BitcoinNetwork.regtest,
          currency: SupportedCurrency.cad,
        );
        expect(history, isA<Ok<List<PricePoint>, PricerFailure>>());
        if (history case Ok(:final value)) expect(value, isNotEmpty);
        expect(methods, containsAll(['getRate', 'getIndexRateHistory']));
      } finally {
        await Pricer.close();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
}
