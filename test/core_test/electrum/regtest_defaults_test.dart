import 'package:bb_mobile/core/storage/database_seeds.dart';
import 'package:bb_mobile/core/storage/sqlite_database.dart';
import 'package:bb_mobile/features/electrum_settings/domain/electrum_server_network.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SqliteDatabase database;

  setUp(() {
    database = SqliteDatabase(NativeDatabase.memory());
  });
  tearDown(() => database.close());

  test('regtest defaults are idempotent without a schema change', () async {
    final before = await database.customSelect('PRAGMA user_version').get();
    final historical = await (database.select(
      database.electrumServers,
    )..where((row) => row.network.isNotIn(['liquidRegtest']))).get();

    await DatabaseSeeds.ensureRegtestDefaults(database);
    await DatabaseSeeds.ensureRegtestDefaults(database);

    final defaults = await (database.select(
      database.electrumServers,
    )..where((row) => row.network.equals('liquidRegtest'))).get();
    expect(defaults, hasLength(1));
    expect(defaults.single.url, 'tcp://127.0.0.1:50001');
    expect(defaults.single.isCustom, isFalse);
    expect(
      await (database.select(
        database.electrumServers,
      )..where((row) => row.network.isNotIn(['liquidRegtest']))).get(),
      historical,
    );
    final after = await database.customSelect('PRAGMA user_version').get();
    expect(after.single.data, before.single.data);
  });

  test(
    'regtest initialization preserves customized rows and settings',
    () async {
      const server = ElectrumServerRow(
        url: 'tcp://127.0.0.1:50001',
        network: 'liquidRegtest',
        priority: 7,
        isCustom: true,
      );
      const settings = ElectrumSettingsRow(
        network: ElectrumServerNetwork.liquidRegtest,
        validateDomain: false,
        stopGap: 37,
        timeout: 11,
        retry: 2,
      );
      await database
          .into(database.electrumServers)
          .insertOnConflictUpdate(server);
      await database
          .into(database.electrumSettings)
          .insertOnConflictUpdate(settings);

      await DatabaseSeeds.ensureRegtestDefaults(database);
      await DatabaseSeeds.ensureRegtestDefaults(database);

      expect(
        await (database.select(
          database.electrumServers,
        )..where((row) => row.network.equals('liquidRegtest'))).getSingle(),
        server,
      );
      expect(
        await (database.select(database.electrumSettings)..where(
              (row) =>
                  row.network.equals(ElectrumServerNetwork.liquidRegtest.name),
            ))
            .getSingle(),
        settings,
      );
    },
  );
}
