import 'package:bb_mobile/core/recoverbull/data/datasources/file_storage_datasource.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _Picker extends Mock implements FilePickerPlatform {}

final class _PickedFile extends PlatformFile {
  @override
  final String? path;

  _PickedFile(this.path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Picker picker;
  late FileStorageDatasource datasource;

  setUp(() {
    picker = _Picker();
    datasource = FileStorageDatasource(filePicker: picker);
    registerFallbackValue(FileType.any);
  });

  void selects(PlatformFile? file) {
    when(
      () => picker.pickFile(
        type: any(named: 'type'),
        allowedExtensions: any(named: 'allowedExtensions'),
      ),
    ).thenAnswer((_) async => file);
  }

  test('returns the local file selected for recovery', () async {
    selects(_PickedFile('/tmp/test-backup.json'));
    expect((await datasource.pickFile()).path, '/tmp/test-backup.json');
  });

  test('cancellation returns the existing file selection exception', () async {
    selects(null);
    await expectLater(
      datasource.pickFile(),
      throwsA(isA<FileStorageException>()),
    );
  });

  test('a selected file without a local path fails explicitly', () async {
    selects(_PickedFile(null));
    await expectLater(
      datasource.pickFile(),
      throwsA(isA<FileStorageException>()),
    );
  });
}
