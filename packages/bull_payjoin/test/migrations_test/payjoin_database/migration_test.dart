import 'fixtures/evidence_only_v3.dart' as v3e;
import 'package:bull_payjoin/src/data/payjoin_model.dart';
import 'package:primitives/primitives.dart' show BitcoinNetwork;
// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:bull_payjoin/src/data/payjoin_database.dart';
import 'package:test/test.dart';
import 'generated/schema.dart';

import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = PayjoinDatabase.forTesting(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  // Schema 1 shipped with one switch that gated both sending and receiving
  // between users. After the upgrade both of those keep its value, the
  // exchange switches start on, and existing receivers stay user receivers.
  for (final enabled in [1, 0]) {
    test('migration from v1 to v2 keeps enabled=$enabled for send and '
        'receive', () async {
      final oldPayjoinPoliciesData = <v1.PayjoinPoliciesData>[
        v1.PayjoinPoliciesData(
          id: 1,
          enabled: enabled,
          minimumAmountSat: 12345,
          sessionLifetimeSeconds: 3600,
        ),
      ];
      final expectedNewPayjoinPoliciesData = <v2.PayjoinPoliciesData>[
        v2.PayjoinPoliciesData(
          id: 1,
          enabled: enabled,
          sendEnabled: enabled,
          buyEnabled: 1,
          sellEnabled: 1,
          minimumAmountSat: 12345,
          sessionLifetimeSeconds: 3600,
        ),
      ];

      final oldPayjoinReceiversData = <v1.PayjoinReceiversData>[
        const v1.PayjoinReceiversData(
          id: 'receiver-1',
          address: 'bc1qexample',
          isTestnet: 0,
          receiver: '[]',
          walletId: 'wallet-1',
          pjUri: 'bitcoin:bc1qexample?pj=https://payjo.in/abc',
          maxFeeRateSatPerVb: 20,
          createdAt: 1700000000,
          expireAfterSec: 86400,
          isExpired: 0,
          isCompleted: 0,
          isAborted: 0,
        ),
      ];
      final expectedNewPayjoinReceiversData = <v2.PayjoinReceiversData>[
        const v2.PayjoinReceiversData(
          id: 'receiver-1',
          address: 'bc1qexample',
          isTestnet: 0,
          receiver: '[]',
          walletId: 'wallet-1',
          pjUri: 'bitcoin:bc1qexample?pj=https://payjo.in/abc',
          maxFeeRateSatPerVb: 20,
          createdAt: 1700000000,
          expireAfterSec: 86400,
          isExpired: 0,
          isCompleted: 0,
          isAborted: 0,
          isTrade: 0,
        ),
      ];

      final oldPayjoinSendersData = <v1.PayjoinSendersData>[];
      final expectedNewPayjoinSendersData = <v2.PayjoinSendersData>[];

      final oldPayjoinMigrationsData = <v1.PayjoinMigrationsData>[];
      final expectedNewPayjoinMigrationsData = <v2.PayjoinMigrationsData>[];

      await verifier.testWithDataIntegrity(
        oldVersion: 1,
        newVersion: 2,
        createOld: v1.DatabaseAtV1.new,
        createNew: v2.DatabaseAtV2.new,
        openTestedDatabase: PayjoinDatabase.forTesting,
        createItems: (batch, oldDb) {
          batch.insertAll(oldDb.payjoinSenders, oldPayjoinSendersData);
          batch.insertAll(oldDb.payjoinReceivers, oldPayjoinReceiversData);
          batch.insertAll(oldDb.payjoinPolicies, oldPayjoinPoliciesData);
          batch.insertAll(oldDb.payjoinMigrations, oldPayjoinMigrationsData);
        },
        validateItems: (newDb) async {
          expect(
            expectedNewPayjoinSendersData,
            await newDb.select(newDb.payjoinSenders).get(),
          );
          expect(
            expectedNewPayjoinReceiversData,
            await newDb.select(newDb.payjoinReceivers).get(),
          );
          expect(
            expectedNewPayjoinPoliciesData,
            await newDb.select(newDb.payjoinPolicies).get(),
          );
          expect(
            expectedNewPayjoinMigrationsData,
            await newDb.select(newDb.payjoinMigrations).get(),
          );
        },
      );
    });
  }

  const insertSender =
      'INSERT INTO payjoin_senders '
      '(uri, is_testnet, sender, wallet_id, original_psbt, original_tx_id, '
      'amount_sat, created_at, expire_after_sec, proposal_psbt, tx_id, '
      'is_expired, is_completed, is_aborted) '
      "VALUES (?, 0, '[]', 'wallet-1', 'cHNidP8=', 'original-tx', 50000, "
      '1700000000, 86400, ?, ?, ?, ?, ?)';

  Future<void> seedSenders(v2.DatabaseAtV2 old) async {
    for (final (uri, proposal, expired, completed, aborted) in [
      ('unfinished-with-proposal', 'cHNidP8=', 0, 0, 0),
      ('unfinished-without-proposal', null, 0, 0, 0),
      ('expired', 'cHNidP8=', 1, 0, 0),
      ('completed', 'cHNidP8=', 0, 1, 0),
      ('aborted', null, 0, 0, 1),
    ]) {
      await old.customStatement(insertSender, [
        uri,
        proposal,
        if (proposal == null) null else 'payjoin-tx',
        expired,
        completed,
        aborted,
      ]);
    }
  }

  Future<Map<String, int>> evidenceByUri(PayjoinDatabase db) async => {
    for (final row in await db.select(db.payjoinSenders).get())
      row.uri: row.hasNetworkEvidence ? 1 : 0,
  };

  // Schema 2 kept no trace of a payment that went out without a recorded
  // outcome, so an unfinished sender cannot be told apart from one that never
  // attempted: it must migrate as holding evidence, never as free to release.
  test(
    'migration from v2 to v3 assumes evidence for unfinished senders',
    () async {
      final schema = await verifier.schemaAt(2);
      final old = v2.DatabaseAtV2(schema.newConnection());
      await seedSenders(old);
      await old.close();

      final db = PayjoinDatabase.forTesting(schema.newConnection());
      await verifier.migrateAndValidate(db, 3);

      expect(await evidenceByUri(db), {
        'unfinished-with-proposal': 1,
        'unfinished-without-proposal': 1,
        'expired': 0,
        'completed': 0,
        'aborted': 0,
      });
      final kept =
          await (db.select(db.payjoinSenders)
                ..where((row) => row.uri.equals('unfinished-with-proposal')))
              .getSingle();
      expect(kept.proposalPsbt, 'cHNidP8=');
      expect(kept.txId, 'payjoin-tx');
      expect(kept.originalTxId, 'original-tx');
      await db.close();
    },
  );

  test('re-running the v2 to v3 step never backfills again', () async {
    final schema = await verifier.schemaAt(2);
    final old = v2.DatabaseAtV2(schema.newConnection());
    await seedSenders(old);
    await old.close();
    final first = PayjoinDatabase.forTesting(schema.newConnection());
    await verifier.migrateAndValidate(first, 3);
    // What a session created after the upgrade, or a withdrawn attempt, holds.
    await first.customStatement(
      'UPDATE payjoin_senders SET has_network_evidence = 0',
    );
    await first.customStatement('PRAGMA user_version = 2');
    await first.close();

    final second = PayjoinDatabase.forTesting(schema.newConnection());
    await verifier.migrateAndValidate(second, 3);
    expect((await evidenceByUri(second)).values, everyElement(0));
    await second.close();
  });

  test('two connections reaching the v2 to v3 step together both '
      'open', () async {
    final directory = await Directory.systemTemp.createTemp('payjoin-v3-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/payjoin.sqlite');
    final old = v2.DatabaseAtV2(
      NativeDatabase(
        file,
        setup: (db) => db.execute('PRAGMA journal_mode = WAL;'),
      ),
    );
    await seedSenders(old);
    await old.close();

    // Each connection runs in its own isolate, like the app's: one waiting on
    // the other's write lock cannot stall the one that has to commit.
    final barrier = _AlterBarrier();
    PayjoinDatabase open() => PayjoinDatabase.forTesting(
      NativeDatabase.createInBackground(
        file,
        setup: (db) => db.execute('PRAGMA busy_timeout = 2000;'),
      ).interceptWith(barrier),
    );
    final first = open();
    final second = open();
    addTearDown(first.close);
    addTearDown(second.close);

    final evidence = await Future.wait([
      evidenceByUri(first),
      evidenceByUri(second),
    ]);

    // Both steps were inside the migration, about to add the column, at once.
    expect(barrier.arrivals, 2);
    const migrated = {
      'unfinished-with-proposal': 1,
      'unfinished-without-proposal': 1,
      'expired': 0,
      'completed': 0,
      'aborted': 0,
    };
    expect(evidence, [migrated, migrated]);
  });
  group('concrete network in pending v3', () {
    Future<File> legacyFile() async {
      final dir = await Directory.systemTemp.createTemp('payjoin-network-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/sessions.sqlite');
      final old = v3e.DatabaseAtV3(NativeDatabase(file));
      for (final (name, testnet, evidence) in [
        ('main-clear', 0, 0),
        ('main-evidence', 0, 1),
        ('test-clear', 1, 0),
        ('test-evidence', 1, 1),
      ]) {
        await old.customStatement(
          'INSERT INTO payjoin_senders '
          '(uri,is_testnet,sender,wallet_id,original_psbt,original_tx_id,'
          'amount_sat,created_at,expire_after_sec,is_expired,is_completed,'
          'is_aborted,has_network_evidence) '
          "VALUES (?,?,'opaque-state','wallet','opaque-psbt','original',10000,10,3600,0,0,0,?)",
          [name, testnet, evidence],
        );
        await old.customStatement(
          'INSERT INTO payjoin_receivers '
          '(id,address,is_testnet,receiver,wallet_id,pj_uri,max_fee_rate_sat_per_vb,'
          'created_at,expire_after_sec,is_expired,is_completed,is_aborted,is_trade) '
          "VALUES (?,'address',?,'receiver-state','wallet','bitcoin:fixture',20,10,3600,0,0,0,0)",
          [name, testnet],
        );
      }
      await old.close();
      return file;
    }

    Future<void> verify(PayjoinDatabase db) async {
      final senders = await db.select(db.payjoinSenders).get();
      final receivers = await db.select(db.payjoinReceivers).get();
      expect(senders, hasLength(4));
      expect(receivers, hasLength(4));
      for (final row in senders) {
        expect(row.network, row.uri.startsWith('main') ? 'mainnet' : 'testnet');
        expect(row.hasNetworkEvidence, row.uri.endsWith('evidence'));
        expect(row.sender, 'opaque-state');
        expect(row.originalPsbt, 'opaque-psbt');
        expect(row.originalTxId, 'original');
        expect(row.amountSat, 10000);
        expect(row.createdAt, 10);
        expect(row.expireAfterSec, 3600);
      }
      for (final row in receivers) {
        expect(row.network, row.id.startsWith('main') ? 'mainnet' : 'testnet');
        expect(row.receiver, 'receiver-state');
        expect(row.isTrade, isFalse);
      }
      expect(
        (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
          'user_version',
        ),
        3,
      );
    }

    test(
      'repairs evidence-only v3 without changing evidence or protocol',
      () async {
        final file = await legacyFile();
        for (var pass = 0; pass < 3; pass++) {
          final db = PayjoinDatabase.open(file.path);
          try {
            await verify(db);
            if (pass == 0) {
              await db.customStatement(
                "UPDATE payjoin_senders SET network='regtest' WHERE uri='test-clear'",
              );
              expect(
                (await db.select(db.payjoinSenders).get())
                    .singleWhere((r) => r.uri == 'test-clear')
                    .hasNetworkEvidence,
                isFalse,
              );
              await db.customStatement(
                "UPDATE payjoin_senders SET network='testnet' WHERE uri='test-clear'",
              );
            }
          } finally {
            await db.close();
          }
        }
      },
    );

    test(
      'reopening retains a stored concrete regtest rather than backfilling again',
      () async {
        final file = await legacyFile();
        final first = PayjoinDatabase.open(file.path);
        await verify(first);
        await first.customStatement(
          "UPDATE payjoin_senders SET network='regtest' WHERE uri='test-clear'",
        );
        await first.customStatement(
          "UPDATE payjoin_receivers SET network='regtest' WHERE id='test-clear'",
        );
        await first.close();
        final second = PayjoinDatabase.open(file.path);
        addTearDown(second.close);
        final sender = (await second.select(second.payjoinSenders).get())
            .singleWhere((r) => r.uri == 'test-clear');
        final receiver = (await second.select(second.payjoinReceivers).get())
            .singleWhere((r) => r.id == 'test-clear');
        expect(sender.network, 'regtest');
        expect(receiver.network, 'regtest');
        expect(sender.hasNetworkEvidence, isFalse);
        expect(
          PayjoinModel.fromSenderTable(sender).toEntity().network,
          BitcoinNetwork.regtest,
        );
        expect(
          PayjoinModel.fromReceiverTable(receiver).toEntity().network,
          BitcoinNetwork.regtest,
        );
      },
    );

    test(
      'network columns and backfills roll back together after interruption',
      () async {
        final file = await legacyFile();
        final failing = PayjoinDatabase.forTesting(
          NativeDatabase(file).interceptWith(_InterruptNetworkUpgrade()),
        );
        await expectLater(
          failing.customSelect('SELECT 1').get(),
          throwsA(anything),
        );
        await failing.close();
        final old = v3e.DatabaseAtV3(NativeDatabase(file));
        for (final table in ['payjoin_senders', 'payjoin_receivers']) {
          final cols = await old
              .customSelect('PRAGMA table_info($table)')
              .get();
          expect(
            cols.map((c) => c.read<String>('name')),
            isNot(contains('network')),
          );
        }
        expect(
          (await old
                  .customSelect(
                    'SELECT has_network_evidence FROM payjoin_senders '
                    "WHERE uri='test-clear'",
                  )
                  .getSingle())
              .read<int>('has_network_evidence'),
          0,
        );
        await old.close();
        final recovered = PayjoinDatabase.open(file.path);
        addTearDown(recovered.close);
        await verify(recovered);
      },
    );

    test('two connections repair old v3 without promoting evidence', () async {
      final file = await legacyFile();
      final barrier = _NetworkAlterBarrier();
      PayjoinDatabase open() => PayjoinDatabase.forTesting(
        NativeDatabase.createInBackground(
          file,
          setup: (db) => db.execute('PRAGMA busy_timeout = 2000;'),
        ).interceptWith(barrier),
      );
      final a = open();
      final b = open();
      addTearDown(a.close);
      addTearDown(b.close);
      await Future.wait([verify(a), verify(b)]);
      expect(barrier.arrivals, 2);
    });
  });
}

