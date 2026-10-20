import 'package:bb_mobile/core/exchange/domain/entity/exchange_rate.dart';
import 'package:bb_mobile/core/exchange/domain/exchange_rate_failure.dart';
import 'package:bb_mobile/core/exchange/domain/usecases/get_exchange_rate_usecase.dart';
import 'package:bb_mobile/core/wallet/domain/entities/wallet.dart';
import 'package:bb_mobile/features/pay/domain/calculate_pay_absolute_fees_usecase.dart';
import 'package:bb_mobile/features/pay/domain/estimate_pay_payin_fees_usecase.dart';
import 'package:bb_mobile/features/pay/domain/get_pay_payin_address_usecase.dart';
import 'package:bb_mobile/features/pay/domain/load_pay_network_fees_usecase.dart';
import 'package:bb_mobile/features/pay/domain/pay_failure.dart';
import 'package:bb_mobile/features/pay/domain/prepare_pay_bitcoin_payin_usecase.dart';
import 'package:bb_mobile/features/pay/domain/prepare_pay_liquid_payin_usecase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:primitives/primitives.dart';

class _Rate extends Mock implements GetExchangeRateUsecase {}

class _Address extends Mock implements GetPayPayinAddressUsecase {}

class _Fees extends Mock implements LoadPayNetworkFeesUsecase {}

class _Bitcoin extends Mock implements PreparePayBitcoinPayinUsecase {}

class _Liquid extends Mock implements PreparePayLiquidPayinUsecase {}

class _AbsoluteFees extends Mock implements CalculatePayAbsoluteFeesUsecase {}

class _Wallet extends Mock implements Wallet {}

void main() {
  late _Rate rate;
  late _Address address;
  late _Wallet wallet;
  late EstimatePayPayinFeesUsecase usecase;

  setUp(() {
    rate = _Rate();
    address = _Address();
    wallet = _Wallet();
    usecase = EstimatePayPayinFeesUsecase(
      getExchangeRateUsecase: rate,
      getPayPayinAddressUsecase: address,
      loadPayNetworkFeesUsecase: _Fees(),
      preparePayBitcoinPayinUsecase: _Bitcoin(),
      preparePayLiquidPayinUsecase: _Liquid(),
      calculatePayAbsoluteFeesUsecase: _AbsoluteFees(),
    );
  });

  test(
    'a rejected authenticated price is a Pay failure before wallet access',
    () async {
      when(() => rate.execute(currencyCode: 'CAD')).thenAnswer(
        (_) async => const Err(ExchangeRateLimitedFailure(retryAfter: '60')),
      );
      final result = await usecase.execute(
        wallet: wallet,
        fiatAmount: 100,
        currencyCode: 'CAD',
      );
      expect(
        (result as Err<PayPayinFeeEstimate, PayFailure>).failure,
        isA<PayUnexpectedFailure>(),
      );
      verifyNever(() => address.execute(walletId: any(named: 'walletId')));
    },
  );

  test(
    'the balance estimate uses the index price rather than user spread',
    () async {
      when(() => rate.execute(currencyCode: 'CAD')).thenAnswer(
        (_) async => Ok(
          ExchangeRate(
            currencyCode: 'CAD',
            indexPrice: 100000,
            userPrice: 97000,
          ),
        ),
      );
      when(() => wallet.id).thenReturn('wallet-1');
      when(() => wallet.balanceSat).thenReturn(BigInt.from(100000));
      const missingAddress = PayUnexpectedFailure('Address unavailable');
      when(
        () => address.execute(walletId: 'wallet-1'),
      ).thenAnswer((_) async => const Err(missingAddress));
      final result = await usecase.execute(
        wallet: wallet,
        fiatAmount: 100,
        currencyCode: 'CAD',
      );
      expect(
        (result as Err<PayPayinFeeEstimate, PayFailure>).failure,
        same(missingAddress),
      );
      verify(() => address.execute(walletId: 'wallet-1')).called(1);
    },
  );
}
