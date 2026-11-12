import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bull_tor/tor.dart';
import 'package:recoverbull/recoverbull.dart';

/// Real client/server protocol check; no wallet or persistent test key is used.
Future<void> main() async {
  final random = Random.secure();
  Uint8List bytes(int length) =>
      Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
  final identifier = bytes(32);
  final salt = bytes(16);
  final key = bytes(32);
  final entropy = bytes(32);
  final password = Uint8List.fromList(utf8.encode(base64UrlEncode(entropy)));
  entropy.fillRange(0, entropy.length, 0);
  final client = const TorHttpClientFactory().create(
    TorProxyEndpoint(host: '127.0.0.1', port: 59051),
  )..connectionTimeout = const Duration(seconds: 5);
  final server = KeyServer(
    address: Uri.parse('http://regtest.recoverbull.onion:3000'),
    client: client,
  );
  var stored = false;
  var stage = 'network verification';
  try {
    final health = HttpClient();
    try {
      final request = await health.getUrl(
        Uri.parse('http://127.0.0.1:8099/health'),
      );
      final response = await request.close().timeout(
        const Duration(seconds: 10),
      );
      final body = jsonDecode(await utf8.decoder.bind(response).join());
      if (response.statusCode != 200 || body['network'] != 'regtest') {
        throw StateError('The controller did not verify the regtest networks');
      }
    } finally {
      health.close(force: true);
    }
    stage = 'server info';
    await server.infos().timeout(const Duration(seconds: 20));
    stage = 'store';
    await server
        .storeBackupKey(
          backupId: identifier,
          password: password,
          backupKey: key,
          salt: salt,
        )
        .timeout(const Duration(seconds: 45));
    stored = true;
    stage = 'fetch';
    final fetched = await server
        .fetchBackupKey(backupId: identifier, password: password, salt: salt)
        .timeout(const Duration(seconds: 45));
    try {
      if (fetched.length != key.length ||
          !List.generate(
            key.length,
            (index) => fetched[index] == key[index],
          ).every((value) => value)) {
        throw StateError('The recovered fixture key differs');
      }
    } finally {
      fetched.fillRange(0, fetched.length, 0);
    }
    stage = 'trash';
    final removed = await server
        .trashBackupKey(backupId: identifier, password: password, salt: salt)
        .timeout(const Duration(seconds: 45));
    removed.fillRange(0, removed.length, 0);
    stored = false;
    stdout.writeln(
      'RecoverBull client store, fetch and trash passed through the local SOCKS fixture',
    );
  } catch (error) {
    stderr.writeln(
      'RecoverBull fixture failed at $stage category=${error.runtimeType}',
    );
    exitCode = 1;
  } finally {
    try {
      if (stored) {
        final removed = await server
            .trashBackupKey(
              backupId: identifier,
              password: password,
              salt: salt,
            )
            .timeout(const Duration(seconds: 45));
        removed.fillRange(0, removed.length, 0);
      }
    } catch (error) {
      stderr.writeln(
        'RecoverBull fixture cleanup failed category=${error.runtimeType}',
      );
      exitCode = 1;
    } finally {
      client.close(force: true);
      for (final value in [identifier, salt, key, password]) {
        value.fillRange(0, value.length, 0);
      }
    }
  }
}
