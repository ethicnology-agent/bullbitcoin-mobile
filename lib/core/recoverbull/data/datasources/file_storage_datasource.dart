import 'dart:convert';
import 'dart:io';

import 'package:bb_mobile/core/errors/bull_exception.dart';
import 'package:file_picker/file_picker.dart';

class FileStorageDatasource {
  final FilePickerPlatform? _filePicker;

  FileStorageDatasource({this._filePicker});

  Future<File> pickFile({List<String>? extensions}) async {
    final result = await (_filePicker ?? FilePickerPlatform.instance).pickFile(
      allowedExtensions: extensions,
      type: extensions != null ? FileType.custom : FileType.any,
    );
    final path = result?.path;
    if (path != null) return File(path);

    throw FileStorageException('File not selected');
  }

  Future<void> saveFile(String content, String filename) async {
    final bytes = utf8.encode(content);
    final result = await (_filePicker ?? FilePickerPlatform.instance).saveFile(
      bytes: bytes,
      fileName: filename,
      mimeType: 'application/octet-stream',
    );

    if (result == null) throw FileStorageException('File not saved');
  }
}

class FileStorageException extends BullException {
  FileStorageException(super.message);
}
