import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:drift/native.dart' show SqliteException;
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'dart:io';
import 'dart:typed_data';

import 'package:bull_payjoin/bull_payjoin.dart';
import 'package:primitives/primitives.dart';
import 'package:test/test.dart';

final class _WalletPort implements PayjoinWalletPort {
  @override
  Future<bool Function(Uint8List script)> createOwnershipChecker({
    required String walletId,
    required BitcoinNetwork network,
  }) async =>
      (Uint8List _) => false;

  @override
  Future<bool Function(Outpoint outpoint)> createOutpointOwnershipChecker({
    required String walletId,
    required BitcoinNetwork network,
  }) async =>
      (Outpoint _) => false;

  @override
  Future<String> signPsbt({
    required String walletId,
    required BitcoinNetwork network,
    required String psbt,
  }) async => psbt;

  @override
  Future<List<PayjoinUtxo>> spendableUtxos({
    required String walletId,
    required BitcoinNetwork network,
  }) async => const [];
}

final class _BlockchainPort implements PayjoinBlockchainPort {
  @override
  Future<void> broadcastPsbt({
    required BitcoinNetwork network,
    required String psbt,
  }) async {}

  @override
  Future<void> broadcastTransaction({
    required BitcoinNetwork network,
    required Uint8List transaction,
  }) async {}
}

final class _TransactionPort implements PayjoinTransactionPort {
  @override
  Future<bool> isTransactionVisible({
    required String walletId,
    required String transactionId,
    bool refresh = false,
  }) async => false;

  @override
  Future<void> refreshWallet(String walletId) async {}

  @override
  Stream<void> watchWallet(String walletId) => const Stream.empty();
}

final class _FeesPort implements PayjoinFeesPort {
  @override
  Future<FeeRate> fastestFeeRate({required BitcoinNetwork network}) async =>
      FeeRate(10);
}

final class _LabelsPort implements PayjoinLabelsPort {
  @override
  Future<void> labelTransaction({
    required String walletId,
    required String transactionId,
  }) async {}
}

final class _LegacyData implements PayjoinLegacyDataPort {
  const _LegacyData();

  @override
  Future<PayjoinLegacySnapshot> readSnapshot() async =>
      const PayjoinLegacySnapshot(
        sourceSchemaVersion: 14,
        senders: [],
        receivers: [],
      );
}

final class _LogPort implements PayjoinLogPort {
  final List<PayjoinLogEvent> events = [];

