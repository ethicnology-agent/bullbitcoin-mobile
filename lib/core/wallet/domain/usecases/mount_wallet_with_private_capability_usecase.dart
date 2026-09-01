import 'package:bb_mobile/core/seed/domain/entity/seed.dart';
import 'package:bb_mobile/core/wallet/data/repositories/wallet_repository.dart';
import 'package:bb_mobile/core/wallet/data/wallet_signing_material_resolver.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet_definition.dart';

/// Materializes a wallet's public projection and hands the wallet domain the
/// temporary signing capability that goes with it (spec 20.4, 20.5).
///
/// The capability is loaded last: a conflicting definition must leave no
/// private material behind, and a caller that never reaches this use case
/// keeps ownership of its own candidate seed.
final class MountWalletWithPrivateCapabilityUsecase {
  final WalletRepository _wallets;
  final WalletSigningMaterialResolver _resolver;

  const MountWalletWithPrivateCapabilityUsecase(this._wallets, this._resolver);

  Future<WalletDefinitionRestoreResult> execute({
    required WalletDefinition definition,
    required MnemonicSeed seed,
    String? label,
  }) async {
    final result = await _wallets.restoreWalletDefinition(definition);
    if (result.status == WalletDefinitionRestoreStatus.conflict) return result;

    if (label != null) {
      await _wallets.updateWalletLabel(
        walletId: definition.walletRef,
        label: label,
      );
    }
    _resolver.loadPrivateCapability(walletId: definition.walletRef, seed: seed);
    return result;
  }
}
