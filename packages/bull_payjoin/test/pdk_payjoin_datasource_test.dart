import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bull_payjoin/src/data/payjoin_model.dart';
import 'package:bull_payjoin/src/engine/payjoin_constants.dart';
import 'package:bull_payjoin/src/engine/payjoin_logger.dart';
import 'package:bull_payjoin/src/engine/pdk_payjoin_datasource.dart';
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:mocktail/mocktail.dart';
import 'package:payjoin/payjoin.dart';
import 'package:test/test.dart';

class _MockDio extends Mock implements Dio {}

/// Hands out the scripted [nextInt] values in order and remembers every
/// upper bound it was asked for, so a test can pin both the delay a poll
/// waited and how many polls were armed.
class _ScriptedRandom implements Random {
  final List<int> _values;
  final List<int> maxes = [];

  _ScriptedRandom(this._values);

  int get draws => maxes.length;

  @override
  int nextInt(int max) {
    maxes.add(max);
    return _values.removeAt(0);
  }

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

final _ohttpKeysBytes = Uint8List.fromList([
  0x01,
  0x00,
  0x16,
  0x04,
  0x52,
  0x73,
  0xda,
  0xa8,
  0xf6,
  0x4c,
  0xdf,
  0x80,
  0x8f,
  0x1e,
  0x94,
  0x03,
  0x98,
  0x09,
  0xf6,
  0x47,
  0xfc,
  0x21,
  0xca,
  0x68,
  0xb2,
  0xbd,
  0x31,
  0xe7,
  0x30,
  0xa9,
  0xc5,
  0x7d,
  0xf3,
  0x68,
  0x84,
  0xb2,
  0xe7,
  0x82,
  0x6e,
  0x2f,
  0xa1,
  0xad,
  0x2b,
  0x9f,
  0x23,
  0x88,
  0x15,
  0x76,
  0x5a,
  0xa6,
  0x7b,
  0x1f,
  0x56,
  0xcc,
  0x72,
  0xc6,
  0x69,
  0x83,
  0x40,
  0x69,
  0x89,
  0x86,
  0x87,
  0x80,
  0xee,
  0x59,
  0x9b,
  0x1f,
  0x00,
  0x04,
  0x00,
  0x01,
  0x00,
  0x03,
]);

OhttpKeys _fakeOhttpKeys() => OhttpKeys.decode(bytes: _ohttpKeysBytes);

void main() {
  group('JSON session persisters', () {
    test('receiver events round-trip and are exposed read-only', () {
      final persister = InMemoryJsonReceiverSessionPersister()
        ..save('a')
        ..save('b');

      expect(persister.load(), ['a', 'b']);
      expect(() => persister.events.add('c'), throwsUnsupportedError);
      expect(
        InMemoryJsonReceiverSessionPersister.fromJson(
          persister.toJson(),
        ).load(),
        ['a', 'b'],
      );
    });

    test('sender events round-trip and malformed input becomes empty', () {
      final persister = InMemoryJsonSenderSessionPersister()
        ..save('a')
        ..save('b');

      expect(
        InMemoryJsonSenderSessionPersister.fromJson(persister.toJson()).load(),
        ['a', 'b'],
      );
      expect(
        InMemoryJsonSenderSessionPersister.fromJson('not-json').load(),
        isEmpty,
      );
      expect(
        InMemoryJsonSenderSessionPersister.fromJson(jsonEncode([1, 2])).load(),
        isEmpty,
      );
    });
  });

  group('fetchOhttpKeyAndRelay', () {
    test(
      'returns the first successful relay and requested directory',
      () async {
        final keys = _fakeOhttpKeys();
        final seenDirectories = <String>{};
        final datasource = PdkPayjoinDatasource(
          log: PayjoinLogger.silent,
          dio: Dio(),
          ohttpKeysFetcher:
              ({required ohttpRelayUrl, required directoryUrl}) async {
                seenDirectories.add(directoryUrl);
                if (ohttpRelayUrl != 'https://pj.bobspacebkk.com') {
                  throw StateError('relay unavailable');
                }
                return keys;
              },
        );

        final (resultKeys, relay) = await datasource.fetchOhttpKeyAndRelay(
          payjoinDirectory: 'https://directory.example',
        );

        expect(resultKeys, same(keys));
        expect(relay, 'https://pj.bobspacebkk.com');
        expect(seenDirectories, {'https://directory.example'});
        await datasource.dispose();
      },
    );

    test('tries every relay before returning unavailable', () async {
      final attempted = <String>{};
      final datasource = PdkPayjoinDatasource(
        log: PayjoinLogger.silent,
        dio: Dio(),
        ohttpKeysFetcher:
            ({required ohttpRelayUrl, required directoryUrl}) async {
              attempted.add(ohttpRelayUrl);
              throw StateError('relay unavailable');
            },
      );

      expect(
        await datasource.fetchOhttpKeyAndRelay(
          payjoinDirectory: PayjoinConstants.directoryUrl,
        ),
        (null, null),
      );
      expect(attempted, PayjoinConstants.ohttpRelayUrlsBase.toSet());
      await datasource.dispose();
    });
  });

  group('postBytes', () {
    setUpAll(() {
      registerFallbackValue(RequestOptions(path: 'https://relay.example'));
      registerFallbackValue(Options());
    });

    test('propagates Dio timeouts for relay fallback', () async {
      final dio = _MockDio();
      when(
        () => dio.post<List<int>>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenThrow(
        DioException(
          requestOptions: RequestOptions(path: 'https://relay.example'),
          type: DioExceptionType.receiveTimeout,
        ),
      );

      expect(
        () => PdkPayjoinDatasource.postBytes(
          dio,
          'https://relay.example',
          Uint8List.fromList([1]),
          'message/ohttp-req',
        ),
        throwsA(
          isA<DioException>().having(
            (error) => error.type,
            'type',
            DioExceptionType.receiveTimeout,
          ),
        ),
      );
    });

    test('returns response bytes', () async {
      final dio = _MockDio();
      when(
        () => dio.post<List<int>>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer(
        (_) async => Response(
          requestOptions: RequestOptions(path: 'https://relay.example'),
          data: [4, 5, 6],
        ),
      );

      expect(
        await PdkPayjoinDatasource.postBytes(
          dio,
          'https://relay.example',
          Uint8List.fromList([1]),
          'message/ohttp-req',
        ),
        Uint8List.fromList([4, 5, 6]),
      );
    });
  });

  group('polling lifecycle', () {
    PayjoinSenderModel sender({
      required int createdAt,
      required int expireAfterSec,
    }) =>
        PayjoinModel.sender(
              uri: 'bitcoin:tb1qsender?pj=https://payjo.in',
              isTestnet: true,
              sender: '[]',
              walletId: 'w1',
              originalPsbt: 'cHNidP8=',
              originalTxId: 'orig-txid',
              amountSat: 50000,
              createdAt: createdAt,
              expireAfterSec: expireAfterSec,
            )
            as PayjoinSenderModel;

    PayjoinSenderModel expiredSender() =>
        sender(createdAt: 0, expireAfterSec: 300);

    PayjoinSenderModel pendingSender() => sender(
      createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      expireAfterSec: PayjoinConstants.defaultExpireAfterSec,
    );

    test('stopPolling prevents a pending expiry event', () {
      fakeAsync((async) {
        final datasource = PdkPayjoinDatasource(
          log: PayjoinLogger.silent,
          dio: Dio(),
        );
        final events = <PayjoinModel>[];
        datasource.expiredPayjoins.listen(events.add);
        final model = expiredSender();

        datasource.startListeningForProposal(model);
        datasource.stopPolling(model.id);
        async.elapse(
          const Duration(
            seconds: PayjoinConstants.maxDirectoryPollingInterval * 3,
          ),
        );

        expect(events, isEmpty);
        datasource.dispose();
        async.flushMicrotasks();
      });
    });

    const minDelay = Duration(
      seconds: PayjoinConstants.minDirectoryPollingInterval,
    );
    const maxDelay = Duration(
      seconds: PayjoinConstants.maxDirectoryPollingInterval,
    );
    // nextInt(max) returns [0, max), so these draws hit the two bounds.
    const drawMin = 0;
    const drawMax =
        (PayjoinConstants.maxDirectoryPollingInterval -
            PayjoinConstants.minDirectoryPollingInterval) *
        1000;

    test('the wait between polls is drawn from the whole 1 to 5 s range', () {
      final datasource = PdkPayjoinDatasource(
        log: PayjoinLogger.silent,
        dio: Dio(),
        random: Random(7),
      );

      final delays = {
        for (var i = 0; i < 2000; i++) datasource.nextPollingDelay(),
      };

      expect(delays, everyElement(greaterThanOrEqualTo(minDelay)));
      expect(delays, everyElement(lessThanOrEqualTo(maxDelay)));
      expect(delays.length, greaterThan(1000));
      datasource.dispose();
    });

    test('the draw maps its bounds to exactly 1 s and 5 s', () {
      final random = _ScriptedRandom([drawMin, drawMax]);
      final datasource = PdkPayjoinDatasource(
        log: PayjoinLogger.silent,
        dio: Dio(),
        random: random,
      );

      expect(datasource.nextPollingDelay(), minDelay);
      expect(datasource.nextPollingDelay(), maxDelay);
      expect(random.maxes, [drawMax + 1, drawMax + 1]);
      datasource.dispose();
    });

    test('the first poll waits the drawn delay, not a fixed one', () {
      fakeAsync((async) {
        final datasource = PdkPayjoinDatasource(
          log: PayjoinLogger.silent,
          dio: Dio(),
          random: _ScriptedRandom([drawMax]),
        );
        final events = <PayjoinModel>[];
        datasource.expiredPayjoins.listen(events.add);

        datasource.startListeningForProposal(expiredSender());
        async.elapse(maxDelay - const Duration(milliseconds: 1));
        expect(events, isEmpty);

        async.elapse(const Duration(milliseconds: 1));
        expect(events, hasLength(1));
        datasource.dispose();
        async.flushMicrotasks();
      });
    });

    test('an unresolved poll re-arms itself with a fresh draw', () {
      fakeAsync((async) {
        final random = _ScriptedRandom([drawMin, drawMax, drawMin]);
        final datasource = PdkPayjoinDatasource(
          log: PayjoinLogger.silent,
          dio: Dio(),
          random: random,
        );

        datasource.startListeningForProposal(pendingSender());
        expect(random.draws, 1);

        async.elapse(minDelay);
        expect(random.draws, 2);

        async.elapse(maxDelay - const Duration(milliseconds: 1));
        expect(random.draws, 2);

        async.elapse(const Duration(milliseconds: 1));
        expect(random.draws, 3);
        datasource.dispose();
        async.flushMicrotasks();
      });
    });

    test('stopPolling between two polls stops the re-arming', () {
      fakeAsync((async) {
        final random = _ScriptedRandom([drawMin, drawMin, drawMin]);
        final datasource = PdkPayjoinDatasource(
          log: PayjoinLogger.silent,
          dio: Dio(),
          random: random,
        );
        final model = pendingSender();

        datasource.startListeningForProposal(model);
        async.elapse(minDelay);
        expect(random.draws, 2);

        datasource.stopPolling(model.id);
        async.elapse(maxDelay * 3);
        expect(random.draws, 2);
        datasource.dispose();
        async.flushMicrotasks();
      });
    });

    test('dispose closes streams and is idempotent', () async {
      final datasource = PdkPayjoinDatasource(
        log: PayjoinLogger.silent,
        dio: Dio(),
      );

      await datasource.dispose();

      await expectLater(datasource.requestsForReceivers, emitsDone);
      await expectLater(datasource.proposalsForSenders, emitsDone);
      await expectLater(datasource.expiredPayjoins, emitsDone);
      await expectLater(datasource.dispose(), completes);
    });
  });
}
