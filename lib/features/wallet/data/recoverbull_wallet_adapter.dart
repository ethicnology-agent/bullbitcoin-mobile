import 'package:bb_mobile/features/wallet/domain/wallet.dart' show Network;
import 'package:bb_mobile/features/wallet/domain/network_x.dart';
import 'package:bb_mobile/core/settings/domain/repositories/settings_repository.dart';
import 'package:bb_mobile/features/wallet/data/wallet_repository.dart';
import 'package:bb_mobile/features/wallet/domain/usecases/create_default_wallets_usecase.dart';
import 'package:bull_logger/bull_logger.dart';
import 'package:bull_recoverbull/bull_recoverbull.dart';
import 'package:secrets/secrets.dart' show Secrets, KeystoreLockedFailure;

final class RecoverBullWalletAdapter implements RecoverBullWalletPort {
  final WalletRepository _wallets;
  final SettingsRepository _settings;
  final Secrets _secrets;
  final CreateDefaultWalletsUsecase _create;

  const RecoverBullWalletAdapter(
    this._wallets,
    this._settings,
    this._secrets,
    this._create,
  );

  @override
  Future<Result<VaultContext?, RecoverBullFailure>> currentDefault() async {
    try {
      final settings = await _settings.fetch();
      switch (await _wallets.getWallets(
        onlyBitcoin: true,
        onlyDefaults: true,
        environment: settings.environment,
      )) {
        case Err():
          return const Err(VaultStorageFailure());
        case Ok(:final value):
          if (value.isEmpty) return const Ok(null);
          if (value.length != 1) return const Err(VaultContextChangedFailure());
          final wallet = value.single;
          return Ok(
            VaultContext(
              fingerprint: Fingerprint(wallet.masterFingerprint),
              network: wallet.network.bitcoin,
            ),
          );
      }
    } on Exception {
      log.warning('recoverbull.wallet.read.failed');
      return const Err(VaultStorageFailure());
    }
  }

  @override
  Future<Result<VaultContext, RecoverBullFailure>> restoreDefaults(
    VaultContext requested,
  ) async {
    try {
      final settings = await _settings.fetch();
      if (Network.fromEnvironment(
            environment: settings.environment.networkEnv,
            isLiquid: false,
          ).bitcoin !=
          requested.network) {
        return const Err(VaultContextChangedFailure());
      }
      final fetched = await _secrets.fetch(requested.fingerprint);
      switch (fetched) {
        case Err(failure: KeystoreLockedFailure()):
          return const Err(VaultKeystoreLockedFailure());
        case Err():
          return const Err(VaultStorageFailure());
        case Ok(:final value):
          final created = await _create.execute(
            secret: value,
            expectedNetwork: settings.environment.networkEnv,
          );
          final bitcoin = created
              .where((wallet) => wallet.network.isBitcoin)
              .toList();
          if (bitcoin.length != 1) {
            return const Err(VaultContextChangedFailure());
          }
          final wallet = bitcoin.single;
          // Return the actual committed context. The feature compares it with
          // the request and never certifies a different network or fingerprint.
          return Ok(
            VaultContext(
              fingerprint: Fingerprint(wallet.masterFingerprint),
              network: wallet.network.bitcoin,
            ),
          );
      }
    } on Exception {
      log.warning('recoverbull.wallet.restore.failed');
      return const Err(VaultStorageFailure());
    }
  }
}
