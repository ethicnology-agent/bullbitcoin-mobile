import 'package:bb_mobile/core/storage/sqlite_database.dart';
import 'package:bb_mobile/core/storage/database_seeds.dart';
import 'package:bb_mobile/core/storage/migrations/schema_15_to_16.dart';
import 'package:bb_mobile/core/storage/sqlite_database.steps.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'generated/schema.dart';
import 'generated/schema_v15.dart' as v15;
import 'generated/schema_v16.dart' as v16;
import 'package:drift/drift.dart' hide isNotNull, isNull;

void main() {
  test('Blockstream upgrade and reruns preserve Liquid regtest seeds', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final schema = await verifier.schemaAt(15);
    final old = v15.DatabaseAtV15(schema.newConnection());
    for (final (url, testnet, liquid, priority, custom) in [
      ('ssl://blockstream.info:993', 1, 0, 7, 0),
      ('blockstream.info:465', 1, 1, 9, 1),
      ('ssl://blockstream.info:700', 0, 0, 4, 0),
      ('ssl://bitcoin-mainnet.blockstream.info:50002', 0, 0, 6, 0),
    ]) {
      await old.customStatement(
        'INSERT INTO electrum_servers '
        '(url, is_testnet, is_liquid, priority, is_custom) VALUES (?, ?, ?, ?, ?)',
        [url, testnet, liquid, priority, custom],
      );
    }
    await old.close();
    final db = SqliteDatabase(schema.newConnection());
    addTearDown(db.close);
    await verifier.migrateAndValidate(db, 16);
    await DatabaseSeeds.ensureRegtestDefaults(db);
    await db.customStatement(
      "UPDATE electrum_servers SET priority = 11 WHERE network = 'liquidRegtest'",
    );
    await db.customStatement(
      "UPDATE electrum_settings SET stop_gap = 37, timeout = 11, retry = 2 "
      "WHERE network = 'liquidRegtest'",
    );
    final servers = await db.select(db.electrumServers).get();
    final settings = await db.select(db.electrumSettings).get();
    for (var pass = 0; pass < 2; pass++) {
      await Schema15To16.migrate(db.createMigrator(), Schema16(database: db));
      await DatabaseSeeds.ensureRegtestDefaults(db);
    }
    expect(await db.select(db.electrumServers).get(), unorderedEquals(servers));
    expect(
      await db.select(db.electrumSettings).get(),
      unorderedEquals(settings),
    );
    expect(
      servers.where((row) => row.url == 'ssl://blockstream.info:993'),
      isEmpty,
    );
    final migrated = servers.singleWhere(
      (row) => row.url == 'ssl://bitcoin-testnet.blockstream.info:50002',
    );
    expect(migrated.network, 'bitcoinTestnet');
    expect(migrated.priority, 7);
    expect(migrated.isCustom, isFalse);
    final custom = servers.singleWhere(
      (row) => row.url == 'blockstream.info:465',
    );
    expect(custom.network, 'liquidTestnet');
    expect(custom.priority, 9);
    expect(custom.isCustom, isTrue);
    // UPDATE OR IGNORE preserves both rows when the destination already exists.
    expect(
      servers
          .singleWhere((row) => row.url == 'ssl://blockstream.info:700')
          .priority,
      4,
    );
    expect(
      servers
          .singleWhere(
            (row) => row.url == 'ssl://bitcoin-mainnet.blockstream.info:50002',
          )
          .priority,
      6,
    );
    final loopback = servers.singleWhere(
      (row) => row.network == 'liquidRegtest',
    );
    expect(loopback.url, 'tcp://127.0.0.1:50001');
    expect(loopback.priority, 11);
    final liquidSettings = settings.singleWhere(
      (row) => row.network.name == 'liquidRegtest',
    );
    expect(liquidSettings.stopGap, 37);
    expect(liquidSettings.timeout, 11);
    expect(liquidSettings.retry, 2);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 16);
  });
  test('network backfill preserves identities and Electrum configuration', () async {
    final schema = await SchemaVerifier(GeneratedHelper()).schemaAt(15);
    final old = v15.DatabaseAtV15(schema.newConnection());
    const networks = {
      'wpkh([aabbccdd/84h/0h/0h])': 'bitcoinMainnet',
      'wpkh([aabbccdd/84h/1h/0h])': 'bitcoinTestnet',
      'elwpkh([aabbccdd/84h/1776h/0h])': 'liquidMainnet',
      'elwpkh([aabbccdd/84h/1h/0h])': 'liquidTestnet',
      'unrecognized-origin': 'unresolved',
    };
    for (final id in networks.keys) {
      await old.customStatement(
        '''
        INSERT INTO wallet_metadatas
        (id, master_fingerprint, xpub_fingerprint, is_encrypted_vault_tested,
         is_physical_backup_tested, xpub, external_public_descriptor,
         internal_public_descriptor, signer, is_default)
        VALUES (?, 'aabbccdd', 'aabbccdd', 0, 0, 'public', 'public', 'public', 'local', 0)
      ''',
        [id],
      );
    }
    await old.customStatement(
      "INSERT INTO electrum_servers (url, is_testnet, is_liquid, priority, is_custom) VALUES ('tcp://local.example:50000', 1, 0, 7, 1)",
    );
    await old.close();
    final db = SqliteDatabase(schema.newConnection());
    addTearDown(db.close);
    await SchemaVerifier(GeneratedHelper()).migrateAndValidate(db, 16);
    final rows = await db
        .customSelect('SELECT id, network FROM wallet_metadatas')
        .get();
    expect({
      for (final row in rows)
        row.read<String>('id'): row.read<String>('network'),
    }, networks);
    final custom = await db
        .customSelect("SELECT * FROM electrum_servers WHERE is_custom = 1")
        .getSingle();
    expect(custom.read<String>('network'), 'bitcoinTestnet');
    expect(custom.read<int>('priority'), 7);
    // Identical endpoints on different networks no longer conflict.
    await db.customStatement(
      "INSERT INTO electrum_servers (url, network, priority, is_custom) VALUES ('tcp://local.example:50000', 'bitcoinRegtest', 2, 1)",
    );
    expect(
      await db
          .customSelect(
            "SELECT * FROM electrum_servers WHERE url = 'tcp://local.example:50000'",
          )
          .get(),
      hasLength(2),
    );
    expect(
      await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE name IN ('prices', 'transactions', 'labels', 'frozen_utxos', 'mempool_servers', 'mempool_settings')",
          )
          .get(),
      hasLength(5),
    );
  });
  test('v15 to v16 drops the price history and keeps the settings', () async {
    final schema = await SchemaVerifier(GeneratedHelper()).schemaAt(15);
    final oldDb = v15.DatabaseAtV15(schema.newConnection());
    await oldDb
        .into(oldDb.settings)
        .insert(
          v15.SettingsCompanion.insert(
            environment: 'mainnet',
            bitcoinUnit: 'sats',
            language: 'en',
            currency: 'CAD',
            hideAmounts: 0,
            isSuperuser: 0,
          ),
        );
    await oldDb
        .into(oldDb.prices)
        .insert(
          v15.PricesCompanion.insert(
            fromCurrency: 'BTC',
            toCurrency: 'CAD',
            interval: 'day',
            createdAt: '2026-11-01T00:00:00.000Z',
            indexPrice: const Value(108945.85),
          ),
        );
    await oldDb.close();

    final db = SqliteDatabase(schema.newConnection());
    await SchemaVerifier(GeneratedHelper()).migrateAndValidate(db, 16);
    final tables = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row.read<String>('name'))
        .get();
    expect(tables, isNot(contains('prices')));
    await db.close();

    final migratedDb = v16.DatabaseAtV16(schema.newConnection());
    final settings = await migratedDb.select(migratedDb.settings).get();
    expect(settings.single.currency, 'CAD');
    await migratedDb.close();
  });
}
