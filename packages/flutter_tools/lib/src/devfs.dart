// Copyright 2016 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:meta/meta.dart';
import 'package:watcher/watcher.dart';

import 'asset.dart';
import 'base/context.dart';
import 'base/file_system.dart';
import 'base/io.dart';
import 'build_info.dart';
import 'bundle.dart';
import 'compile.dart';
import 'convert.dart' show base64, utf8;
import 'dart/package_map.dart';
import 'globals.dart';
import 'vmservice.dart';

class DevFSConfig {
  /// Should DevFS assume that symlink targets are stable?
  bool cacheSymlinks = false;
  /// Should DevFS assume that there are no symlinks to directories?
  bool noDirectorySymlinks = false;
}

DevFSConfig get devFSConfig => context[DevFSConfig];

/// Common superclass for content copied to the device.
abstract class DevFSContent {
  /// Return true if this is the first time this method is called
  /// or if the entry has been modified since this method was last called.
  bool get isModified;

  /// Return true if this is the first time this method is called
  /// or if the entry has been modified after the given time
  /// or if the given time is null.
  bool isModifiedAfter(DateTime time);

  int get size;

  Future<List<int>> contentsAsBytes();

  Stream<List<int>> contentsAsStream();

  Stream<List<int>> contentsAsCompressedStream() {
    return contentsAsStream().transform<List<int>>(gzip.encoder);
  }

  /// Return the list of files this content depends on.
  List<String> get fileDependencies => <String>[];
}

// File content to be copied to the device.
class DevFSFileContent extends DevFSContent {
  DevFSFileContent(this.file);

  static DevFSFileContent clone(DevFSFileContent fsFileContent) {
    final DevFSFileContent newFsFileContent = DevFSFileContent(fsFileContent.file);
    newFsFileContent._linkTarget = fsFileContent._linkTarget;
    newFsFileContent._fileStat = fsFileContent._fileStat;
    return newFsFileContent;
  }

  final FileSystemEntity file;
  FileSystemEntity _linkTarget;
  FileStat _fileStat;

  File _getFile() {
    if (_linkTarget != null) {
      return _linkTarget;
    }
    if (file is Link) {
      // The link target.
      return fs.file(file.resolveSymbolicLinksSync());
    }
    return file;
  }

  void _stat() {
    if (_linkTarget != null) {
      // Stat the cached symlink target.
      final FileStat fileStat = _linkTarget.statSync();
      if (fileStat.type == FileSystemEntityType.notFound) {
        _linkTarget = null;
      } else {
        _fileStat = fileStat;
        return;
      }
    }
    final FileStat fileStat = file.statSync();
    _fileStat = fileStat.type == FileSystemEntityType.notFound ? null : fileStat;
    if (_fileStat != null && _fileStat.type == FileSystemEntityType.link) {
      // Resolve, stat, and maybe cache the symlink target.
      final String resolved = file.resolveSymbolicLinksSync();
      final FileSystemEntity linkTarget = fs.file(resolved);
      // Stat the link target.
      final FileStat fileStat = linkTarget.statSync();
      if (fileStat.type == FileSystemEntityType.notFound) {
        _fileStat = null;
        _linkTarget = null;
      } else if (devFSConfig.cacheSymlinks) {
        _linkTarget = linkTarget;
      }
    }
    if (_fileStat == null) {
      printError('Unable to get status of file "${file.path}": file not found.');
    }
  }

  @override
  List<String> get fileDependencies => <String>[_getFile().path];

  @override
  bool get isModified {
    final FileStat _oldFileStat = _fileStat;
    _stat();
    if (_oldFileStat == null && _fileStat == null)
      return false;
    return _oldFileStat == null || _fileStat == null || _fileStat.modified.isAfter(_oldFileStat.modified);
  }

  @override
  bool isModifiedAfter(DateTime time) {
    final FileStat _oldFileStat = _fileStat;
    _stat();
    if (_oldFileStat == null && _fileStat == null)
      return false;
    return time == null
        || _oldFileStat == null
        || _fileStat == null
        || _fileStat.modified.isAfter(time);
  }