  @override
  void write(PayjoinLogEvent event) => events.add(event);
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('payjoin-runtime-');
  });

  tearDown(() => directory.delete(recursive: true));

  Future<Result<PayjoinLifecycle, PayjoinFailure>> open({PayjoinLogPort? log}) {
    return openPayjoin(
      databasePath: '${directory.path}/payjoin.sqlite',
      wallet: _WalletPort(),
      blockchain: _BlockchainPort(),
      fees: _FeesPort(),
      transactions: _TransactionPort(),
      labels: _LabelsPort(),
      legacyData: const _LegacyData(),
      log: log ?? _LogPort(),
    );
  }

  test(
    'writer contention preserves the active database and reserved inputs',
    () async {
      const psbt =
          'cHNidP8BAFICAAAAARERERERERERERERERERERERERERERERERERERERERERAAAAAAD9////'
          'AaCGAQAAAAAAFgAUIiIiIiIiIiIiIiIiIiIiIiIiIiIAAAAAAAEBH2iHAQAAAAAAFgAUMzMz'
          'MzMzMzMzMzMzMzMzMzMzMzMAAA==';
      final initial = switch (await open()) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
      await initial.dispose();
      final path = '${directory.path}/payjoin.sqlite';
      final held = sqlite.sqlite3.open(path);
      held.execute(
        'INSERT INTO payjoin_senders '
        '(uri,is_testnet,sender,wallet_id,original_psbt,original_tx_id,amount_sat,'
        'created_at,expire_after_sec,is_expired,is_completed,is_aborted) '
        "VALUES ('bitcoin:tb1qreserved?pj=https://payjo.in',1,'[]','wallet',?,'original',10000,?,3600,0,0,0)",
        [psbt, DateTime.now().millisecondsSinceEpoch ~/ 1000],
      );

      held.execute('PRAGMA journal_mode = DELETE');
      held.execute('BEGIN EXCLUSIVE');
      try {
        final log = _LogPort();
        final result = await open(log: log);
        expect(
          log.events.any((event) {
            Object? cause = event.error;
            while (cause is DriftRemoteException) {
              cause = cause.remoteCause;
            }
            return cause is SqliteException && (cause.resultCode & 0xff) == 5;
          }),
          isTrue,
          reason: 'A real SQLite lock must cause the refusal',
        );

        if (result case Ok(:final value)) await value.dispose();
        expect(
          result,
          isA<Err<PayjoinLifecycle, PayjoinFailure>>().having(
            (r) => r.failure,
            'failure',
            isA<PayjoinMigrationFailure>(),
          ),
        );
        expect(
          directory.listSync().where((f) => f.path.contains('.unreadable-')),
          isEmpty,
        );
      } finally {
        held.dispose();
      }
      final restored = switch (await open()) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
      addTearDown(restored.dispose);
      expect(
        await restored.payjoin.sessions.reservedOutpoints(),
        isA<Ok<Set<Outpoint>, PayjoinFailure>>().having(
          (r) => r.value,
          'reserved inputs',
          contains((txId: '11' * 32, vout: 0)),
        ),
      );
      final check = sqlite.sqlite3.open(path);

      try {
        final row = check
            .select('SELECT original_psbt,sender FROM payjoin_senders')
            .single;
        expect(row['original_psbt'], psbt);
        expect(row['sender'], '[]');
      } finally {
        check.dispose();
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a future schema is refused without replacing its data', () async {
    final warnings = <String>[];
    final previousPrinter = driftRuntimeOptions.debugPrint;
    driftRuntimeOptions.debugPrint = warnings.add;
    addTearDown(() => driftRuntimeOptions.debugPrint = previousPrinter);
    final initial = switch (await open()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    await initial.dispose();
    final path = '${directory.path}/payjoin.sqlite';
    final raw = sqlite.sqlite3.open(path);
    raw.execute('CREATE TABLE future_sentinel (value TEXT NOT NULL)');
    raw.execute("INSERT INTO future_sentinel VALUES ('retained')");
    raw.execute('PRAGMA journal_mode = DELETE');
    raw.execute('PRAGMA user_version = 99');
    raw.dispose();
    final before = File(path).readAsBytesSync();
    for (var attempt = 0; attempt < 3; attempt++) {
      final result = await open();
      if (result case Ok(:final value)) await value.dispose();
      expect(result, isA<Err<PayjoinLifecycle, PayjoinFailure>>());
    }
    expect(
      warnings,
      isEmpty,
      reason: 'Every rejected setup must close its database handle',
    );
    expect(
      directory.listSync().where((f) => f.path.contains('.unreadable-')),
      isEmpty,
    );
    expect(File(path).readAsBytesSync(), before);
    final check = sqlite.sqlite3.open(path);
    try {
      expect(check.select('PRAGMA user_version').single['user_version'], 99);
      expect(
        check.select('SELECT value FROM future_sentinel').single['value'],
        'retained',
      );
    } finally {
      check.dispose();
    }
  });

  test('a sender that cannot start says why in the log', () async {
    final log = _LogPort();
    final lifecycle = switch (await open(log: log)) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    addTearDown(lifecycle.dispose);

    final result = await lifecycle.payjoin.sender.start(
      StartPayjoinSender(
        walletId: 'wallet-1',
        network: BitcoinNetwork.testnet,
        bip21Uri: 'bitcoin:tb1qnopayjoinendpoint?amount=0.001',
        unsignedOriginalPsbt: 'cHNidP8=',
        amount: Sats.fromInt(100000),
        feeRate: FeeRate(2),
      ),
    );

    expect(result, isA<Err<PayjoinSenderSession, PayjoinFailure>>());
    final event = log.events.singleWhere(
      (event) => event.code == PayjoinLogCode.sessionStartFailed,
    );
    expect(event.level, PayjoinLogLevel.warning);
    expect(event.role, PayjoinLogRole.sender);
    expect(event.error, isNotNull);
  });

  test('opens roles over the seeded policy and disposes cleanly', () async {
    final result = await open();
    final lifecycle = switch (result) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };

    final policy = await lifecycle.payjoin.policy.load();

    // Nothing to migrate: the root settings payjoin columns only existed in
    // the unreleased schema 14, so a freshly opened payjoin database starts on
    // the defaults, receiving from users disabled.
    final loaded = switch (policy) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    final defaults = PayjoinPolicy.defaults();
    expect(loaded.receiveEnabled, defaults.receiveEnabled);
    expect(loaded.receiveEnabled, isFalse);
    expect(loaded.sendEnabled, isTrue);
    expect(loaded.buyEnabled, isTrue);
    expect(loaded.sellEnabled, isTrue);
    expect(loaded.minimumAmount.value, defaults.minimumAmount.value);
    expect(loaded.sessionLifetime, defaults.sessionLifetime);

    final invalidMinimum = await lifecycle.payjoin.policy.setMinimumAmount(
      Sats.fromInt(500),
    );
    expect(switch (invalidMinimum) {
      Ok() => null,
      Err(:final failure) => failure,
    }, isA<PayjoinInvalidInputFailure>());
    await lifecycle.dispose();
  });
}
