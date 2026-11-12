import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Test-only recovery records. Native swap JSON never reaches a plaintext file.
final class EncryptedSwapStore {
  final Directory directory;
  final String scope;
  final Uint8List _key;
  final Random _random = Random.secure();

  EncryptedSwapStore({
    required this.directory,
    required this.scope,
    required Uint8List key,
  }) : _key = Uint8List.fromList(key) {
    if (key.length != 32 || scope.isEmpty) {
      throw ArgumentError('A scoped 256-bit fixture key is required');
    }
  }

  File _file(String name) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(name)) {
      throw ArgumentError('Invalid recovery record name');
    }
    return File('${directory.path}/$name.state');
  }

  GCMBlockCipher _cipher(bool encrypt, Uint8List nonce, String name) =>
      GCMBlockCipher(AESEngine())..init(
        encrypt,
        AEADParameters(
          KeyParameter(_key),
          128,
          nonce,
          Uint8List.fromList(utf8.encode('bull-regtest:$scope:$name')),
        ),
      );

  Future<void> write(String name, String value) async {
    final file = _file(name);
    final nonce = Uint8List.fromList(
      List.generate(12, (_) => _random.nextInt(256)),
    );
    final encrypted = _cipher(
      true,
      nonce,
      name,
    ).process(Uint8List.fromList(utf8.encode(value)));
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsBytes([1, ...nonce, ...encrypted], flush: true);
    await temporary.rename(file.path);
  }

  Future<String> read(String name) async {
    final packet = await _file(name).readAsBytes();
    if (packet.length < 29 || packet.first != 1) {
      throw StateError('Invalid encrypted recovery record');
    }
    try {
      final nonce = Uint8List.sublistView(packet, 1, 13);
      final plaintext = _cipher(
        false,
        nonce,
        name,
      ).process(Uint8List.sublistView(packet, 13));
      return utf8.decode(plaintext);
    } on InvalidCipherTextException {
      throw StateError('Recovery record authentication failed');
    } on FormatException {
      throw StateError('Invalid encrypted recovery payload');
    }
  }

  /// Reserve the next index durably before sending a creation request.
  Future<BigInt> allocateIndex({int count = 1}) async {
    if (count != 1 && count != 2) {
      throw ArgumentError('Reserve one key or a chain swap key pair');
    }
    final previous = await _file('counter').exists()
        ? BigInt.parse(await read('counter'))
        : BigInt.zero;
    final next = previous + BigInt.from(count);
    if (previous < BigInt.zero || next > BigInt.from(0x7fffffff)) {
      throw StateError('Recovery fixture key index exhausted');
    }
    await write('counter', next.toString());
    return previous;
  }

  void dispose() => _key.fillRange(0, _key.length, 0);
}
