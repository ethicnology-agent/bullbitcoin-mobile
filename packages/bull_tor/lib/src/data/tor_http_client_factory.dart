import 'dart:io';

import 'package:socks5_proxy/socks_client.dart';

import '../domain/entities/tor_proxy_endpoint.dart';
import '../domain/tor_failure.dart';

/// Builds an HTTP client for an already-selected Tor route.
///
/// [endpoint] is deliberately non-nullable. Accepting null meant "return a
/// plain, unproxied client". A caller that passed null could ship a request over
/// clearnet, so the route is a requirement the compiler enforces rather than a
/// default the caller can forget.
final class TorHttpClientFactory {
  const TorHttpClientFactory();

  /// Creates a client that can only connect through [endpoint].
  ///
  /// Certificate validation stays enabled unless [allowBadCertificate] is
  /// explicitly selected for a user-controlled server.
  HttpClient create(
    TorProxyEndpoint endpoint, {
    bool allowBadCertificate = false,
  }) {
    // `ProxySettings` takes a resolved address, but `TorProxyEndpoint` accepts
    // any non-empty host because the Electrum advanced options let one be typed
    // by hand. Rejecting a non-literal here as a modeled failure keeps that
    // combination from surfacing as a bare `ArgumentError` from `dart:io`.
    final address = InternetAddress.tryParse(endpoint.host);
    if (address == null) {
      throw TorBackendException(
        TorUnexpectedFailure(
          'SOCKS5 proxy host is not an IP literal: ${endpoint.host}',
        ),
      );
    }

    final client = HttpClient();
    SocksTCPClient.assignToHttpClientWithSecureOptions(client, [
      ProxySettings(address, endpoint.port, password: null),
    ], onBadCertificate: allowBadCertificate ? (_) => true : null);
    return client;
  }
}
