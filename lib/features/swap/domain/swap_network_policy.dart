import 'package:primitives/primitives.dart';

bool swapEnvironmentAvailable(NetworkEnv environment) =>
    (environment == NetworkEnv.mainnet || environment == NetworkEnv.testnet) &&
    NetworkCapabilities.supports(switch (environment) {
      NetworkEnv.mainnet => BitcoinNetwork.mainnet,
      NetworkEnv.testnet => BitcoinNetwork.testnet,
      NetworkEnv.regtest => BitcoinNetwork.regtest,
      NetworkEnv.signet => BitcoinNetwork.signet,
    }, NetworkCapability.swaps);
