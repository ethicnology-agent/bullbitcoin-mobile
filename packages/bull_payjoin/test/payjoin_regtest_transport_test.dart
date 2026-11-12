import 'dart:typed_data';
import 'fixtures/regtest_certificate.dart';
import 'package:bull_payjoin/bull_payjoin.dart';
import 'package:test/test.dart';

void main() {
  test('loads the public DER certificate into a scoped trust context', () {
    final transport = PayjoinRegtestTransport(
      servers: [
        Uri.parse('https://localhost:8040'),
        Uri.parse('https://127.0.0.1:8041'),
      ],
      certificate: regtestCertificate(),
    );
    expect(transport.createSecurityContext, returnsNormally);
  });

  test(
    'requires distinct HTTPS loopback hosts and an explicit certificate',
    () {
      for (final urls in [
        ['http://localhost:8040', 'https://127.0.0.1:8041'],
        ['https://remote.example', 'https://localhost:8040'],
        ['https://localhost:8040', 'https://localhost:8041'],
        ['https://user@localhost:8040', 'https://127.0.0.1:8041'],
      ]) {
        expect(
          () => PayjoinRegtestTransport(
            servers: urls.map(Uri.parse).toList(),
            certificate: Uint8List.fromList([1]),
          ),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'rejects untrusted discovery origins before TLS or outbound requests',
    () async {
      final transport = PayjoinRegtestTransport(
        servers: [
          Uri.parse('https://localhost:8040'),
          Uri.parse('https://127.0.0.1:8041'),
        ],
        certificate: Uint8List.fromList([1]),
      );
      for (final directory in [
        'https://remote.example',
        'http://localhost:8040',
        'https://user@localhost:8040',
        'https://localhost:8040/?redirect=remote',
        'https://127.0.0.1:8041',
      ]) {
        await expectLater(
          transport.fetchKeys(
            ohttpRelayUrl: 'https://127.0.0.1:8041',
            directoryUrl: directory,
            timeout: const Duration(seconds: 1),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Untrusted regtest key origins',
            ),
          ),
        );
      }
      expect(
        transport.allowsBip21(
          'bitcoin:bc1qexample?pj=https://localhost:8040/a',
        ),
        isFalse,
      );
      expect(
        transport.allowsBip21(
          'bitcoin:bcrt1qexample?pj=https://remote.example/a',
        ),
        isFalse,
      );
      expect(
        transport.allowsBip21(
          'bitcoin:bcrt1qexample?pj=https://localhost:8040/a',
        ),
        isTrue,
      );
    },
  );
}
