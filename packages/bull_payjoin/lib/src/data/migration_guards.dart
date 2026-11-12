import 'package:drift/drift.dart';

extension MigrationGuards on Migrator {
  Future<bool> hasColumn(String table, String column) async {
    final rows = await database
        .customSelect(
          'SELECT 1 FROM pragma_table_info(?) WHERE name = ?',
          variables: [Variable<String>(table), Variable<String>(column)],
        )
        .get();
    return rows.isNotEmpty;
  }
}
