import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Fee requests must keep using the configured Tor route rather than falling
// back to the direct Dio transport.
void main() {
  group('Security audit #2658 fee transport bypasses Tor', () {
    test('fee datasource configures Tor-aware transport', () {
      final source = File(
        'lib/core/fees/data/fees_datasource.dart',
      ).readAsStringSync();
      expect(source, contains('useTorProxy'));
      expect(source, contains('torProxyPort'));
      expect(source, contains('TorHttpClientFactory'));
      expect(source, contains('TorProxyEndpoint'));
    });
  });
}
