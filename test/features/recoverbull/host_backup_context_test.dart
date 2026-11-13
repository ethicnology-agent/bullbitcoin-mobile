import 'package:bb_mobile/core/settings/data/settings_repository.dart';
import 'package:bb_mobile/features/backup_settings/domain/read_backup_status_usecase.dart';
import 'package:bb_mobile/features/settings/domain/settings_entity.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/features/wallet/domain/usecases/check_backup_needed_usecase.dart';
import 'package:bb_mobile/features/wallet/domain/usecases/get_wallets_usecase.dart';
import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bull_recoverbull/bull_recoverbull.dart' as rb;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:primitives/primitives.dart' hide Network, ScriptType;

class _Settings extends Mock implements SettingsRepository {}

class _Wallets extends Mock implements WalletRepository {}

class _ReadWallets extends Mock implements GetWalletsUsecase {}

class _Wallet extends Mock implements Wallet {}

void main() {
  final environments = {
    Environment.mainnet: (Network.bitcoinMainnet, BitcoinNetwork.mainnet),
    Environment.testnet: (Network.bitcoinTestnet, BitcoinNetwork.testnet),
    Environment.regtest: (Network.bitcoinRegtest, BitcoinNetwork.regtest),
  };
  Wallet wallet(Network network, String fingerprint) {
    final value = _Wallet();
    when(() => value.network).thenReturn(network);
    when(() => value.masterFingerprint).thenReturn(fingerprint);
    when(() => value.isPhysicalBackupTested).thenReturn(false);
    when(() => value.latestPhysicalBackup).thenReturn(null);
    when(() => value.latestEncryptedBackup).thenReturn(null);
    return value;
  }

  for (final entry in environments.entries) {
    final settings = _Settings();
    when(settings.fetch).thenAnswer(
      (_) async => SettingsEntity(
        environment: entry.key,
        bitcoinUnit: BitcoinUnit.sats,
        currencyCode: 'CAD',
      ),
    );

    test(
      'backup warning certifies the exact ${entry.key.name} context',
      () async {
        final repository = _Wallets();
        when(
          () =>
              repository.getWallets(onlyDefaults: true, environment: entry.key),
        ).thenAnswer((_) async => Ok([wallet(entry.value.$1, 'deadbeef')]));
        final usecase = CheckBackupNeededUsecase(
          walletRepository: repository,
          settingsRepository: settings,
          backupStatus: (context) async {
            expect(context.network, entry.value.$2);
            expect(context.fingerprint, Fingerprint('deadbeef'));
            return Ok(rb.BackupStatus(verifiedAt: DateTime.utc(2026)));
          },
        );
        expect(
          await usecase.execute(),
          isA<Ok>().having((r) => r.value, 'backup needed', isFalse),
        );
      },
    );

    test(
      'backup settings selects only the exact ${entry.key.name} context',
      () async {
        final read = _ReadWallets();
        final other = entry.key == Environment.mainnet
            ? Network.bitcoinRegtest
            : Network.bitcoinMainnet;
        when(() => read.execute(onlyDefaults: true)).thenAnswer(
          (_) async => Ok([
            wallet(other, '01234567'),
            wallet(entry.value.$1, 'deadbeef'),
          ]),
        );
        final usecase = ReadBackupStatusUsecase(read, settings, (
          context,
        ) async {
          expect(context.network, entry.value.$2);
          expect(context.fingerprint, Fingerprint('deadbeef'));
          return Ok(rb.BackupStatus(verifiedAt: DateTime.utc(2026)));
        });
        expect(
          await usecase.execute(),
          isA<Ok>().having(
            (r) => (r.value as BackupStatusSummary).encryptedVerified,
            'encrypted backup verified',
            isTrue,
          ),
        );
      },
    );
  }
}
