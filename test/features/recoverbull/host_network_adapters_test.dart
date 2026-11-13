import 'dart:io';

import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/core/storage/sqlite_database.dart';
import 'package:bb_mobile/features/settings/data/recoverbull_settings_adapter.dart';
import 'package:bb_mobile/features/settings/domain/settings_entity.dart';
import 'package:bb_mobile/features/wallet/data/recoverbull_wallet_adapter.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/features/wallet/domain/usecases/create_default_wallets_usecase.dart';
import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bull_recoverbull/bull_recoverbull.dart' as rb;
import 'package:bull_tor/tor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:primitives/primitives.dart' hide Network, ScriptType;
import 'package:secrets/secrets.dart';
import 'package:secrets/testing.dart';

class _Settings extends Mock implements SettingsRepository {}

class _Database extends Mock implements SqliteDatabase {}

class _Embedded extends Mock implements EmbeddedTor {}

class _Tor extends Mock implements Tor {}

class _Wallets extends Mock implements WalletRepository {}

class _Wallet extends Mock implements Wallet {}

class _Create extends Mock implements CreateDefaultWalletsUsecase {}

class _Store extends FakeSecureStoragePlatform {
  void Function()? onRead;

  @override
  Future<String?> read({
    required String key,
    required Map<String, String> options,
  }) {
    final callback = onRead;
    onRead = null;
    callback?.call();
    return super.read(key: key, options: options);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Settings settings;
  late _Wallets wallets;
  late _Create create;
  late _Store storage;
  late Secrets secrets;
  late Secret secret;
  late Directory scratch;
  var selected = Environment.regtest;
  final networks = {
    Environment.mainnet: (Network.bitcoinMainnet, BitcoinNetwork.mainnet),
    Environment.testnet: (Network.bitcoinTestnet, BitcoinNetwork.testnet),
    Environment.regtest: (Network.bitcoinRegtest, BitcoinNetwork.regtest),
  };

  Wallet wallet(Network network) {
    final value = _Wallet();
    when(() => value.network).thenReturn(network);
    when(() => value.masterFingerprint).thenReturn(secret.id.hex);
    return value;
  }

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp(
      'recoverbull-host-network-',
    );
    storage = _Store()..install();
    secrets = Secrets(scratchDirectory: () async => scratch.path);
    secret = (await secrets.generate() as Ok<Secret, SecretFailure>).value;
    registerFallbackValue(secret);
    registerFallbackValue(Network.bitcoinMainnet);
    settings = _Settings();
    wallets = _Wallets();
    create = _Create();
    selected = Environment.regtest;
    when(settings.fetch).thenAnswer(
      (_) async => SettingsEntity(
        environment: selected,
        bitcoinUnit: BitcoinUnit.sats,
        currencyCode: 'CAD',
      ),
    );
  });

  tearDown(() async {
    final removed = await secrets.trash(secret.id);
    expect(removed, isA<Ok>());
    await scratch.delete(recursive: true);
  });

  for (final entry in networks.entries) {
    test('RecoverBull settings preserves ${entry.key.name}', () async {
      selected = entry.key;
      final adapter = RecoverBullSettingsAdapter(
        settings,
        _Database(),
        _Embedded(),
        _Tor(),
      );
      expect(
        await adapter.currentNetwork(),
        isA<Ok<BitcoinNetwork, rb.RecoverBullFailure>>().having(
          (r) => r.value,
          'network',
          entry.value.$2,
        ),
      );
    });

    test('RecoverBull default context preserves ${entry.key.name}', () async {
      selected = entry.key;
      when(
        () => wallets.getWallets(
          onlyBitcoin: true,
          onlyDefaults: true,
          environment: entry.key,
        ),
      ).thenAnswer((_) async => Ok([wallet(entry.value.$1)]));
      final adapter = RecoverBullWalletAdapter(
        wallets,
        settings,
        secrets,
        create,
      );
      expect(
        await adapter.currentDefault(),
        isA<Ok<rb.VaultContext?, rb.RecoverBullFailure>>().having(
          (r) => r.value?.network,
          'network',
          entry.value.$2,
        ),
      );
    });

    test(
      'RecoverBull restore keeps ${entry.key.name} at the creation boundary',
      () async {
        selected = entry.key;
        final restored = [wallet(entry.value.$1)];
        when(
          () => create.execute(secret: any(named: 'secret')),
        ).thenAnswer((_) async => restored);
        when(
          () => create.execute(
            secret: any(named: 'secret'),
            expectedNetwork: entry.key.networkEnv,
          ),
        ).thenAnswer((_) async => restored);
        final adapter = RecoverBullWalletAdapter(
          wallets,
          settings,
          secrets,
          create,
        );
        final result = await adapter.restoreDefaults(
          rb.VaultContext(fingerprint: secret.id, network: entry.value.$2),
        );
        expect(
          result,
          isA<Ok<rb.VaultContext, rb.RecoverBullFailure>>()
              .having((r) => r.value.network, 'network', entry.value.$2)
              .having((r) => r.value.fingerprint, 'fingerprint', secret.id),
        );
        final received =
            verify(
                  () => create.execute(
                    secret: captureAny(named: 'secret'),
                    expectedNetwork: entry.key.networkEnv,
                  ),
                ).captured.single
                as Secret;
        expect(received.id, secret.id);
      },
    );
  }

  test(
    'RecoverBull refuses mainnet versus regtest before reading custody',
    () async {
      selected = Environment.mainnet;
      when(
        () => create.execute(secret: any(named: 'secret')),
      ).thenThrow(Exception('Creation must be fenced'));
      final reads = storage.reads;
      final adapter = RecoverBullWalletAdapter(
        wallets,
        settings,
        secrets,
        create,
      );
      final result = await adapter.restoreDefaults(
        rb.VaultContext(
          fingerprint: secret.id,
          network: BitcoinNetwork.regtest,
        ),
      );
      expect(
        result,
        isA<Err>().having(
          (r) => r.failure,
          'failure',
          isA<rb.VaultContextChangedFailure>(),
        ),
      );
      expect(storage.reads, reads);
      verifyZeroInteractions(create);
    },
  );

  test(
    'RecoverBull fences a network change while reading custody before creating wallets',
    () async {
      selected = Environment.regtest;
      var flipped = false;
      storage.onRead = () {
        selected = Environment.mainnet;
        flipped = true;
      };
      when(
        () => wallets.getWallets(
          onlyDefaults: true,
          environment: Environment.mainnet,
        ),
      ).thenAnswer((_) async => const Ok([]));
      when(
        () => wallets.createWallet(
          secret: any(named: 'secret'),
          network: any(named: 'network'),
          scriptType: ScriptType.bip84,
          isDefault: true,
          birthday: any(named: 'birthday'),
        ),
      ).thenThrow(Exception('Creation must be fenced'));
      final actualCreate = CreateDefaultWalletsUsecase(
        secrets: secrets,
        settingsRepository: settings,
        walletRepository: wallets,
      );
      final adapter = RecoverBullWalletAdapter(
        wallets,
        settings,
        secrets,
        actualCreate,
      );
      final result = await adapter.restoreDefaults(
        rb.VaultContext(
          fingerprint: secret.id,
          network: BitcoinNetwork.regtest,
        ),
      );
      expect(flipped, isTrue);
      expect(
        result,
        isA<Err>().having(
          (r) => r.failure,
          'failure',
          isA<rb.VaultStorageFailure>(),
        ),
      );
      verifyNever(
        () => wallets.createWallet(
          secret: any(named: 'secret'),
          network: any(named: 'network'),
          scriptType: ScriptType.bip84,
          isDefault: true,
          birthday: any(named: 'birthday'),
        ),
      );
    },
  );
}