/// Routes the migration's own statements through [interceptor]: drift hands
/// `beforeOpen` the raw executor otherwise.
final class _MigrationUser implements QueryExecutorUser {
  final QueryExecutorUser _user;
  final QueryInterceptor _interceptor;

  _MigrationUser(this._user, this._interceptor);

  @override
  int get schemaVersion => _user.schemaVersion;

  @override
  Future<void> beforeOpen(QueryExecutor executor, OpeningDetails details) =>
      _user.beforeOpen(executor.interceptWith(_interceptor), details);
}

/// Holds every connection right before its `ALTER TABLE` until two are
/// there, so both have decided to migrate before either adds the column.
/// Fails the open instead of waiting forever when the second never arrives.
final class _AlterBarrier extends QueryInterceptor {
  final _both = Completer<void>();
  int arrivals = 0;

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      executor.ensureOpen(_MigrationUser(user, this));

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.startsWith('ALTER TABLE') &&
        statement.contains('has_network_evidence')) {
      arrivals++;
      if (arrivals == 2) _both.complete();
      await _both.future.timeout(const Duration(seconds: 10));
    }
    return executor.runCustom(statement, args);
  }
}

final class _InterruptNetworkUpgrade extends QueryInterceptor {
  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      executor.ensureOpen(_MigrationUser(user, this));
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    if (statement.startsWith('ALTER TABLE') &&
        statement.contains('payjoin_receivers') &&
        statement.contains('network')) {
      throw StateError('Injected migration interruption');
    }
    return executor.runCustom(statement, args);
  }
}

final class _NetworkAlterBarrier extends QueryInterceptor {
  final _both = Completer<void>();
  int arrivals = 0;
  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      executor.ensureOpen(_MigrationUser(user, this));
  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (statement.startsWith('ALTER TABLE') &&
        statement.contains('payjoin_senders') &&
        statement.contains('network')) {
      arrivals++;
      if (arrivals == 2) _both.complete();
      await _both.future.timeout(const Duration(seconds: 10));
    }
    return executor.runCustom(statement, args);
  }
}
