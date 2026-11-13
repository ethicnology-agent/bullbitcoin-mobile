import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart';
import 'package:bb_mobile/features/settings/domain/settings_entity.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/locator.dart';
import 'package:bull_recoverbull/bull_recoverbull.dart' as rb;
import 'package:bull_tor/tor.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primitives/primitives.dart' show Ok, Err;
import 'package:recoverbull/recoverbull.dart';
import 'package:secrets/secrets.dart';

import 'integration_harness.dart';

Future<void> restoreLocalRecoverbull() async {
  final socket = await Socket.connect(
    '127.0.0.1',
    59051,
    timeout: const Duration(seconds: 5),
  );
  try {
    socket.add([5, 1, 0]);
    final response = await socket
        .expand<int>((bytes) => bytes)
        .take(2)
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(response, [5, 0]);
  } finally {
    socket.destroy();
  }
  final source = await IntegrationHarness.generateSecret();
  final backup = switch (await source.backup.recoverbull()) {
    Ok(:final value) => value,
    Err(:final failure) => fail(
      'Vault creation failed: ${failure.runtimeType}',
    ),
  };
  final recoverbull = locator<rb.RecoverBullFacade>();
  final vault = switch (recoverbull.parseVault(backup.vault.json)) {
    Ok(:final value) => value,
    Err(:final failure) => fail('Vault parsing failed: ${failure.runtimeType}'),
  };
  final configured = switch (await recoverbull.settings()) {
    Ok(:final value) => value,
    Err(:final failure) => fail(
      'Vault settings failed: ${failure.runtimeType}',
    ),
  };
  expect(configured.server, Uri.parse('http://regtest.recoverbull.onion:3000'));
  if (await recoverbull.acceptServer(configured.server) case Err(
    :final failure,
  )) {
    fail('Vault consent failed: ${failure.runtimeType}');
  }

  // Only fixture provisioning uses the low-level client. Recovery exercises
  // the mounted facade, durable admission, selected route and Secrets import.
  final random = Random.secure();
  final password = base64UrlEncode(
    List.generate(32, (_) => random.nextInt(256)),
  );
  final identifier = Uint8List.fromList(hex.decode(vault.id));
  final salt = Uint8List.fromList(hex.decode(vault.salt));
  final key = Uint8List.fromList(hex.decode(backup.key.hex));
  final passwordBytes = Uint8List.fromList(utf8.encode(password));
  final client = locator<TorHttpClientFactory>().create(
    TorProxyEndpoint(host: '127.0.0.1', port: 59051),
  )..connectionTimeout = const Duration(seconds: 5);
  final fixture = KeyServer(address: configured.server, client: client);
  final settings = locator<SettingsRepository>();
  final before = await settings.fetch();
  var stored = false;
  var proxyChanged = false;
  try {
    await fixture.storeBackupKey(
      backupId: identifier,
      password: passwordBytes,
      backupKey: key,
      salt: salt,
    );
    stored = true;
    await IntegrationHarness.clearDefaultWalletsForRestore();
    if (await locator<Secrets>().trash(source.id) case Err(:final failure)) {
      fail('Fixture removal failed: ${failure.runtimeType}');
    }
    final proxy = await settings.setTorProxy(enabled: true, port: 59051);
    if (proxy case Err(:final failure)) {
      fail('Fixture proxy selection failed: ${failure.runtimeType}');
    }
    proxyChanged = true;
    final completion = switch (await recoverbull.recoverFromServer(
      vault: vault,
      password: password,
    )) {
      Ok(:final value) => value,
      Err(:final failure) => fail(
        'Vault restoration failed: ${failure.runtimeType}',
      ),
    };
    expect(completion.recovery, isA<rb.VaultRecovered>());
    expect(completion.warning, isNull);
    expect(completion.verifiedContext?.fingerprint, source.id);
    expect(completion.verifiedContext?.network, rb.BitcoinNetwork.regtest);
    final wallets = switch (await locator<WalletRepository>().getWallets(
      environment: Environment.regtest,
    )) {
      Ok(:final value) =>
        value
            .where((wallet) => wallet.masterFingerprint == source.id.hex)
            .toList(),
      Err(:final failure) => fail(
        'Restored wallet lookup failed: ${failure.runtimeType}',
      ),
    };
    IntegrationHarness.ownWallets(wallets);
    expect(wallets, hasLength(2));
    expect(
      wallets.every(
        (wallet) =>
            wallet.network.environment == Environment.regtest.networkEnv,
      ),
      isTrue,
    );
  } finally {
    try {
      if (stored) {
        final removed = await fixture.trashBackupKey(
          backupId: identifier,
          password: passwordBytes,
          salt: salt,
        );
        removed.fillRange(0, removed.length, 0);
      }
    } finally {
      client.close(force: true);
      for (final bytes in [identifier, salt, key, passwordBytes]) {
        bytes.fillRange(0, bytes.length, 0);
      }
      if (proxyChanged) {
        final restored = await settings.setTorProxy(
          enabled: before.useTorProxy,
          port: before.torProxyPort,
        );
        if (restored case Err(:final failure)) {
          fail('Fixture proxy cleanup failed: ${failure.runtimeType}');
        }
      }
    }
  }
}