  @override
  int get size {
    if (_fileStat == null)
      _stat();
    // Can still be null if the file wasn't found.
    return _fileStat?.size ?? 0;
  }

  @override
  Future<List<int>> contentsAsBytes() => _getFile().readAsBytes();

  @override
  Stream<List<int>> contentsAsStream() => _getFile().openRead();
}

/// Byte content to be copied to the device.
class DevFSByteContent extends DevFSContent {
  DevFSByteContent(this._bytes);

  List<int> _bytes;

  bool _isModified = true;
  DateTime _modificationTime = DateTime.now();

  List<int> get bytes => _bytes;

  set bytes(List<int> value) {
    _bytes = value;
    _isModified = true;
    _modificationTime = DateTime.now();
  }

  /// Return true only once so that the content is written to the device only once.
  @override
  bool get isModified {
    final bool modified = _isModified;
    _isModified = false;
    return modified;
  }

  @override
  bool isModifiedAfter(DateTime time) {
    return time == null || _modificationTime.isAfter(time);
  }

  @override
  int get size => _bytes.length;

  @override
  Future<List<int>> contentsAsBytes() async => _bytes;

  @override
  Stream<List<int>> contentsAsStream() =>
      Stream<List<int>>.fromIterable(<List<int>>[_bytes]);
}

/// String content to be copied to the device.
class DevFSStringContent extends DevFSByteContent {
  DevFSStringContent(String string)
    : _string = string,
      super(utf8.encode(string));

  String _string;

  String get string => _string;

  set string(String value) {
    _string = value;
    super.bytes = utf8.encode(_string);
  }

  @override
  set bytes(List<int> value) {
    string = utf8.decode(value);
  }
}

class ServiceProtocolDevFSOperations {
  ServiceProtocolDevFSOperations(this._vmService);

  final VMService _vmService;

  Future<Uri> create(String fsName) async {
    final Map<String, dynamic> response = await _vmService.vm.createDevFS(fsName);
    return Uri.parse(response['uri']);
  }

  Future<dynamic> destroy(String fsName) async {
    await _vmService.vm.deleteDevFS(fsName);
  }

  Future<dynamic> writeFile(String fsName, Uri deviceUri, DevFSContent content) async {
    List<int> bytes;
    try {
      bytes = await content.contentsAsBytes();
    } catch (e) {
      printError('Caught error while trying to convert $fsName to bytes for devfs sync.');
      rethrow;
    }
    final String fileContents = base64.encode(bytes);
    try {
      return await _vmService.vm.invokeRpcRaw(
        '_writeDevFSFile',
        params: <String, dynamic> {
          'fsName': fsName,
          'uri': deviceUri.toString(),
          'fileContents': fileContents
        },
      );
    } catch (error) {
      printTrace('DevFS: Failed to write $deviceUri: $error');
    }
  }
}

class DevFSException implements Exception {
  DevFSException(this.message, [this.error, this.stackTrace]);
  final String message;
  final dynamic error;
  final StackTrace stackTrace;
}

class _DevFSHttpWriter {
  _DevFSHttpWriter(this.fsName, VMService serviceProtocol)
    : httpAddress = serviceProtocol.httpAddress,
      _client = HttpClient() {
    _client.maxConnectionsPerHost = kMaxInFlight;
  }

  final String fsName;
  final Uri httpAddress;

  static const int kMaxInFlight = 6;
  static const int kMaxRetries = 3;

  int _inFlight = 0;
  Map<Uri, DevFSContent> _outstanding;
  Completer<void> _completer;
  final HttpClient _client;

  Future<void> write(Map<Uri, DevFSContent> entries) async {
    _completer = Completer<void>();
    _outstanding = Map<Uri, DevFSContent>.from(entries);
    _scheduleWrites();
    await _completer.future;
    _client.close();
  }

