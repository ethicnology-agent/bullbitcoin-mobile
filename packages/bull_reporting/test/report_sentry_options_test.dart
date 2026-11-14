import 'package:bull_reporting/src/report.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

T _required<T>(T? value) {
  if (value == null) throw StateError('Expected a configured privacy callback');
  return value;
}

SentryFlutterOptions _options({required bool consent}) {
  Report.consent = consent;
  final options = SentryFlutterOptions();
  Report.configureSentryOptions(options, dsn: 'https://public@example.com/1');
  return options;
}

final class _Transaction extends Fake implements SentryTransaction {
  @override
  final contexts = Contexts();
}

void main() {
  tearDown(() => Report.consent = false);

  test('keeps consented transaction sampling and disables new telemetry', () {
    final options = _options(consent: true);
    expect(options.traceLifecycle, SentryTraceLifecycle.static);
    expect(options.tracesSampleRate, 0.2);
    expect(options.enableAutoPerformanceTracing, isTrue);
    expect(options.sendDefaultPii, isFalse);
    expect(options.captureFailedRequests, isFalse);
    expect(options.captureNativeFailedRequests, isFalse);
    expect(options.attachScreenshot, isFalse);
    expect(options.attachViewHierarchy, isFalse);
    expect(options.replay.sessionSampleRate, 0);
    expect(options.replay.onErrorSampleRate, 0);
    // ignore: experimental_member_use
    expect(options.replay.enableWebReplay, isFalse);
    expect(options.enablePrintBreadcrumbs, isFalse);
  });

  test('does not start performance tracking without boot consent', () {
    final options = _options(consent: false);
    expect(options.tracesSampleRate, 0);
    expect(options.enableAutoPerformanceTracing, isFalse);
    expect(options.enableAutoSessionTracking, isFalse);
    expect(options.sendClientReports, isFalse);
  });

  test(
    'live opt-out drops errors and transactions created with consent',
    () async {
      final options = _options(consent: true);
      final event = SentryEvent();
      final transaction = _Transaction();
      final sendEvent = _required(options.beforeSend);
      final sendTransaction = _required(options.beforeSendTransaction);
      expect(await sendEvent(event, Hint()), same(event));
      expect(await sendTransaction(transaction, Hint()), same(transaction));

      Report.consent = false;

      expect(await sendEvent(event, Hint()), isNull);
      expect(await sendTransaction(transaction, Hint()), isNull);
    },
  );

  for (final consent in [false, true]) {
    test('drops SDK logs and metrics with consent $consent', () async {
      final options = _options(consent: consent);
      final log = SentryLog(
        timestamp: DateTime.utc(2026),
        traceId: SentryId.newId(),
        level: SentryLogLevel.info,
        body: 'private marker',
        attributes: {},
      );
      final metric = SentryCounterMetric(
        timestamp: DateTime.utc(2026),
        traceId: SentryId.newId(),
        name: 'private.marker',
        value: 1,
      );
      expect(await _required(options.beforeSendLog)(log, Hint()), isNull);
      expect(await _required(options.beforeSendMetric)(metric, Hint()), isNull);
    });
  }

  test('minimizes error payload and excludes new cellular context', () async {
    final options = _options(consent: true);
    final event = SentryEvent(
      exceptions: [SentryException(type: 'Test', value: 'private exception')],
      user: SentryUser(id: 'opaque-install', email: 'private@example.com'),
      request: SentryRequest(url: 'https://example.com/private'),
      breadcrumbs: [
        Breadcrumb(message: 'private breadcrumb', data: {'secret': 'private'}),
      ],
      contexts: Contexts(
        device: SentryDevice.fromJson({
          'model': 'retained model',
          'connection_effective_type': '5g',
        }),
      ),
    );

    final result = await _required(options.beforeSend)(event, Hint());

    expect(result, same(event));
    expect(event.exceptions?.single.value, isNull);
    expect(event.request, isNull);
    expect(event.user?.toJson(), {'id': 'opaque-install'});
    expect(event.breadcrumbs?.single.message, isNull);
    expect(event.breadcrumbs?.single.data, isNull);
    expect(event.contexts.device?.toJson(), {'model': 'retained model'});
  });

  test('excludes new cellular context from allowed transactions', () async {
    final options = _options(consent: true);
    final transaction = _Transaction();
    transaction.contexts.device = SentryDevice.fromJson({
      'model': 'retained model',
      'connection_effective_type': '4g',
    });

    final result = await _required(options.beforeSendTransaction)(
      transaction,
      Hint(),
    );

    expect(result, same(transaction));
    expect(transaction.contexts.device?.toJson(), {'model': 'retained model'});
  });
}
