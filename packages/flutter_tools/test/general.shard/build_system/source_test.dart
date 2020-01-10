// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:file/memory.dart';
import 'package:flutter_tools/src/artifacts.dart';
import 'package:flutter_tools/src/base/file_system.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/build_system/build_system.dart';
import 'package:flutter_tools/src/build_system/exceptions.dart';
import 'package:flutter_tools/src/build_system/source.dart';
import 'package:mockito/mockito.dart';
import 'package:platform/platform.dart';

import '../../src/common.dart';
import '../../src/fake_process_manager.dart';

void main() {
  SourceVisitor visitor;
  Environment environment;
  MockPlatform platform;
  FileSystem fileSystem;
  Logger logger;
  Artifacts artifacts;

  setUp(() {
    platform = MockPlatform();
    fileSystem = MemoryFileSystem();
    logger = MockLogger();
    artifacts = MockArtifacts();

    when(platform.isWindows).thenReturn(true);
    fileSystem.directory('cache').createSync();
    final Directory outputs = fileSystem.directory('outputs')
        ..createSync();
    environment = Environment(
      fileSystem: fileSystem,
      logger: logger,
      artifacts: artifacts,
      platform: platform,
      processManager: FakeProcessManager.any(),
      outputDir: outputs,
      projectDir: fileSystem.currentDirectory,
      buildDir: fileSystem.directory('build'),
      cacheDir: fileSystem.directory('cache')
        ..createSync(),
      flutterRootDir: fileSystem.directory('flutter')
        ..createSync(),
    );
    visitor = SourceVisitor(environment);
    environment.buildDir.createSync(recursive: true);
  });

  testWithoutContext('configures implicit vs explict correctly', () {
    expect(const Source.pattern('{PROJECT_DIR}/foo').implicit, false);
    expect(const Source.pattern('{PROJECT_DIR}/*foo').implicit, true);
  });

  testWithoutContext('can substitute {PROJECT_DIR}/foo', () {
    fileSystem.file('foo').createSync();
    const Source fooSource = Source.pattern('{PROJECT_DIR}/foo');
    fooSource.accept(visitor);

    expect(visitor.sources.single.path, fileSystem.path.absolute('foo'));
  });

  testWithoutContext('can substitute {OUTPUT_DIR}/foo', () {
    fileSystem.file('foo').createSync();
    const Source fooSource = Source.pattern('{OUTPUT_DIR}/foo');
    fooSource.accept(visitor);

    expect(visitor.sources.single.path, fileSystem.path.absolute(fileSystem.path.join('outputs', 'foo')));
  });

  testWithoutContext('can substitute {BUILD_DIR}/bar', () {
    final String path = fileSystem.path.join(environment.buildDir.path, 'bar');
    fileSystem.file(path).createSync();
    const Source barSource = Source.pattern('{BUILD_DIR}/bar');
    barSource.accept(visitor);

    expect(visitor.sources.single.path, fileSystem.path.absolute(path));
  });

  testWithoutContext('can substitute {FLUTTER_ROOT}/foo', () {
    final String path = fileSystem.path.join(environment.flutterRootDir.path, 'foo');
    fileSystem.file(path).createSync();
    const Source barSource = Source.pattern('{FLUTTER_ROOT}/foo');
    barSource.accept(visitor);

    expect(visitor.sources.single.path, fileSystem.path.absolute(path));
  });

  testWithoutContext('can substitute Artifact', () {
    fileSystem.file('example').createSync();
    when(artifacts.getArtifactPath(any, mode: anyNamed('mode'), platform: anyNamed('platform')))
      .thenReturn('example');
    const Source fizzSource = Source.artifact(Artifact.windowsDesktopPath, platform: TargetPlatform.windows_x64);
    fizzSource.accept(visitor);

    expect(visitor.sources.single.resolveSymbolicLinksSync(), fileSystem.path.absolute('example'));
  });

  testWithoutContext('can substitute {PROJECT_DIR}/*.fizz', () {
    const Source fizzSource = Source.pattern('{PROJECT_DIR}/*.fizz');
    fizzSource.accept(visitor);

    expect(visitor.sources, isEmpty);

    fileSystem.file('foo.fizz').createSync();
    fileSystem.file('foofizz').createSync();


    fizzSource.accept(visitor);

    expect(visitor.sources.single.path, fileSystem.path.absolute('foo.fizz'));
  });

  testWithoutContext('can substitute {PROJECT_DIR}/fizz.*', () {
    const Source fizzSource = Source.pattern('{PROJECT_DIR}/fizz.*');
    fizzSource.accept(visitor);

    expect(visitor.sources, isEmpty);

    fileSystem.file('fizz.foo').createSync();
    fileSystem.file('fizz').createSync();

    fizzSource.accept(visitor);

    expect(visitor.sources.single.path, fileSystem.path.absolute('fizz.foo'));
  });


  testWithoutContext('can substitute {PROJECT_DIR}/a*bc', () {
    const Source fizzSource = Source.pattern('{PROJECT_DIR}/bc*bc');
    fizzSource.accept(visitor);

    expect(visitor.sources, isEmpty);

    fileSystem.file('bcbc').createSync();
    fileSystem.file('bc').createSync();

    fizzSource.accept(visitor);

    expect(visitor.sources.single.path, fileSystem.path.absolute('bcbc'));
  });


  testWithoutContext('crashes on bad substitute of two **', () {
    const Source fizzSource = Source.pattern('{PROJECT_DIR}/*.*bar');

    fileSystem.file('abcd.bar').createSync();

    expect(() => fizzSource.accept(visitor), throwsA(isInstanceOf<InvalidPatternException>()));
  });


  testWithoutContext('can\'t substitute foo', () {
    const Source invalidBase = Source.pattern('foo');

    expect(() => invalidBase.accept(visitor), throwsA(isInstanceOf<InvalidPatternException>()));
  });

  testWithoutContext('can substitute optional files', () {
    const Source missingSource = Source.pattern('{PROJECT_DIR}/foo', optional: true);

    expect(fileSystem.file('foo').existsSync(), false);
    missingSource.accept(visitor);
    expect(visitor.sources, isEmpty);
  });

  testWithoutContext('can resolve a missing depfile', () {
    visitor.visitDepfile('foo.d');

    expect(visitor.sources, isEmpty);
    expect(visitor.containsNewDepfile, true);
  });

  testWithoutContext('can resolve a populated depfile', () {
    environment.buildDir.childFile('foo.d')
      .writeAsStringSync('a.dart : c.dart');

    visitor.visitDepfile('foo.d');
    expect(visitor.sources.single.path, 'c.dart');
    expect(visitor.containsNewDepfile, false);

    final SourceVisitor outputVisitor = SourceVisitor(environment, false);
    outputVisitor.visitDepfile('foo.d');

    expect(outputVisitor.sources.single.path, 'a.dart');
    expect(outputVisitor.containsNewDepfile, false);
  });

  testWithoutContext('does not crash on completely invalid depfile', () {
    environment.buildDir.childFile('foo.d')
        .writeAsStringSync('hello, world');

    visitor.visitDepfile('foo.d');
    expect(visitor.sources, isEmpty);
    expect(visitor.containsNewDepfile, false);
  });

  testWithoutContext('can parse depfile with windows paths', () {
    fileSystem = MemoryFileSystem(style: FileSystemStyle.windows);
    environment.buildDir.childFile('foo.d')
        .writeAsStringSync(r'a.dart: C:\\foo\\bar.txt');

    visitor.visitDepfile('foo.d');
    expect(visitor.sources.single.path, r'C:\foo\bar.txt');
    expect(visitor.containsNewDepfile, false);
  });

  testWithoutContext('can parse depfile with spaces in paths', () {
    environment.buildDir.childFile('foo.d')
        .writeAsStringSync(r'a.dart: foo\ bar.txt');

    visitor.visitDepfile('foo.d');
    expect(visitor.sources.single.path, r'foo bar.txt');
    expect(visitor.containsNewDepfile, false);
  });
}

class MockPlatform extends Mock implements Platform {}
class MockLogger extends Mock implements Logger {}
class MockArtifacts extends Mock implements Artifacts {}