  void _scheduleWrites() {
    while (_inFlight < kMaxInFlight) {
      if (_outstanding.isEmpty) {
        // Finished.
        break;
      }
      final Uri deviceUri = _outstanding.keys.first;
      final DevFSContent content = _outstanding.remove(deviceUri);
      _scheduleWrite(deviceUri, content);
      _inFlight++;
    }
  }

  Future<void> _scheduleWrite(
    Uri deviceUri,
    DevFSContent content, [
    int retry = 0,
  ]) async {
    try {
      final HttpClientRequest request = await _client.putUrl(httpAddress);
      request.headers.removeAll(HttpHeaders.acceptEncodingHeader);
      request.headers.add('dev_fs_name', fsName);
      request.headers.add('dev_fs_uri_b64',
          base64.encode(utf8.encode(deviceUri.toString())));
      final Stream<List<int>> contents = content.contentsAsCompressedStream();
      await request.addStream(contents);
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
    } on SocketException catch (socketException, stackTrace) {
      // We have one completer and can get up to kMaxInFlight errors.
      if (!_completer.isCompleted) {
        _completer.completeError(socketException, stackTrace);
      }
      return;
    } catch (error) {
      if (retry < kMaxRetries) {
        printTrace('Retrying writing "$deviceUri" to DevFS due to error: $error');
        // Synchronization is handled by the _completer below.
        _scheduleWrite(deviceUri, content, retry + 1); // ignore: unawaited_futures
        return;
      } else {
        printError('Error writing "$deviceUri" to DevFS: $error');
      }
    }
    _inFlight--;
    if ((_outstanding.isEmpty) && (_inFlight == 0)) {
      _completer.complete();
    } else {
      _scheduleWrites();
    }
  }
}

// Basic statistics for DevFS update operation.
class UpdateFSReport {
  UpdateFSReport({bool success = false,
    int invalidatedSourcesCount = 0, int syncedBytes = 0}) {
    _success = success;
    _invalidatedSourcesCount = invalidatedSourcesCount;
    _syncedBytes = syncedBytes;
  }

  bool get success => _success;
  int get invalidatedSourcesCount => _invalidatedSourcesCount;
  int get syncedBytes => _syncedBytes;

  void incorporateResults(UpdateFSReport report) {
    if (!report._success) {
      _success = false;
    }
    _invalidatedSourcesCount += report._invalidatedSourcesCount;
    _syncedBytes += report._syncedBytes;
  }

  bool _success;
  int _invalidatedSourcesCount;
  int _syncedBytes;
}

class DevFS {
  /// Create a [DevFS] named [fsName] for the local files in [rootDirectory].
  ///
  /// One of `serviceProtocol` or `devFSOperations` must be provided.
  DevFS(
    this.fsName,
    this.rootDirectory, {
    String packagesFilePath,
    Watcher watcher,
    VMService vmService,
    ServiceProtocolDevFSOperations devFSOperations,
  }) : _operations = devFSOperations ?? ServiceProtocolDevFSOperations(vmService),
       _httpWriter = vmService != null ? _DevFSHttpWriter(fsName, vmService) : null,
      _packagesFilePath = packagesFilePath ?? fs.path.join(rootDirectory.path, kPackagesFileName) {
    watcher.events.listen((WatchEvent watchEvent) {
      if (fs.path.extension(watchEvent.path) == '.dart') {
        _dirtyEntries.add(watchEvent.path);
      }
    });
  }

  final String fsName;
  final Directory rootDirectory;

  String _packagesFilePath;
  final ServiceProtocolDevFSOperations _operations;
  final _DevFSHttpWriter _httpWriter;
  final Set<String> _dirtyEntries = Set<String>();
  final Set<String> assetPathsToEvict = Set<String>();

  Uri _baseUri;
  Uri get baseUri => _baseUri;

