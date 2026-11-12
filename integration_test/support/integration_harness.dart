import 'dart:io';

import 'package:bb_mobile/core/storage/sqlite_database.dart';
import 'package:bb_mobile/features/wallet/public/wallet_facade.dart';
import 'package:bb_mobile/features/settings/domain/settings_entity.dart';
import 'package:bb_mobile/features/wallet/data/wallet_native_runtime.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_address_repository.dart';
import 'package:bb_mobile/core/wallet/domain/repositories/wallet_utxo_repository.dart';
import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bb_mobile/init.dart';
import 'package:bb_mobile/locator.dart';
import 'package:bb_mobile/native_libraries.dart';
import 'package:drift/native.dart';
import 'package:bull_payjoin/bull_payjoin.dart';
import 'package:bull_logger/bull_logger.dart';
import 'package:bull_pricer/bull_pricer.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:primitives/primitives.dart' show Ok, Err;
import 'package:secrets/secrets.dart';

import 'regtest_controller.dart';

/// One suite owner; isolation precedes native wallet and custody construction.
abstract final class IntegrationHarness {
  static const isRegtest = bool.fromEnvironment('BULL_REGTEST_VALIDATION');
  static final controller = RegtestController();
  static bool _initialized = false;
  static final List<Secret> _ownedSecrets = [];
  static final List<String> _ownedWalletIds = [];
  static late String _payjoinPath;

  static Future<Secret> generateSecret() async {
    if (!isRegtest || !_initialized) {
      throw StateError('An isolated regtest run is required');
    }
    final secret = switch (await locator<Secrets>().generate()) {
      Ok(:final value) => value,
      Err(:final failure) => throw StateError(
        'Regtest custody creation failed: ${failure.runtimeType}',
      ),
    };
    ownSecret(secret);
    return secret;
  }

  static void ownSecret(Secret secret) {
    if (!isRegtest || !_initialized) {
      throw StateError('An isolated regtest run is required');
    }
    if (!_ownedSecrets.any((owned) => owned.id == secret.id)) {
      _ownedSecrets.add(secret);
    }
  }

  static void ownWallets(Iterable<Wallet> wallets) {
    if (!isRegtest || !_initialized) {
      throw StateError('An isolated regtest run is required');
    }
    for (final wallet in wallets) {
      if (!_ownedWalletIds.contains(wallet.id)) _ownedWalletIds.add(wallet.id);
    }
  }

  /// RecoverBull restores defaults; the earlier BIP85 fixture owns that slot.
  static Future<void> clearDefaultWalletsForRestore() async {
    if (!isRegtest || !_initialized) {
      throw StateError('An isolated regtest run is required');
    }
    final repository = locator<WalletRepository>();
    final defaults = switch (await repository.getWallets(
      onlyDefaults: true,
      environment: Environment.regtest,
    )) {
      Ok(:final value) => value,
      Err(:final failure) => throw StateError(
        'Default fixture lookup failed: ${failure.runtimeType}',
      ),
    };
    for (final wallet in defaults) {
      if (!wallet.isDefault ||
          (wallet.network != Network.bitcoinRegtest &&
              wallet.network != Network.liquidRegtest) ||
          !_ownedWalletIds.contains(wallet.id)) {
        throw StateError('Cannot remove an unowned default-wallet fixture');
      }
      final result = await repository.deleteWallet(walletId: wallet.id);
      if (result case Err(:final failure)) {
        throw StateError(
          'Default fixture removal failed: ${failure.runtimeType}',
        );
      }
      _ownedWalletIds.remove(wallet.id);
    }
  }

