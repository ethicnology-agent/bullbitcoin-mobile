import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../../integration_test/support/encrypted_swap_store.dart';

void main() {
  late Directory directory;
  late Uint8List key;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('encrypted-swap-test-');
    final random = Random.secure();
    key = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
  });
  tearDown(() async {
    key.fillRange(0, key.length, 0);
    await directory.delete(recursive: true);
  });

  test(
    'reopens encrypted recovery state without reusing an allocated index',
    () async {
      final first = EncryptedSwapStore(
        directory: directory,
        scope: 'regtest-fixture',
        key: key,
      );
      expect(await first.allocateIndex(), BigInt.zero);
      await first.write('swap', 'public-cleartext-marker');
      first.dispose();
      final ciphertext = await File(
        '${directory.path}/swap.state',
      ).readAsBytes();
      expect(
        String.fromCharCodes(ciphertext).contains('public-cleartext-marker'),
        isFalse,
      );
      final reopened = EncryptedSwapStore(
        directory: directory,
        scope: 'regtest-fixture',
        key: key,
      );
      try {
        expect(await reopened.read('swap'), 'public-cleartext-marker');
        expect(await reopened.allocateIndex(), BigInt.one);
        expect(await reopened.allocateIndex(count: 2), BigInt.two);
        expect(await reopened.allocateIndex(), BigInt.from(4));
      } finally {
        reopened.dispose();
      }
    },
  );

  test(
    'tampering and moving recovery state across scopes fail authentication',
    () async {
      final store = EncryptedSwapStore(
        directory: directory,
        scope: 'regtest-fixture',
        key: key,
      );
      final other = EncryptedSwapStore(
        directory: directory,
        scope: 'other-fixture',
        key: key,
      );
      try {
        await store.write('swap', 'public-cleartext-marker');
        await expectLater(other.read('swap'), throwsStateError);
        final file = File('${directory.path}/swap.state');
        final ciphertext = await file.readAsBytes();
        ciphertext.last ^= 1;
        await file.writeAsBytes(ciphertext, flush: true);
        await expectLater(store.read('swap'), throwsStateError);
      } finally {
        store.dispose();
        other.dispose();
      }
    },
  );
}
