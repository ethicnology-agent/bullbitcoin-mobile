import 'package:primitives/primitives.dart';

/// Stable storage codes; legacy testnet is a compatibility projection only.
abstract final class PayjoinNetworkCodec {
  static String encode(BitcoinNetwork network) => switch (network) {
    BitcoinNetwork.mainnet => 'mainnet',
    BitcoinNetwork.testnet => 'testnet',
    BitcoinNetwork.regtest => 'regtest',
    BitcoinNetwork.signet => throw const FormatException(
      'Unsupported Payjoin network',
    ),
  };

  static BitcoinNetwork decode(String code, bool legacyTestnet) {
    final network = switch (code) {
      'mainnet' => BitcoinNetwork.mainnet,
      'testnet' => BitcoinNetwork.testnet,
      'regtest' => BitcoinNetwork.regtest,
      _ => throw const FormatException('Invalid stored Payjoin network'),
    };
    if (legacyTestnet != !network.isMainnet) {
      throw const FormatException('Inconsistent stored Payjoin network');
    }
    return network;
  }
}
