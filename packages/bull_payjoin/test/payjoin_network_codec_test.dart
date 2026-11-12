import 'package:bull_payjoin/src/data/payjoin_network_codec.dart';
import 'package:primitives/primitives.dart';
import 'package:test/test.dart';

void main() {
  for (final (network, code, testnet) in [
    (BitcoinNetwork.mainnet, 'mainnet', false),
    (BitcoinNetwork.testnet, 'testnet', true),
    (BitcoinNetwork.regtest, 'regtest', true),
  ]) {
    test('round-trips $code without collapsing its environment', () {
      expect(PayjoinNetworkCodec.encode(network), code);
      expect(PayjoinNetworkCodec.decode(code, testnet), network);
      expect(
        () => PayjoinNetworkCodec.decode(code, !testnet),
        throwsFormatException,
      );
    });
  }
  test('rejects sentinel, unknown and unsupported stored networks', () {
    for (final code in ['', 'unknown', 'signet']) {
      for (final testnet in [true, false]) {
        expect(
          () => PayjoinNetworkCodec.decode(code, testnet),
          throwsFormatException,
        );
      }
    }
    expect(
      () => PayjoinNetworkCodec.encode(BitcoinNetwork.signet),
      throwsFormatException,
    );
  });
}
