import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:bb_mobile/core/recoverbull/domain/entity/encrypted_vault.dart';
import 'package:bb_mobile/core/recoverbull/domain/recoverbull_tor_route.dart';
import 'package:bb_mobile/core/recoverbull/domain/repositories/recoverbull_repository.dart';
import 'package:bb_mobile/core/recoverbull/domain/usecases/fetch_vault_key_from_server_usecase.dart';
import 'package:bb_mobile/core/recoverbull/domain/usecases/restore_vault_usecase.dart';
import 'package:bb_mobile/core/recoverbull/domain/usecases/store_vault_key_into_server_usecase.dart';
import 'package:bb_mobile/features/settings/domain/settings_entity.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/locator.dart';
import 'package:bull_tor/tor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:primitives/primitives.dart' show Ok, Err;
import 'package:secrets/secrets.dart' hide EncryptedVault;

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
  final route = RecoverBullTorRoute(
    TorRoute(
      source: TorSource.external,
      endpoint: TorProxyEndpoint(host: '127.0.0.1', port: 59051),
      evidence: TorReadinessEvidence.externalSocksHandshake,
    ),
    () async {},
  );
  final source = await IntegrationHarness.generateSecret();
  final backup = switch (await source.backup.recoverbull()) {
    Ok(:final value) => value,
    Err(:final failure) => fail(
      'Vault creation failed: ${failure.runtimeType}',
    ),
  };
  final vault = EncryptedVault(file: backup.vault.json);
  final random = Random.secure();
  final password = base64UrlEncode(
    List.generate(32, (_) => random.nextInt(256)),
  );
  final repository = locator<RecoverBullRepository>();
  var stored = false;
  try {
    final store = await locator<StoreVaultKeyIntoServerUsecase>().execute(
      password: password,
      vault: vault,
      vaultKey: backup.key.hex,
      route: route,
    );
    if (store case Err(:final failure)) {
      fail('Local key storage failed: ${failure.runtimeType}');
    }
    stored = true;
    final fetched = await locator<FetchVaultKeyFromServerUsecase>().execute(
      vault: vault,
      password: password,
      route: route,
    );
    final key = switch (fetched) {
      Ok(:final value) => value,
      Err(:final failure) => fail(
        'Local key retrieval failed: ${failure.runtimeType}',
      ),
    };
    // Compare as a boolean: an assertion must never render a vault key.
    expect(key == backup.key.hex, isTrue);
    await IntegrationHarness.clearDefaultWalletsForRestore();
    final removed = await locator<Secrets>().trash(source.id);
    if (removed case Err(:final failure)) {
      fail('Fixture removal failed: ${failure.runtimeType}');
    }
    final restored = await locator<RestoreVaultUsecase>().execute(
      vault: vault,
      vaultKey: key,
    );
    if (restored case Err(:final failure)) {
      fail('Vault restoration failed: ${failure.runtimeType}');
    }
    final result = await locator<WalletRepository>().getWallets(
      environment: Environment.regtest,
    );
    final wallets = switch (result) {
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
    if (stored) {
      await repository.trashVaultKey(
        vault.id,
        password,
        vault.salt,
        route.endpoint,
      );
    }
    await route.close();
  }
}
