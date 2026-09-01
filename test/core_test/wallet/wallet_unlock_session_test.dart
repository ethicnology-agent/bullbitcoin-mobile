import 'dart:typed_data';

import 'package:bb_mobile/core/seed/domain/entity/seed.dart';
import 'package:bb_mobile/core/wallet/domain/services/wallet_unlock_session.dart';
import 'package:bb_mobile/core/wallet/domain/wallet_error.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  MnemonicSeed seed(String passphrase) =>
      Seed.mnemonic(
            mnemonicWords: const ['abandon'],
            passphrase: passphrase,
            bytes: Uint8List.fromList([1]),
            masterFingerprint: '00000001',
          )
          as MnemonicSeed;

  test('keeps only one unlocked wallet and clears it on lock', () async {
    final session = WalletUnlockSession();
    addTearDown(session.close);

    final first = seed('first secret');
    session.unlock(walletId: 'first', seed: first);
    expect(session.seedFor('first').passphrase, 'first secret');

    final second = seed('second secret');
    session.unlock(walletId: 'second', seed: second);
    expect(first.bytes, everyElement(0));
    expect(session.isUnlocked('first'), isFalse);
    expect(
      () => session.seedFor('first'),
      throwsA(isA<PassphraseWalletLockedException>()),
    );
    expect(session.seedFor('second').passphrase, 'second secret');

    expect(session.lock(), isTrue);
    expect(second.bytes, everyElement(0));
    expect(session.unlockedWalletId, isNull);
    expect(
      () => session.seedFor('second'),
      throwsA(isA<PassphraseWalletLockedException>()),
    );
    expect(session.lock(), isFalse);
  });
}