  static Future<Wallet> fundedWallet({bool liquid = false}) async {
    if (!isRegtest || !_initialized) {
      throw StateError('A running isolated regtest harness is required');
    }
    final repository = locator<WalletRepository>();
    final wallet = await newWallet(liquid: liquid);
    // Two separate outputs support manual coin selection and concurrency tests.
    for (var index = 0; index < 2; index++) {
      final receive = await locator<WalletAddressRepository>()
          .generateNewReceiveAddress(walletId: wallet.id);
      await controller.fund(
        address: receive.address,
        amountSat: 100000,
        liquid: liquid,
      );
    }
    await controller.mine(liquid: liquid);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(deadline)) {
      final read = await repository.getWallet(wallet.id, sync: true);
      if (read case Ok(
        :final value,
      ) when (value.balanceSat ?? BigInt.zero) >= BigInt.from(200000)) {
        final coins = await locator<WalletUtxoRepository>().getWalletUtxos(
          walletId: wallet.id,
        );
        if (coins.length >= 2 &&
            coins.every((coin) => coin.confirmations > 0)) {
          return value;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    throw StateError('The app did not observe its confirmed faucet funding');
  }

  static Future<Wallet> newWallet({bool liquid = false}) async {
    final secret = await generateSecret();
    final repository = locator<WalletRepository>();
    final wallet = await repository.createWallet(
      secret: secret,
      network: liquid ? Network.liquidRegtest : Network.bitcoinRegtest,
      scriptType: ScriptType.bip84,
    );
    _ownedWalletIds.add(wallet.id);
    return wallet;
  }

  static Future<void> init() async {
    if (_initialized) return;
    if (!isRegtest) {
      await Bull.init();
      _initialized = true;
      return;
    }
    if (!kDebugMode) {
      throw StateError('Regtest integration requires a debug runner');
    }
    if (Platform.isAndroid) {
      final package = await PackageInfo.fromPlatform();
      if (package.packageName != 'com.bullbitcoin.mobile.regtest.debug') {
        throw StateError(
          'Regtest integration requires its dedicated application',
        );
      }
    } else if (Platform.isLinux) {
      await _verifyLinuxIsolation();
    } else {
      throw StateError(
        'No isolated regtest runner is configured for this platform',
      );
    }
    await controller.verify();
    final parent = await getTemporaryDirectory();
    // The logger outlives the disposable DB directory; retain support logs in
    // this isolated application's cache, without a reporting destination.
    final logs = await Directory(
      p.join(parent.path, 'regtest-integration-logs'),
    ).create(recursive: true);
    await initializeLogging(directory: logs);
    final run = await Directory(parent.path).createTemp('wallet-integration-');
    final database = SqliteDatabase(
      NativeDatabase(File(p.join(run.path, 'app.sqlite'))),
    );
    // Materialize and seed the run-owned DB before any consumer is registered.
    await database.customSelect('SELECT 1').getSingle();
    await database.customStatement(
      "UPDATE settings SET environment = 'regtest', is_superuser = 1, "
      'is_dev_mode_enabled = 1, use_tor_proxy = 0, is_error_reporting_enabled = 0',
    );
    await database.customStatement(
      "UPDATE recoverbull SET url = 'http://regtest.recoverbull.onion:3000'",
    );
    // An accidental historical-network call must fail locally, never fall
    // back to a public chain service seeded for normal app installations.
    await database.customStatement(
      "DELETE FROM electrum_servers WHERE network NOT IN ('bitcoinRegtest', 'liquidRegtest')",
    );
    await database.customStatement('DELETE FROM mempool_servers');
    await initFlutterRustBridgeDependencies();
    await Pricer.init(
      databasePath: p.join(run.path, 'pricer.sqlite'),
      regtestEndpoint: Uri.parse('http://127.0.0.1:8088'),
    );
    _payjoinPath = p.join(run.path, 'payjoin.sqlite');
    await AppLocator.setup(
      locator,
      database,
      payjoinDatabasePath: _payjoinPath,
      startPayjoinRecovery: false,
      startOrderSwapWatcher: false,
      startAutoswapWatcher: false,
      startSpWatchers: false,
    );
    await initializeWalletRuntime(locator);
    _initialized = true;
    tearDownAll(() async {
      try {
        await locator<PayjoinLifecycle>().dispose();
        for (final walletId in _ownedWalletIds) {
          final removed = await locator<WalletRepository>().deleteWallet(
            walletId: walletId,
          );
          if (removed case Err(:final failure)) {
            throw StateError(
              'Regtest wallet cleanup failed: ${failure.runtimeType}',
            );
          }
        }
        _ownedWalletIds.clear();
        await locator<WalletNativeRuntime>().close();
        for (final secret in _ownedSecrets) {
          final removed = await locator<Secrets>().trash(secret.id);
          if (removed case Err(:final failure)) {
            throw StateError(
              'Regtest custody cleanup failed: ${failure.runtimeType}',
            );
          }
        }
        _ownedSecrets.clear();
        await Pricer.close();
        await locator.reset();
        await database.close();
        await run.delete(recursive: true);
        _initialized = false;
      } finally {
        await log.flush();
      }
    });
  }

  static Future<void> _verifyLinuxIsolation() async {
    final root = Platform.environment['BULL_REGTEST_RUN_DIRECTORY'];
    if (root == null || await Directory(root).resolveSymbolicLinks() != root) {
      throw StateError('Use the private Linux regtest runner');
    }
    final status = await FileStat.stat(root);
    final owner = await Process.run('stat', ['-c', '%u', root]);
    final user = await Process.run('id', ['-u']);
    if (status.type != FileSystemEntityType.directory ||
        (status.mode & 0x3f) != 0 ||
        owner.exitCode != 0 ||
        user.exitCode != 0 ||
        owner.stdout != user.stdout) {
      throw StateError(
        'The Linux integration directory must be private and owned',
      );
    }
    for (final (name, child) in [
      ('XDG_DATA_HOME', 'data'),
      ('XDG_CONFIG_HOME', 'config'),
      ('XDG_CACHE_HOME', 'cache'),
      ('XDG_RUNTIME_DIR', 'runtime'),
      ('TMPDIR', 'tmp'),
    ]) {
      final expected = p.join(root, child);
      if (Platform.environment[name] != expected ||
          await Directory(expected).resolveSymbolicLinks() != expected) {
        throw StateError('The Linux integration paths are not isolated');
      }
    }
    final bus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'] ?? '';
    final expectedBus = 'unix:path=$root/bus';
    if (bus != expectedBus && !bus.startsWith('$expectedBus,guid=')) {
      throw StateError('The Linux integration bus is not private');
    }
    for (final directory in [
      await getApplicationDocumentsDirectory(),
      await getApplicationSupportDirectory(),
      await getTemporaryDirectory(),
    ]) {
      final actual = await directory.resolveSymbolicLinks();
      if (!p.isWithin(root, actual)) {
        throw StateError(
          'A platform data directory escaped the integration runner',
        );
      }
    }
  }
}