  Uri deviceUriToHostUri(Uri deviceUri) {
    final String deviceUriString = deviceUri.toString();
    final String baseUriString = baseUri.toString();
    if (deviceUriString.startsWith(baseUriString)) {
      final String deviceUriSuffix = deviceUriString.substring(baseUriString.length);
      return rootDirectory.uri.resolve(deviceUriSuffix);
    }
    return deviceUri;
  }

  Future<Uri> create() async {
    printTrace('DevFS: Creating new filesystem on the device ($_baseUri)');
    try {
      _baseUri = await _operations.create(fsName);
    } on rpc.RpcException catch (rpcException) {
      // 1001 is kFileSystemAlreadyExists in //dart/runtime/vm/json_stream.h
      if (rpcException.code != 1001)
        rethrow;
      printTrace('DevFS: Creating failed. Destroying and trying again');
      await destroy();
      _baseUri = await _operations.create(fsName);
    }
    printTrace('DevFS: Created new filesystem on the device ($_baseUri)');
    return _baseUri;
  }

  Future<void> destroy() async {
    printTrace('DevFS: Deleting filesystem on the device ($_baseUri)');
    await _operations.destroy(fsName);
    printTrace('DevFS: Deleted filesystem on the device ($_baseUri)');
  }

  /// Updates files on the device.
  ///
  /// Returns the number of bytes synced.
  Future<UpdateFSReport> update({
    @required String mainPath,
    String target,
    AssetBundle bundle,
    DateTime firstBuildTime,
    bool bundleFirstUpload = false,
    bool bundleDirty = false,
    Set<String> fileFilter,
    @required ResidentCompiler generator,
    String dillOutputPath,
    @required bool trackWidgetCreation,
    bool fullRestart = false,
    String projectRootPath,
    @required String pathToReload,
  }) async {
    final Map<Uri, DevFSContent> dirtyEntries = <Uri, DevFSContent>{};
    int syncedBytes = 0;
    if (fullRestart) {
      generator.reset();
    }
    // We run generator even if [dirtyEntries] was empty because we want to
    // keep logic of accepting/rejecting generator's output simple: we must
    // accept/reject generator's output after every [update] call.  Incremental
    // run with no changes is supposed to be fast (considering that it is
    // initiated by user key press).
    final List<String> dirtyDartEntries = _dirtyEntries.toList();
    _dirtyEntries.clear();
    final CompilerOutput compilerOutput = await generator.recompile(
      mainPath,
      dirtyDartEntries,
      outputPath:  dillOutputPath ?? getDefaultApplicationKernelPath(trackWidgetCreation: trackWidgetCreation),
      packagesFilePath : _packagesFilePath,
    );

    bundle?.entries?.forEach((String archivePath, DevFSContent content) {
      if (content.isModified) {
        syncedBytes += content.size;
        final Uri deviceUri = fs.path.toUri(fs.path.join(getAssetBuildDirectory(), archivePath));
        dirtyEntries[deviceUri] = content;
      }
    });

    if (bundleFirstUpload) {
      await _httpWriter?.write(dirtyEntries);
      return UpdateFSReport(invalidatedSourcesCount: dirtyDartEntries.length, success: true, syncedBytes: syncedBytes);
    }

    final String compiledBinary = compilerOutput?.outputFilename;
    if (compiledBinary == null || compiledBinary.isEmpty) {
      return UpdateFSReport(invalidatedSourcesCount: 0, success: false, syncedBytes: 0);
    }
    final Uri entryUri = fs.path.toUri(projectRootPath != null
      ? fs.path.relative(pathToReload, from: projectRootPath)
      : pathToReload,
    );
    final DevFSFileContent content = DevFSFileContent(fs.file(compiledBinary));
    syncedBytes += content.size;
    dirtyEntries[entryUri] = content;
    await _httpWriter?.write(dirtyEntries);
    
    // Don't send full kernel file that would overwrite what VM already
    // started loading from.
    if (!fullRestart) {
      await _operations.writeFile(fsName, entryUri, content);
    }
    return UpdateFSReport(invalidatedSourcesCount: dirtyDartEntries.length, success: true, syncedBytes: syncedBytes);
  }
}
