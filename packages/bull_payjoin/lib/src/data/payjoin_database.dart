import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:drift/isolate.dart' show DriftRemoteException;

import 'payjoin_database.steps.dart';
import 'migration_guards.dart';

part 'payjoin_database.g.dart';

@DataClassName('PayjoinSenderRow')
class PayjoinSenders extends Table {
  TextColumn get uri => text()();
  BoolColumn get isTestnet => boolean()();
  TextColumn get network => text().withDefault(const Constant(''))();
  TextColumn get sender => text()();
  TextColumn get walletId => text()();
  TextColumn get originalPsbt => text()();
  TextColumn get originalTxId => text()();
  IntColumn get amountSat => integer()();
  IntColumn get createdAt => integer()();
  IntColumn get expireAfterSec => integer()();
  TextColumn get proposalPsbt => text().nullable()();
  TextColumn get txId => text().nullable()();
  BoolColumn get isExpired => boolean()();
  BoolColumn get isCompleted => boolean()();
  BoolColumn get isAborted => boolean()();
  // A payment of this session may be on the network without a recorded
  // outcome: one of its transactions went to broadcast or was observed. Such
  // a session is never expired from a later negative lookup. Senders that
  // were unfinished when schema 3 arrived are assumed to hold it.
  BoolColumn get hasNetworkEvidence =>
      boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {uri};
}

@DataClassName('PayjoinReceiverRow')
class PayjoinReceivers extends Table {
  TextColumn get id => text()();
  TextColumn get address => text()();
  BoolColumn get isTestnet => boolean()();
  TextColumn get network => text().withDefault(const Constant(''))();
  TextColumn get receiver => text()();
  TextColumn get walletId => text()();
  TextColumn get pjUri => text()();
  Int64Column get maxFeeRateSatPerVb => int64()();
  IntColumn get createdAt => integer()();
  IntColumn get expireAfterSec => integer()();
  BlobColumn get originalTxBytes => blob().nullable()();
  TextColumn get originalTxId => text().nullable()();
  IntColumn get amountSat => integer().nullable()();
  TextColumn get proposalPsbt => text().nullable()();
  TextColumn get txId => text().nullable()();
  BoolColumn get isExpired => boolean()();
  BoolColumn get isCompleted => boolean()();
  BoolColumn get isAborted => boolean()();
  // A buy order payout from the Bull Bitcoin exchange, gated by the buy
  // switch instead of the receive switch. Schema 1 rows were all created by
  // the receive flow, hence the default.
  BoolColumn get isTrade => boolean().withDefault(const Constant(false))();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('PayjoinPolicyRow')
class PayjoinPolicies extends Table {
  IntColumn get id => integer()();
  // Schema 1's single switch; it now governs receiving from users only.
  BoolColumn get receiveEnabled => boolean().named('enabled')();
  BoolColumn get sendEnabled => boolean().withDefault(const Constant(false))();
  BoolColumn get buyEnabled => boolean().withDefault(const Constant(true))();
  BoolColumn get sellEnabled => boolean().withDefault(const Constant(true))();
  IntColumn get minimumAmountSat => integer()();
  IntColumn get sessionLifetimeSeconds => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

@DataClassName('PayjoinMigrationRow')
class PayjoinMigrations extends Table {
  TextColumn get name => text()();
  DateTimeColumn get completedAt => dateTime()();
  IntColumn get sourceSchemaVersion => integer()();
  IntColumn get senderCount => integer()();
  IntColumn get receiverCount => integer()();
  TextColumn get verificationDigest => text()();

  @override
  Set<Column<Object>> get primaryKey => {name};
}

@DriftDatabase(
  tables: [
    PayjoinSenders,
    PayjoinReceivers,
    PayjoinPolicies,
    PayjoinMigrations,
  ],
)
final class PayjoinDatabase extends _$PayjoinDatabase {
  static const schema = 3;

  PayjoinDatabase._(super.executor);

  factory PayjoinDatabase.open(String path) {
    return PayjoinDatabase._(
      NativeDatabase.createInBackground(
        File(path),
        setup: (database) {
          database.execute('PRAGMA busy_timeout = 2000;');
          database.execute('PRAGMA journal_mode = WAL;');
          database.execute('PRAGMA synchronous = FULL;');
        },
      ),
    );
  }

  factory PayjoinDatabase.forTesting(QueryExecutor executor) =
      PayjoinDatabase._;

  @override
  int get schemaVersion => schema;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (details) async {
      if (details.versionNow >= 3) await _ensurePendingV3();
    },
    onUpgrade: stepByStep(
      from1To2: (m, schema) async {
        await m.addColumn(
          schema.payjoinReceivers,
          schema.payjoinReceivers.isTrade,
        );
        await m.addColumn(
          schema.payjoinPolicies,
          schema.payjoinPolicies.sendEnabled,
        );
        await m.addColumn(
          schema.payjoinPolicies,
          schema.payjoinPolicies.buyEnabled,
        );
        await m.addColumn(
          schema.payjoinPolicies,
          schema.payjoinPolicies.sellEnabled,
        );
        // The single switch used to gate sending as well: a user who turned
        // it on keeps payjoin on both sides of a payment with another user.
        await customStatement(
          'UPDATE payjoin_policies SET send_enabled = enabled',
        );
      },
      from2To3: (m, schema) => _ensurePendingV3(),
    ),
  );
  // The version stays 3: development phones already opened the evidence-only
  // v3. Repair its physical shape before any typed query, without replaying
  // evidence backfills or changing existing concrete networks.
  Future<void> _ensurePendingV3() async {
    for (var attempt = 0; ; attempt++) {
      try {
        await transaction(() async {
          final m = createMigrator();
          if (!await m.hasColumn('payjoin_senders', 'has_network_evidence')) {
            await m.addColumn(
              payjoinSenders,
              payjoinSenders.hasNetworkEvidence,
            );
            await customStatement(
              'UPDATE payjoin_senders SET has_network_evidence = 1 '
              'WHERE is_expired = 0 AND is_completed = 0 AND is_aborted = 0',
            );
          }
          for (final (table, column)
              in <(TableInfo<Table, dynamic>, GeneratedColumn<String>)>[
                (payjoinSenders, payjoinSenders.network),
                (payjoinReceivers, payjoinReceivers.network),
              ]) {
            if (!await m.hasColumn(table.actualTableName, 'network')) {
              await m.addColumn(table, column);
              await customStatement(
                'UPDATE "${table.actualTableName}" SET network = '
                "CASE WHEN is_testnet = 1 THEN 'testnet' ELSE 'mainnet' END",
              );
            }
          }
        });
        return;
      } catch (error) {
        Object cause = error;
        while (cause is DriftRemoteException) {
          cause = cause.remoteCause;
        }
        if (cause is! SqliteException) rethrow;
        final retryable =
            cause.resultCode == 5 ||
            cause.resultCode == 6 ||
            cause.message == 'duplicate column name: network' ||
            cause.message == 'duplicate column name: has_network_evidence';
        if (!retryable || attempt >= 5) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 20 * (attempt + 1)));
      }
    }
  }
}
