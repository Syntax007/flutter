// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:typed_data';

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/terminal.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/file_hash_store.dart';
import 'package:mockito/mockito.dart';
import 'package:platform/platform.dart';


import '../../src/common.dart';
import '../../src/fake_process_manager.dart';

void main() {
  Environment environment;
  FileSystem fileSystem;
  BufferLogger logger;
  MockPlatform platform;

  setUp(() {
    platform = MockPlatform();
    fileSystem = MemoryFileSystem();
    logger = BufferLogger(
      terminal: null,
      outputPreferences: OutputPreferences.test(),
    );
    fileSystem.directory('build').createSync();
    environment = Environment(
      outputDir: fileSystem.currentDirectory,
      projectDir: fileSystem.currentDirectory,
      artifacts: MockArtifacts(),
      fileSystem: fileSystem,
      logger: logger,
      processManager: FakeProcessManager.any(),
      platform: platform,
    );
    environment.buildDir.createSync(recursive: true);
  });

  testWithoutContext('Initializes file cache', () {
    final FileHashStore fileCache = FileHashStore(environment, fileSystem, logger);
    fileCache.initialize();
    fileCache.persist();

    expect(fileSystem.file(fileSystem.path.join(environment.buildDir.path, '.filecache')).existsSync(), true);

    final Uint8List buffer = fileSystem.file(fileSystem.path.join(environment.buildDir.path, '.filecache'))
        .readAsBytesSync();
    final FileStorage fileStorage = FileStorage.fromBuffer(buffer);

    expect(fileStorage.files, isEmpty);
    expect(fileStorage.version, 2);
  });

  testWithoutContext('saves and restores to file cache', () async {
    final File file = fileSystem.file('foo.dart')
      ..createSync()
      ..writeAsStringSync('hello');
    final FileHashStore fileCache = FileHashStore(environment, fileSystem, logger);
    fileCache.initialize();
    await fileCache.hashFiles(<File>[file]);
    fileCache.persist();
    final String currentHash =  fileCache.currentHashes[file.path];
    final Uint8List buffer = fileSystem.file(fileSystem.path.join(environment.buildDir.path, '.filecache'))
        .readAsBytesSync();
    FileStorage fileStorage = FileStorage.fromBuffer(buffer);

    expect(fileStorage.files.single.hash, currentHash);
    expect(fileStorage.files.single.path, file.path);


    final FileHashStore newFileCache = FileHashStore(environment, fileSystem, logger);
    newFileCache.initialize();
    expect(newFileCache.currentHashes, isEmpty);
    expect(newFileCache.previousHashes['foo.dart'],  currentHash);
    newFileCache.persist();

    // Still persisted correctly.
    fileStorage = FileStorage.fromBuffer(buffer);

    expect(fileStorage.files.single.hash, currentHash);
    expect(fileStorage.files.single.path, file.path);
  });

  testWithoutContext('handles persisting with a missing build directory', () async {
    final File file = fileSystem.file('foo.dart')
      ..createSync()
      ..writeAsStringSync('hello');
    final FileHashStore fileCache = FileHashStore(environment, fileSystem, logger);
    fileCache.initialize();
    environment.buildDir.deleteSync(recursive: true);

    await fileCache.hashFiles(<File>[file]);
    // Does not throw.
    fileCache.persist();
  });

  testWithoutContext('handles hashing missing files', () async {
    final FileHashStore fileCache = FileHashStore(environment, fileSystem, logger);
    fileCache.initialize();

    final List<File> results = await fileCache.hashFiles(<File>[fileSystem.file('hello.dart')]);

    expect(results, hasLength(1));
    expect(results.single.path, 'hello.dart');
    expect(fileCache.currentHashes, isNot(contains(fileSystem.path.absolute('hello.dart'))));
  });

  testWithoutContext('handles failure to persist file cache', () async {
    final FakeForwardingFileSystem fakeForwardingFileSystem = FakeForwardingFileSystem(fileSystem);
    final FileHashStore fileCache = FileHashStore(environment, fileSystem, logger);
    final String cacheFile = environment.buildDir.childFile('.filecache').path;
    final MockFile mockFile = MockFile();
    when(mockFile.writeAsBytesSync(any)).thenThrow(const FileSystemException('Out of space!'));
    when(mockFile.existsSync()).thenReturn(true);

    fileCache.initialize();
    fakeForwardingFileSystem.files[cacheFile] = mockFile;
    fileCache.persist();

    expect(logger.errorText, contains('Out of space!'));
  });

  testWithoutContext('handles failure to restore file cache', () async {
    final FakeForwardingFileSystem fakeForwardingFileSystem = FakeForwardingFileSystem(fileSystem);
    final FileHashStore fileCache = FileHashStore(
      environment,
      fakeForwardingFileSystem,
      logger,
    );
    final String cacheFile = environment.buildDir.childFile('.filecache').path;
    final MockFile mockFile = MockFile();
    when(mockFile.readAsBytesSync()).thenThrow(const FileSystemException('Out of space!'));
    when(mockFile.existsSync()).thenReturn(true);

    fakeForwardingFileSystem.files[cacheFile] = mockFile;
    fileCache.initialize();

    expect(logger.errorText, contains('Out of space!'));
  });
}

class FakeForwardingFileSystem extends ForwardingFileSystem {
  FakeForwardingFileSystem(FileSystem fileSystem) : super(fileSystem);

  final Map<String, File> files = <String, File>{};

  @override
  File file(dynamic path) => files[path] ?? super.file(path);
}

class MockFile extends Mock implements File {}
class MockArtifacts extends Mock implements Artifacts {}
class MockPlatform extends Mock implements Platform {}
