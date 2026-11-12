import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Only the isolated stack's bounded test utilities are reachable here.
final class RegtestController {
  static final _origin = Uri.parse('http://127.0.0.1:8099');

  Future<void> verify() async {
    final health = await _request('GET', '/health');
    if (health['network'] != 'regtest' ||
        health['service'] != 'regtest-controller') {
      throw StateError('The regtest controller did not verify its networks');
    }
  }

  Future<({String runId, String address})> arkFundingAddress() async {
    final response = await _request('POST', '/ark/funding-address', {});
    final runId = response['run_id'];
    final address = response['address'];
    if (runId is! String ||
        address is! String ||
        !address.startsWith('bcrt1') ||
        response['deposit_sat'] != 150000) {
      throw StateError('The Ark fixture did not provide its regtest deposit');
    }
    return (runId: runId, address: address);
  }

  Future<void> boardArk(String runId, String depositTxid) async {
    final response = await _request('POST', '/ark/board', {
      'run_id': runId,
      'deposit_txid': depositTxid,
    }, const Duration(seconds: 180));
    if (response['deposit_confirmed'] != true ||
        response['board_spendable'] != true ||
        response['amount_sat'] != 100000) {
      throw StateError(
        'The confirmed deposit and new Ark board were not verified',
      );
    }
  }

  Future<String> offboardArk(String runId, String address) async {
    if (!address.startsWith('bcrt1')) {
      throw ArgumentError('Bitcoin regtest destination required');
    }
    final response = await _request('POST', '/ark/offboard', {
      'run_id': runId,
      'address': address,
    }, const Duration(seconds: 180));
    final txid = response['offboard_txid'];
    if (txid is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(txid) ||
        response['transferred_sat'] != 100000) {
      throw StateError(
        'The Ark fixture did not verify its transfer and offboard',
      );
    }
    return txid;
  }

  Future<Uint8List> payjoinCertificate() async {
    final response = await _request('GET', '/payjoin/certificate');
    final encoded = response['certificate'];
    if (encoded is! String || encoded.length > 22000) {
      throw StateError('The Payjoin fixture did not provide its certificate');
    }
    return base64Decode(encoded);
  }

  Future<String> fund({
    required String address,
    required int amountSat,
    bool liquid = false,
  }) async {
    final validAddress = liquid
        ? address.startsWith('el1') || address.startsWith('ert1')
        : address.startsWith('bcrt1');
    if (!validAddress || amountSat < 1 || amountSat > 5000000) {
      throw ArgumentError('A bounded regtest funding request is required');
    }
    final response = await _request('POST', '/faucet', {
      'network': liquid ? 'liquid' : 'bitcoin',
      'address': address,
      'amount_sat': amountSat,
    });
    final txid = response['txid'];
    if (txid is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(txid)) {
      throw StateError('The faucet did not return a transaction ID');
    }
    return txid;
  }

  Future<void> mine({bool liquid = false, int count = 1}) async {
    if (count < 1 || count > 6) {
      throw ArgumentError('Mine between one and six blocks per request');
    }
    await _request('POST', '/mine', {
      'network': liquid ? 'liquid' : 'bitcoin',
      'count': count,
    });
  }

  Future<String> invoice({int amountSat = 100000}) async {
    final response = await _request('POST', '/lightning/invoice', {
      'amount_sat': amountSat,
    });
    final invoice = response['invoice'];
    if (invoice is! String || !invoice.startsWith('lnbcrt')) {
      throw StateError('The fixture did not return a regtest invoice');
    }
    return invoice;
  }

  Future<void> pay(String invoice) async {
    if (!invoice.startsWith('lnbcrt')) {
      throw ArgumentError('A regtest invoice is required');
    }
    final response = await _request('POST', '/lightning/pay', {
      'invoice': invoice,
    }, const Duration(seconds: 180));
    if (response['status'] != 'complete') {
      throw StateError('Regtest Lightning payment did not complete');
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Map<String, Object>? body,
    Duration timeout = const Duration(seconds: 30),
  ]) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';
    try {
      final request = await client.openUrl(method, _origin.resolve(path));
      request.followRedirects = false;
      if (body != null) {
        request.headers.contentType = ContentType.json;
        final bytes = utf8.encode(jsonEncode(body));
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        throw StateError('Regtest utility failed: HTTP ${response.statusCode}');
      }
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }
}
