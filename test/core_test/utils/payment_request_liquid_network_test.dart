import 'package:bb_mobile/features/wallet/domain/wallet.dart';
import 'package:bb_mobile/features/send/domain/usecases/detect_bitcoin_string_usecase.dart';
import 'package:primitives/primitives.dart' as primitives;
import 'package:bb_mobile/core/utils/payment_request.dart';
import 'package:bull_sdk/lwk.dart' as lwk;
import 'package:bull_sdk/src/rust/frb_generated.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Sdk extends Mock implements BullSdkApi {}

void main() {
  final sdk = _Sdk();
  // Public address derived from a synthetic script and blinding public key.
  const address =
      'el1qqfumuen7l8wthtz45p3ftn58pvrs9xlumvkuu2xet8egzkcklqtesg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyqsscuw9qrf4q';

  setUpAll(() => BullSdk.initMock(api: sdk));
  tearDownAll(BullSdk.dispose);

  test('does not classify a Liquid regtest address as mainnet', () async {
    when(
      () => sdk.lwkApiTypesAddressValidate(addressString: address),
    ).thenAnswer((_) async => lwk.LiquidNetwork.regtest);

    final request = await PaymentRequest.parse(address);
    expect(
      request,
      isA<Bip21PaymentRequest>().having(
        (r) => r.network,
        'network',
        Network.liquidRegtest,
      ),
    );
    expect(
      await DetectBitcoinStringUsecase().execute(
        data: address,
        environment: primitives.NetworkEnv.regtest,
      ),
      isA<Bip21PaymentRequest>().having(
        (r) => r.network,
        'network',
        Network.liquidRegtest,
      ),
    );
    for (final environment in [
      primitives.NetworkEnv.mainnet,
      primitives.NetworkEnv.testnet,
    ]) {
      await expectLater(
        DetectBitcoinStringUsecase().execute(
          data: address,
          environment: environment,
        ),
        throwsFormatException,
      );
    }
  });
  for (final (network, testnet) in [
    (lwk.LiquidNetwork.mainnet, false),
    (lwk.LiquidNetwork.testnet, true),
  ]) {
    test('preserves historical Liquid ${network.name} parsing', () async {
      when(
        () => sdk.lwkApiTypesAddressValidate(addressString: address),
      ).thenAnswer((_) async => network);
      expect(
        await PaymentRequest.parse(address),
        isA<LiquidPaymentRequest>().having(
          (r) => r.isTestnet,
          'isTestnet',
          testnet,
        ),
      );
    });
  }
  test('does not trust a regtest prefix over the validated network', () async {
    when(
      () => sdk.lwkApiTypesAddressValidate(addressString: address),
    ).thenAnswer((_) async => lwk.LiquidNetwork.mainnet);
    await expectLater(
      DetectBitcoinStringUsecase().execute(
        data: address,
        environment: primitives.NetworkEnv.regtest,
      ),
      throwsFormatException,
    );
  });
}
