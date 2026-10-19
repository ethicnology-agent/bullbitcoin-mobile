import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the application disables backup and references extraction rules', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final application = RegExp(
      r'<application\b[^>]*>',
    ).firstMatch(manifest)?.group(0);

    expect(application, contains('android:allowBackup="false"'));
    expect(
      application,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  final rules = File(
    'android/app/src/main/res/xml/data_extraction_rules.xml',
  ).readAsStringSync().replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

  for (final mode in ['cloud-backup', 'device-transfer']) {
    group(mode, () {
      final section = RegExp(
        '<$mode\\b[^>]*>([\\s\\S]*?)</$mode>',
      ).firstMatch(rules)?.group(1);

      test('excludes Flutter documents with the rest of the app data', () {
        expect(section, isNotNull, reason: 'Missing $mode rules.');
        for (final domain in [
          'root',
          'sharedpref',
          'database',
          'file',
          'external',
        ]) {
          // Flutter's app_flutter/ lives in root, outside file and database.
          expect(
            section,
            matches(
              '<exclude\\b(?=[^>]*\\bdomain="$domain")'
              '(?=[^>]*\\bpath="\\.")[^>]*/>',
            ),
            reason: '$mode must exclude the entire $domain domain.',
          );
        }
      });
    });
  }
}
