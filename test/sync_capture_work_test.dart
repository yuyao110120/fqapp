import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/library_backup.dart';
import 'package:fqapp/services/sync/sync_capture_work.dart';
import 'package:fqapp/services/sync/sync_snapshot.dart';

void main() {
  testWidgets('reading updates batch until idle or the 30-second deadline', (
    tester,
  ) async {
    var scans = 0;
    final work = CoalescedSyncWork(
      enqueue: (action) => action(),
      run: () async => scans++,
    );

    for (var i = 0; i < 5; i++) {
      work.requestAfterHistoryIdle();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(scans, 0);
    await tester.pump(const Duration(seconds: 2));
    expect(scans, 1);

    for (var i = 0; i < 29; i++) {
      work.requestAfterHistoryIdle();
      await tester.pump(const Duration(seconds: 1));
    }
    expect(scans, 1);
    work.requestAfterHistoryIdle();
    await tester.pump(const Duration(seconds: 1));
    expect(scans, 2);
  });

  testWidgets('a deletion takes priority over deferred history work', (
    tester,
  ) async {
    var scans = 0;
    final work = CoalescedSyncWork(
      enqueue: (action) => action(),
      run: () async => scans++,
    );
    work.requestAfterHistoryIdle();
    work.request();
    expect(scans, 1);
    await tester.pump(const Duration(seconds: 31));
    expect(scans, 1);
  });

  test(
    'merged remote snapshots skip equal stores but preserve deletions',
    () async {
      final baseline = SyncSnapshot({
        'h|book|removed': {'id': 'removed', 'kind': 'book', 'time': 1},
        'h|book|kept': {'id': 'kept', 'kind': 'book', 'time': 2},
      });
      final reordered = SyncSnapshot({
        'h|book|kept': {'time': 2, 'id': 'kept', 'kind': 'book'},
        'h|book|removed': {'time': 1, 'id': 'removed', 'kind': 'book'},
      });
      expect(await prepareMergedSyncApply(reordered, baseline), isNull);

      reordered.values.remove('h|book|removed');
      final backup = await prepareMergedSyncApply(reordered, baseline);
      expect(backup!.history.map((row) => row['id']), ['kept']);
      expect(baseline.values, hasLength(2));
    },
  );

  test(
    'notification bursts queue one scan and one follow-up behind other work',
    () async {
      final queue = <Future<void> Function()>[];
      final gate = Completer<void>();
      var scans = 0;
      var latest = 0;
      final observed = <int>[];
      final work = CoalescedSyncWork(
        enqueue: (action) {
          queue.add(action);
          return Future.value();
        },
        run: () async {
          scans++;
          observed.add(latest);
          if (scans == 1) await gate.future;
        },
      );
      for (var i = 0; i < 1000; i++) {
        latest = i;
        work.request();
      }
      expect(queue, hasLength(1));
      final running = queue.removeAt(0)();
      queue.add(() async => observed.add(-1)); // Explicit sync/configuration.
      for (var i = 1000; i < 2000; i++) {
        latest = i;
        work.request();
      }
      expect(queue, hasLength(1));
      gate.complete();
      await running;
      expect(queue, hasLength(2));
      await queue.removeAt(0)();
      await queue.removeAt(0)();
      expect(scans, 2);
      expect(observed, [999, -1, 1999]);
      expect(queue, isEmpty);
    },
  );

  test('capture failure does not strand later changes', () async {
    final queue = <Future<void> Function()>[];
    var scans = 0;
    final work = CoalescedSyncWork(
      enqueue: (action) {
        queue.add(action);
        return Future.value();
      },
      run: () async {
        if (++scans == 1) throw StateError('storage failed');
      },
    );
    work.request();
    await expectLater(queue.removeAt(0)(), throwsStateError);
    work.request();
    await queue.removeAt(0)();
    expect(scans, 2);
  });

  test(
    'worker detects edits and deletions without mutating the baseline',
    () async {
      final old = SyncSnapshot({
        'h|book|removed': {'id': 'removed', 'kind': 'book', 'time': 1},
      });
      final backup = LibraryBackup.capture(
        shelf: [],
        history: [
          {'id': 'kept', 'kind': 'book', 'time': 2, 'position': 42},
          {'id': 'local_123_abcd', 'kind': 'book', 'time': 1},
        ],
        watched: {},
      );
      final result = await prepareLocalSyncCapture(backup, old, null);
      expect(result.changes['h|book|removed'], isNull);
      expect(result.changes.containsKey('h|book|removed'), isTrue);
      expect(result.changes['h|book|kept']?['position'], 42);
      expect(result.current.values.keys, ['h|book|kept']);
      expect(old.values.keys, ['h|book|removed']);
      expect(
        (await prepareLocalSyncCapture(backup, result.current, null)).changes,
        isEmpty,
      );
    },
  );

  test(
    'a full-size history scan leaves the UI event loop responsive',
    () async {
      final backup = LibraryBackup.capture(
        shelf: [],
        history: [
          for (var i = 0; i < 10000; i++)
            {'id': 'book-$i', 'kind': 'book', 'time': i, 'position': i},
        ],
        watched: {},
      );
      var heartbeats = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => heartbeats++,
      );
      try {
        final result = await prepareLocalSyncCapture(
          backup,
          SyncSnapshot({}),
          null,
        );
        expect(result.current.values, hasLength(10000));
        expect(result.changes, hasLength(10000));
        expect(heartbeats, greaterThan(0));
      } finally {
        timer.cancel();
      }
    },
  );

  test(
    'recovery does not republish applied remote deletions as local edits',
    () async {
      final old = SyncSnapshot({
        'h|book|removed': {'id': 'removed', 'kind': 'book', 'time': 1},
      });
      final result = await prepareLocalSyncCapture(
        LibraryBackup.capture(shelf: [], history: [], watched: {}),
        old,
        {},
      );
      expect(result.changes, isEmpty);
      expect(old.values, isNotEmpty);
    },
  );
}
