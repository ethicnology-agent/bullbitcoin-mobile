import 'fixtures/regtest_certificate.dart';
import 'package:bull_payjoin/src/data/payjoin_database.dart';
import 'package:bull_payjoin/src/data/local_payjoin_datasource.dart';
import 'package:bull_payjoin/src/data/payjoin_model.dart';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/isolate.dart' show DriftRemoteException;
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'migrations_test/payjoin_database/fixtures/evidence_only_v3.dart' as v3e;
import 'dart:typed_data';

import 'package:bull_payjoin/bull_payjoin.dart';
import 'package:primitives/primitives.dart';
import 'package:test/test.dart';

base class _WalletPort implements PayjoinWalletPort {
  int signingCalls = 0;
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
  }) async {
    signingCalls++;
    return psbt;
  }

  @override
  Future<List<PayjoinUtxo>> spendableUtxos({
    required String walletId,
    required BitcoinNetwork network,
  }) async => const [];
}

final class _BlockchainPort implements PayjoinBlockchainPort {
  @override
  Future<void> broadcastPsbt({
    required String walletId,
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
  final bool offline;

  _TransactionPort({this.offline = false});

  @override
  Future<bool> protectObservedSpend({
    required String walletId,
    required String transactionId,
  }) async => true;

  @override
  Future<bool> isTransactionVisible({
    required String walletId,
    required String transactionId,
    bool refresh = false,
  }) async => offline ? throw StateError('offline') : false;

  @override
  Future<void> refreshWallet(String walletId) async {}

  @override
  Stream<void> watchWallet(String walletId) => const Stream.empty();
}

final class _FeesPort implements PayjoinFeesPort {
  int calls = 0;
  @override
  Future<FeeRate> fastestFeeRate({required BitcoinNetwork network}) async {
    calls++;
    return FeeRate(10);
  }
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

final class _BusyWalletPort extends _WalletPort {
  @override
  Future<String> signPsbt({
    required String walletId,
    required BitcoinNetwork network,
    required String psbt,
  }) async => throw const PayjoinSpendBlockedException(busy: true);
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

  Future<Result<PayjoinLifecycle, PayjoinFailure>> open({
    PayjoinLogPort? log,
    bool offline = false,
    PayjoinWalletPort? wallet,
    _FeesPort? fees,
    PayjoinRegtestTransport? transport,
  }) {
    return openPayjoin(
      databasePath: '${directory.path}/payjoin.sqlite',
      regtestTransport: transport,
      wallet: wallet ?? _WalletPort(),
      blockchain: _BlockchainPort(),
      fees: fees ?? _FeesPort(),
      transactions: _TransactionPort(offline: offline),
      labels: _LabelsPort(),
      legacyData: const _LegacyData(),
      log: log ?? _LogPort(),
    );
  }

  for (final local in [false, true]) {
    test(
      'wrong-network requests fail before signing and fee lookup (local=$local)',
      () async {
        final wallet = _WalletPort();
        final fees = _FeesPort();
        final lifecycle = switch (await open(
          wallet: wallet,
          fees: fees,
          transport: local
              ? PayjoinRegtestTransport(
                  servers: [
                    Uri.parse('https://localhost:8040'),
                    Uri.parse('https://127.0.0.1:8041'),
                  ],
                  certificate: regtestCertificate(),
                )
              : null,
        )) {
          Ok(:final value) => value,
          Err(:final failure) => throw failure,
        };
        addTearDown(lifecycle.dispose);
        for (final action in [PayjoinAction.send, PayjoinAction.receive]) {
          expect(
            await lifecycle.payjoin.policy.setActionEnabled(
              action,
              enabled: true,
            ),
            isA<Ok<void, PayjoinFailure>>(),
          );
        }
        for (final network in [
          if (!local) BitcoinNetwork.regtest,
          BitcoinNetwork.mainnet,
          BitcoinNetwork.testnet,
        ]) {
          final sender = await lifecycle.payjoin.sender.start(
            StartPayjoinSender(
              walletId: 'regtest-wallet',
              network: network,
              bip21Uri: 'bitcoin:bcrt1qfixture?pj=https://localhost:8040/x',
              unsignedOriginalPsbt: 'must-not-be-signed',
              amount: Sats.fromInt(10000),
              feeRate: FeeRate(2),
            ),
          );
          final receiver = await lifecycle.payjoin.receiver.start(
            StartPayjoinReceiver(
              walletId: 'regtest-wallet',
              network: network,
              address: 'bcrt1qfixture',
            ),
          );
          expect(sender, isA<Err<PayjoinSenderSession, PayjoinFailure>>());
          expect(receiver, isA<Err<PayjoinReceiverSession, PayjoinFailure>>());
          if (sender case Err(:final failure)) {
            expect(failure, isA<PayjoinUnavailableFailure>());
          }
          if (receiver case Err(:final failure)) {
            expect(failure, isA<PayjoinUnavailableFailure>());
          }
          expect(wallet.signingCalls, 0);
          expect(fees.calls, 0);
        }
      },
    );
  }

  test(
    'a locked v3 repair fails closed without replacing its reservations',
    () async {
      final warnings = <String>[];
      final previousPrinter = driftRuntimeOptions.debugPrint;
      driftRuntimeOptions.debugPrint = warnings.add;
      addTearDown(() => driftRuntimeOptions.debugPrint = previousPrinter);
      const psbt =
          'cHNidP8BAFICAAAAARERERERERERERERERERERERERERERERERERERERERERAAAAAAD9////'
          'AaCGAQAAAAAAFgAUIiIiIiIiIiIiIiIiIiIiIiIiIiIAAAAAAAEBH2iHAQAAAAAAFgAUMzMz'
          'MzMzMzMzMzMzMzMzMzMzMzMAAA==';
      final path = '${directory.path}/payjoin.sqlite';
      final old = v3e.DatabaseAtV3(
        NativeDatabase(
          File(path),
          setup: (db) => db.execute('PRAGMA journal_mode=WAL'),
        ),
      );
      await old.customStatement(
        'INSERT INTO payjoin_senders '
        '(uri,is_testnet,sender,wallet_id,original_psbt,original_tx_id,amount_sat,'
        'created_at,expire_after_sec,is_expired,is_completed,is_aborted,has_network_evidence) '
        "VALUES ('bitcoin:tb1qreserved?pj=https://payjo.in',1,'[]','wallet',?,'original',10000,?,3600,0,0,0,1)",
        [psbt, DateTime.now().millisecondsSinceEpoch ~/ 1000],
      );
      // A running evidence-only v3 has already completed its one-shot import.
      await old.customStatement(
        'INSERT INTO payjoin_migrations '
        '(name,completed_at,source_schema_version,sender_count,receiver_count,verification_digest) '
        "VALUES ('root-payjoin-v1',0,14,0,0,'fixture-empty-import')",
      );
      final defaults = PayjoinPolicy.defaults();
      await old.customStatement(
        'INSERT INTO payjoin_policies '
        '(id,enabled,send_enabled,buy_enabled,sell_enabled,minimum_amount_sat,session_lifetime_seconds) '
        'VALUES (1,?,?,?,?,?,?)',
        [
          defaults.receiveEnabled ? 1 : 0,
          defaults.sendEnabled ? 1 : 0,
          defaults.buyEnabled ? 1 : 0,
          defaults.sellEnabled ? 1 : 0,
          defaults.minimumAmount.value.toInt(),
          defaults.sessionLifetime.inSeconds,
        ],
      );
      await old.close();
      final held = sqlite.sqlite3.open(path);
      held.execute('BEGIN IMMEDIATE');
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
          reason: 'The failure must be actual SQLite writer contention',
        );
        // Dispose even an incorrectly successful open before asserting Red.
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
      final rows = PayjoinDatabase.open(path);
      try {
        final row = await rows.select(rows.payjoinSenders).getSingle();
        expect(row.hasNetworkEvidence, isTrue);
        expect(row.originalPsbt, psbt);
        expect(row.network, 'testnet');
      } finally {
        await rows.close();
      }
      final reopened = switch (await open()) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
      addTearDown(reopened.dispose);
      final reserved = await reopened.payjoin.sessions.reservedOutpoints();
      expect(
        reserved,
        isA<Ok<Set<Outpoint>, PayjoinFailure>>().having(
          (r) => r.value,
          'reserved outpoints',
          contains((txId: '11' * 32, vout: 0)),
        ),
      );

      expect(
        warnings,
        isEmpty,
        reason: 'Failed opens must close their database connection',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('a future schema is refused without replacing its data', () async {
    final initial = switch (await open()) {
      Ok(:final value) => value,
      Err(:final failure) => throw failure,
    };
    await initial.dispose();
    final path = '${directory.path}/payjoin.sqlite';
    final future = sqlite.sqlite3.open(path);
    future.execute('CREATE TABLE future_sentinel (value TEXT NOT NULL)');
    future.execute("INSERT INTO future_sentinel VALUES ('retained')");
    future.execute('PRAGMA user_version = 4');
    future.dispose();
    final result = await open();
    if (result case Ok(:final value)) await value.dispose();
    expect(result, isA<Err<PayjoinLifecycle, PayjoinFailure>>());
    expect(
      directory.listSync().where((f) => f.path.contains('.unreadable-')),
      isEmpty,
    );
    final preserved = sqlite.sqlite3.open(path);
    try {
      expect(preserved.select('PRAGMA user_version').single['user_version'], 4);
      expect(
        preserved.select('SELECT value FROM future_sentinel').single['value'],
        'retained',
      );
    } finally {
      preserved.dispose();
    }
  });

  test(
    'confirmed non-SQLite corruption retains the existing recovery',
    () async {
      final path = '${directory.path}/payjoin.sqlite';
      const corrupt = 'deliberately not a SQLite file';
      await File(path).writeAsString(corrupt);
      final reopened = switch (await open()) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
      addTearDown(reopened.dispose);
      final archived = directory
          .listSync()
          .whereType<File>()
          .where((f) => f.path.contains('payjoin.sqlite.unreadable-'))
          .single;
      expect(await archived.readAsString(), corrupt);
      expect(
        await reopened.payjoin.policy.load(),
        isA<Ok<PayjoinPolicy, PayjoinFailure>>(),
      );
    },
  );

  test('a sender refused by a busy wallet says so', () async {
    final lifecycle = switch (await open(wallet: _BusyWalletPort())) {
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

    expect(
      result,
      isA<Err<PayjoinSenderSession, PayjoinFailure>>().having(
        (result) => result.failure,
        'failure',
        isA<PayjoinSpendBlockedFailure>().having((f) => f.busy, 'busy', isTrue),
      ),
    );
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

  test(
    'recovered paused proposal is typed in both session reads and events',
    () async {
      final initial = switch (await open()) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
      await initial.dispose();
      final database = PayjoinDatabase.open('${directory.path}/payjoin.sqlite');
      final model = PayjoinSenderModel(
        uri: 'bitcoin:tb1qsender?pj=https://payjo.in',
        network: BitcoinNetwork.testnet,
        sender: '[]',
        walletId: 'wallet-1',
        originalPsbt: 'cHNidP8=',
        originalTxId: 'original-tx',
        amountSat: 50000,
        createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 - 7200,
        expireAfterSec: 3600,
        proposalPsbt: 'cHNidP8=',
        txId: 'proposal-tx',
      );
      await LocalPayjoinDatasource(db: database).storeSender(model);
      await database.close();
      // Unknown visibility keeps an expired proposal paused, not released.
      final lifecycle = switch (await open(offline: true)) {
        Ok(:final value) => value,
        Err(:final failure) => throw failure,
      };
      addTearDown(lifecycle.dispose);
      final event = lifecycle.payjoin.sessions
          .watch(sessionIds: {model.id})
          .first;
      expect(await lifecycle.resume(), isA<Ok<void, PayjoinFailure>>());
      final update = switch (await event) {
        Ok(:final value) => value as PayjoinSenderSession,
        Err(:final failure) => throw failure,
      };
      expect(update.spendFailure, isA<PayjoinSpendBlockedFailure>());
      expect(update.isOngoing, isTrue);
      expect(update.canRetryProposal, isFalse);
      final read = switch (await lifecycle.payjoin.sessions.byId(model.id)) {
        Ok(:final value) => value as PayjoinSenderSession,
        Err(:final failure) => throw failure,
      };
      expect(read.spendFailure, isA<PayjoinSpendBlockedFailure>());
      expect(
        await lifecycle.payjoin.sender.retryProposal(model.id),
        isA<Err<PayjoinSession, PayjoinFailure>>(),
      );
    },
  );

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
