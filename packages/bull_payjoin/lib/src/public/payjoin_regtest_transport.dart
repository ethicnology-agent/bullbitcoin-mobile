import 'dart:convert';
import 'dart:io';
import 'package:payjoin/payjoin.dart' show OhttpKeys;
import 'dart:typed_data';

/// Explicit local protocol fixture. Configured runtimes serve regtest only.
final class PayjoinRegtestTransport {
  final List<Uri> servers;
  final Uint8List certificate;

  PayjoinRegtestTransport({
    required List<Uri> servers,
    required Uint8List certificate,
  }) : servers = List.unmodifiable(servers),
       certificate = Uint8List.fromList(certificate).asUnmodifiableView() {
    if (servers.length < 2 ||
        servers.map((server) => server.host).toSet().length < 2 ||
        certificate.isEmpty ||
        certificate.length > 16384) {
      throw ArgumentError(
        'Regtest requires two local origins and a fixture certificate',
      );
    }
    for (final server in servers) {
      if (server.scheme != 'https' ||
          !const {'localhost', '127.0.0.1', '::1'}.contains(server.host) ||
          server.userInfo.isNotEmpty ||
          server.hasQuery ||
          server.hasFragment ||
          (server.path.isNotEmpty && server.path != '/')) {
        throw ArgumentError(
          'Payjoin regtest servers must be explicit HTTPS loopback origins',
        );
      }
    }
  }

  /// The fixture uses DER; Dart's non-iOS trust store expects PEM.
  SecurityContext createSecurityContext() {
    final encoded = base64Encode(certificate);
    final lines = <String>[];
    for (var offset = 0; offset < encoded.length; offset += 64) {
      final end = offset + 64;
      lines.add(
        encoded.substring(offset, end < encoded.length ? end : encoded.length),
      );
    }
    final bytes = Platform.isIOS
        ? certificate
        : utf8.encode(
            '-----BEGIN CERTIFICATE-----\n${lines.join('\n')}\n-----END CERTIFICATE-----\n',
          );
    return SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(bytes);
  }

  Future<OhttpKeys> fetchKeys({
    required String ohttpRelayUrl,
    required String directoryUrl,
    required Duration timeout,
  }) async {
    final relay = Uri.parse(ohttpRelayUrl);
    final directory = Uri.parse(directoryUrl);
    bool configured(Uri uri) =>
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment &&
        (uri.path.isEmpty || uri.path == '/') &&
        servers.any((s) => s.origin == uri.origin);
    if (!configured(relay) ||
        !configured(directory) ||
        relay.host == directory.host) {
      throw const FormatException('Untrusted regtest key origins');
    }
    final context = createSecurityContext();
    final client = HttpClient(context: context)..connectionTimeout = timeout;
    final relayHost = relay.host.contains(':') ? '[${relay.host}]' : relay.host;
    client.findProxy = (_) => 'PROXY $relayHost:${relay.port}';
    client.connectionFactory = (_, host, port) {
      if (host == null || port == null) {
        throw StateError('Regtest OHTTP requires its configured relay');
      }
      return SecureSocket.startConnect(host, port, context: context);
    };
    try {
      final request = await client
          .getUrl(directory.resolve('/.well-known/ohttp-gateway'))
          .timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptHeader, 'application/ohttp-keys');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw const HttpException('Regtest key discovery failed');
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > 65536) {
          throw const HttpException('Regtest key response exceeds bound');
        }
        bytes.add(chunk);
      }
      return OhttpKeys.decode(bytes: bytes.takeBytes());
    } finally {
      client.close(force: true);
    }
  }

  bool allowsBip21(String value) {
    try {
      final request = Uri.parse(value);
      if (request.scheme != 'bitcoin' ||
          !request.path.toLowerCase().startsWith('bcrt1')) {
        return false;
      }
      final endpoint = Uri.parse(request.queryParameters['pj'] ?? '');
      return endpoint.userInfo.isEmpty &&
          servers.any((server) => server.origin == endpoint.origin);
    } on FormatException {
      return false;
    } on StateError {
      return false;
    }
  }
}
