// Copyright 2018 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:convert' show JsonEncoder;

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:flutter_driver/flutter_driver.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart' hide TypeMatcher, isInstanceOf;

import 'package:fuchsia_driver/fuchsia_driver.dart';
import 'package:fuchsia_remote_debug_protocol/fuchsia_remote_debug_protocol.dart';
import 'package:fuchsia_remote_debug_protocol/logging.dart';
import 'package:lib.app.dart/logging.dart';

// Demos for which timeline data will be collected using
// FlutterDriver.traceAction().
//
// Warning: The number of tests executed with timeline collection enabled
// significantly impacts heap size of the running app. When run with
// --trace-startup, as we do in this test, the VM stores trace events in an
// endless buffer instead of a ring buffer.
//
// These names must match GalleryItem titles from kAllGalleryDemos
// in examples/flutter_gallery/lib/gallery/demos.dart
const List<String> kProfiledDemos = <String>[
  'Shrine@Studies',
  'Contact profile@Studies',
  'Animation@Studies',
  'Bottom navigation@Material',
  'Buttons@Material',
  'Cards@Material',
  'Chips@Material',
  'Dialogs@Material',
  'Pickers@Material',
];

// Demos that will be backed out of within FlutterDriver.runUnsynchronized();
//
// These names must match GalleryItem titles from kAllGalleryDemos
// in examples/flutter_gallery/lib/gallery/demos.dart
const List<String> kUnsynchronizedDemos = <String>[
  'Progress indicators@Material',
  'Activity Indicator@Cupertino',
  'Video@Media',
];

const List<String> kSkippedDemos = <String>[];

// All of the gallery demos, identified as "title@category".
//
// These names are reported by the test app, see _handleMessages()
// in transitions_perf.dart.
List<String> _allDemos = <String>[];

/// Extracts event data from [events] recorded by timeline, validates it, turns
/// it into a histogram, and saves to a JSON file.
Future<void> printDurationsHistogram(List<Map<String, dynamic>> events) async {
  final Map<String, List<int>> durations = <String, List<int>>{};
  Map<String, dynamic> startEvent;

  // Save the duration of the first frame after each 'Start Transition' event.
  for (Map<String, dynamic> event in events) {
    final String eventName = event['name'];
    if (eventName == 'Start Transition') {
      assert(startEvent == null);
      startEvent = event;
    } else if (startEvent != null && eventName == 'Frame') {
      final String routeName = startEvent['args']['to'];
      durations[routeName] ??= <int>[];
      durations[routeName].add(event['dur']);
      startEvent = null;
    }
  }

  // Verify that the durations data is valid.
  if (durations.keys.isEmpty) {
    throw 'no "Start Transition" timeline events found';
  }
  final Map<String, int> unexpectedValueCounts = <String, int>{};
  durations.forEach((String routeName, List<int> values) {
    if (values.length != 2) {
      unexpectedValueCounts[routeName] = values.length;
    }
  });

  if (unexpectedValueCounts.isNotEmpty) {
    final StringBuffer error = StringBuffer('Some routes recorded wrong number of values (expected 2 values/route):\n\n');
    unexpectedValueCounts.forEach((String routeName, int count) {
      error.writeln(' - $routeName recorded $count values.');
    });
    error.writeln('\nFull event sequence:');
    final Iterator<Map<String, dynamic>> eventIter = events.iterator;
    String lastEventName = '';
    String lastRouteName = '';
    while (eventIter.moveNext()) {
      final String eventName = eventIter.current['name'];

      if (!<String>['Start Transition', 'Frame'].contains(eventName))
        continue;

      final String routeName = eventName == 'Start Transition'
        ? eventIter.current['args']['to']
        : '';

      if (eventName == lastEventName && routeName == lastRouteName) {
        error.write('.');
      } else {
        error.write('\n - $eventName $routeName .');
      }

      lastEventName = eventName;
      lastRouteName = routeName;
    }
    throw error;
  }
  final String result = const JsonEncoder.withIndent('  ').convert(durations);
  print(result);
}

/// Scrolls each demo menu item into view, launches it, then returns to the
/// home screen twice.
Future<Null> runDemos(List<String> demos, FlutterDriver driver) async {
  final SerializableFinder demoList = find.byValueKey('GalleryDemoList');
  String currentDemoCategory;

  for (String demo in demos) {
    if (kSkippedDemos.contains(demo))
      continue;

    final String demoName = demo.substring(0, demo.indexOf('@'));
    final String demoCategory = demo.substring(demo.indexOf('@') + 1);
    print('> $demo');

    if (currentDemoCategory == null) {
      await driver.tap(find.text(demoCategory));
    } else if (currentDemoCategory != demoCategory) {
      await driver.tap(find.byTooltip('Back'));
      await driver.tap(find.text(demoCategory));
      // Scroll back to the top
      await driver.scroll(demoList, 0.0, 10000.0, const Duration(milliseconds: 100));
    }
    currentDemoCategory = demoCategory;

    final SerializableFinder demoItem = find.text(demoName);
    await driver.scrollUntilVisible(demoList, demoItem,
      dyScroll: -48.0,
      alignment: 0.5,
      timeout: const Duration(seconds: 30),
    );

    for (int i = 0; i < 2; i += 1) {
      await driver.tap(demoItem); // Launch the demo
      if (kUnsynchronizedDemos.contains(demo)) {
        await driver.runUnsynchronized<void>(() async {
          await driver.tap(find.pageBack());
        });
      } else {
        await driver.tap(find.pageBack());
      }
    }
    print('< Success');
  }

  // Return to the home screen
  await driver.tap(find.byTooltip('Back'));
}

void main() {
  group('flutter gallery transitions', () {
    FlutterDriver driver;
    FuchsiaRemoteConnection connection;

    setUpAll(() async {
      Logger.globalLevel = LoggingLevel.all;
      connection = await FuchsiaDriver.connect();
      const Pattern isolatePattern = 'flutter_gallery_app:main()';
      print('Finding $isolatePattern');
      final List<IsolateRef> refs = await connection.getMainIsolatesByPattern(isolatePattern);
      final IsolateRef ref = refs.first;
      // Occasionally this will crash if this delay isn't here.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      driver = await FlutterDriver.connect(
        dartVmServiceUrl: ref.dartVm.uri.toString(),
        isolateNumber: ref.number,
        printCommunication: true,
        logCommunicationToFile: false);
      _allDemos = kProfiledDemos + kUnsynchronizedDemos;
    });

    tearDownAll(() async {
      if (driver != null) {
        await driver.close();
      }
      if (connection != null) {
        await connection.stop();
      }
      await FuchsiaDriver.cleanup();
    });

    test('all demos', () async {
      // Collect timeline data for just a limited set of demos to avoid OOMs.
      final Timeline timeline = await driver.traceAction(
        () async {
          await runDemos(kProfiledDemos, driver);
        },
        streams: const <TimelineStream>[
          TimelineStream.dart,
          TimelineStream.embedder,
        ],
      );

      // Save the duration (in microseconds) of the first timeline Frame event
      // that follows a 'Start Transition' event. The Gallery app adds a
      // 'Start Transition' event when a demo is launched (see GalleryItem).
      // TODO(jonahwilliams): support timeline recording.
      // final TimelineSummary summary = TimelineSummary.summarize(timeline);
      // await printDurationsHistogram(
      // List<Map<String, dynamic>>.from(timeline.json['traceEvents']));

      // Execute the remaining tests.
      final Set<String> unprofiledDemos = Set<String>.from(_allDemos)..removeAll(kProfiledDemos);
      await runDemos(unprofiledDemos.toList(), driver);

    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
