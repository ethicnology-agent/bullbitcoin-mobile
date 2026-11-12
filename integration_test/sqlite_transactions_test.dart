import 'package:bb_mobile/core/storage/sqlite_database.dart';
import 'package:bb_mobile/core/transactions/domain/transaction_port.dart';
import 'package:bb_mobile/locator.dart';
import 'package:bb_mobile/core/wallet/domain/repositories/wallet_utxo_repository.dart';
import 'support/integration_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> main({bool isInitialized = false}) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (!isInitialized) await IntegrationHarness.init();

  final sqlite = locator<SqliteDatabase>();
  final transactionPort = locator<TransactionPort>();

  var txid = 'ff47a0a1dfdcf68327242d2cbfb229a5ba7e3e67572c2d4f390c51b1a89d56e5';

  setUp(() async => await sqlite.clearCacheTables());

  tearDownAll(() {});
  group('Sqlite Integration Tests', () {
    setUpAll(() async {
      if (IntegrationHarness.isRegtest) {
        final wallet = await IntegrationHarness.fundedWallet();
        final coins = await locator<WalletUtxoRepository>().getWalletUtxos(
          walletId: wallet.id,
        );
        expect(coins, isNotEmpty);
        txid = coins.first.txId;
        await sqlite.clearCacheTables();
      }
    });
    test('Ensure the repository works', () async {
      // Ensure the tx does not exists in sqlite
      var sqliteTx = await sqlite.managers.transactions
          .filter((e) => e.txid(txid))
          .getSingleOrNull();
      expect(sqliteTx, isNull);

      // Fetch a transaction and cache it in sqlite if not present
      final tx = await transactionPort.fetch(txid: txid);
      expect(tx.txid, txid);

      // Ensure the tx is now stored in sqlite
      sqliteTx = await sqlite.managers.transactions
          .filter((e) => e.txid(tx.txid))
          .getSingleOrNull();
      expect(sqliteTx, isNotNull);
      expect(tx.txid, sqliteTx!.txid);
    });
  });
}
