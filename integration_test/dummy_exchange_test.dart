import 'package:bb_mobile/core/exchange/data/datasources/bullbitcoin_api_datasource.dart';
import 'package:bb_mobile/core/exchange/domain/entity/order.dart';
import 'package:bb_mobile/features/swap/data/datasources/exchange_public_api_datasource.dart';
import 'package:bb_mobile/features/swap/domain/entities/order_swap_network.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/integration_harness.dart';

Future<void> main({bool isInitialized = false}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!isInitialized) await IntegrationHarness.init();
  group(
    'dummy exchange interaction simulation',
    () {
      late Dio http;
      late BullbitcoinApiDatasource accountApi;
      late ExchangePublicApiDatasource swapApi;
      setUp(() async {
        http = Dio(
          BaseOptions(baseUrl: 'http://127.0.0.1:8088', followRedirects: false),
        );
        accountApi = BullbitcoinApiDatasource(bullbitcoinApiHttpClient: http);
        swapApi = ExchangePublicApiDatasource(http);
        await http.post<void>('/__scenario', data: {'scenario': 'pending'});
      });
      tearDown(() => http.close(force: true));
      test(
        'dummy account deserializes through the BULL account model',
        () async {
          final account = await accountApi.getUserSummary();
          expect(account, isNotNull);
          expect(account!.toEntity().email, 'developer@example.invalid');
          expect(account.autoBuy.isActive, isFalse);
          expect(account.payjoinReceiveEnabled, isFalse);
        },
      );

      test(
        'all directed swap pairs deserialize through the actual API',
        () async {
          for (final input in OrderSwapNetwork.values) {
            for (final output in OrderSwapNetwork.values) {
              if (input == output) continue;
              final quote = await swapApi.getBestSwapOption(
                amountSat: BigInt.from(100000),
                isInAmountFixed: true,
                inNetwork: input,
                outNetwork: output,
              );
              expect(quote.inAmount, '0.001');
              expect(quote.outAmount, '0.00099');
              final order = await swapApi.createOrderSwap(
                amountSat: BigInt.from(100000),
                isInAmountFixed: true,
                inNetwork: input,
                outNetwork: output,
                destinationAddress: 'simulated-destination',
                fallbackAddress: null,
              );
              expect(order.payinAmount, '0.001');
              expect(order.orderStatus, 'Awaiting confirmation');
              await http.post<void>(
                '/__scenario',
                data: {'scenario': 'completed'},
              );
              final completed = await swapApi.getOrderSwapSummary(
                order.orderId,
              );
              expect(completed.orderStatus, 'Completed');
              expect(completed.completedAt, isNotNull);
              await http.post<void>(
                '/__scenario',
                data: {'scenario': 'pending'},
              );
            }
          }
        },
      );

      test('buy and confirmation use the real BULL enums', () async {
        final order = await accountApi.createBuyOrder(
          fiatCurrency: FiatCurrency.cad,
          orderAmount: const BitcoinAmount(0.001),
          network: OrderBitcoinNetwork.bitcoin,
          isOwner: true,
          address: 'simulated-destination',
        );
        expect(order.toEntity(isTestnet: true), isA<BuyOrder>());
        expect(
          order.toEntity(isTestnet: true).orderStatus,
          OrderStatus.awaitingConfirmation,
        );
        final confirmed = await accountApi.confirmOrder(orderId: order.orderId);
        expect(
          confirmed.toEntity(isTestnet: true).orderStatus,
          OrderStatus.inProgress,
        );
        final another = await accountApi.createBuyOrder(
          fiatCurrency: FiatCurrency.cad,
          orderAmount: const BitcoinAmount(0.001),
          network: OrderBitcoinNetwork.bitcoin,
          isOwner: true,
          address: 'simulated-destination',
        );
        expect(another.orderId, isNot(order.orderId));
      });
    },
    skip: IntegrationHarness.isRegtest
        ? null
        : 'Requires the local dummy exchange',
  );
}
