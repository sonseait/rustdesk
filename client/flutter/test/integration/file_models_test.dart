import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_hbb/integration/session/file_models.dart';

FileEntry entry(String name,
        {int type = 4, int size = 0, int modified = 0}) =>
    FileEntry(
        name: name, entryType: type, size: size, modifiedTime: modified);

void main() {
  group('FileEntry', () {
    test('classifies by the core entry_type numbering', () {
      // Below 3 is a directory, 3 is a drive, above 3 is a file.
      expect(entry('docs', type: 1).isDirectory, isTrue);
      expect(entry('C:', type: 3).isDrive, isTrue);
      expect(entry('notes.txt', type: 4).isFile, isTrue);

      expect(entry('docs', type: 1).isFile, isFalse);
      expect(entry('notes.txt').isDirectory, isFalse);
    });

    test('parses the core json shape', () {
      final parsed = FileEntry.fromJson({
        'name': 'report.pdf',
        'entry_type': 4,
        'modified_time': 1700000000,
        'size': 2048,
      });

      expect(parsed.name, 'report.pdf');
      expect(parsed.size, 2048);
      expect(parsed.isFile, isTrue);
    });

    test('converts the modified time from seconds', () {
      // The core reports seconds; DateTime takes milliseconds.
      final parsed = entry('x', modified: 1700000000);

      expect(parsed.lastModified.millisecondsSinceEpoch, 1700000000 * 1000);
    });

    test('tolerates a missing field', () {
      final parsed = FileEntry.fromJson({});

      expect(parsed.name, isEmpty);
      expect(parsed.size, 0);
    });
  });

  group('sortEntries', () {
    test('keeps directories above files whatever the key', () {
      final sorted = sortEntries([
        entry('zzz-file', size: 100),
        entry('aaa-dir', type: 1),
      ], SortBy.size);

      expect(sorted.first.name, 'aaa-dir');
    });

    test('sorts by name case-insensitively', () {
      final sorted = sortEntries(
          [entry('Beta'), entry('alpha'), entry('Gamma')], SortBy.name);

      expect(sorted.map((e) => e.name).toList(), ['alpha', 'Beta', 'Gamma']);
    });

    test('sorts by size, modified time and extension', () {
      final bySize = sortEntries(
          [entry('b', size: 30), entry('a', size: 10)], SortBy.size);
      expect(bySize.first.name, 'a');

      final byTime = sortEntries(
          [entry('b', modified: 30), entry('a', modified: 10)],
          SortBy.modified);
      expect(byTime.first.name, 'a');

      final byType = sortEntries(
          [entry('b.zip'), entry('a.txt')], SortBy.type);
      expect(byType.first.name, 'a.txt');
    });

    test('descending reverses within each group', () {
      final sorted = sortEntries(
        [entry('a'), entry('b'), entry('dir', type: 1)],
        SortBy.name,
        ascending: false,
      );

      // Directories still lead; only the order within a group flips.
      expect(sorted.first.name, 'dir');
      expect(sorted[1].name, 'b');
    });
  });

  group('FileDirectory.formatted', () {
    test('builds full paths with the remote separator', () {
      const dir = FileDirectory(
        path: r'C:\Users\ada',
        entries: [FileEntry(name: 'notes.txt')],
      );

      final formatted = dir.formatted(isWindows: true);

      // A Windows peer browsed from macOS must still get backslash paths.
      expect(formatted.entries.first.path, r'C:\Users\ada\notes.txt');
    });

    test('uses posix separators for a posix peer', () {
      const dir = FileDirectory(
        path: '/home/ada',
        entries: [FileEntry(name: 'notes.txt')],
      );

      final formatted = dir.formatted(isWindows: false);

      expect(formatted.entries.first.path, '/home/ada/notes.txt');
    });

    test('parses the core listing shape', () {
      final dir = FileDirectory.fromJson({
        'id': 7,
        'path': '/home/ada',
        'entries': [
          {'name': 'a.txt', 'entry_type': 4, 'size': 1},
          {'name': 'docs', 'entry_type': 1},
        ],
      });

      expect(dir.id, 7);
      expect(dir.entries.length, 2);
    });

    test('a listing with no entries is empty rather than null', () {
      final dir = FileDirectory.fromJson({'id': 1, 'path': '/'});

      expect(dir.entries, isEmpty);
      expect(dir.isEmpty, isTrue);
    });
  });

  group('PathUtil', () {
    test('joins and splits per platform', () {
      expect(PathUtil.join(r'C:\a', 'b', true), r'C:\a\b');
      expect(PathUtil.join('/a', 'b', false), '/a/b');
      expect(PathUtil.split(r'C:\a\b', true), contains('b'));
    });

    test('dirname walks up on both styles', () {
      expect(PathUtil.dirname(r'C:\a\b', true), r'C:\a');
      expect(PathUtil.dirname('/a/b', false), '/a');
    });

    test('converts a path between platform styles', () {
      // Dragging a file from a posix host to a Windows peer.
      expect(PathUtil.convert('a/b/c', false, true), r'a\b\c');
      expect(PathUtil.convert(r'a\b\c', true, false), 'a/b/c');
    });

    test('mirrors a path onto the other side', () {
      final mirrored = PathUtil.otherSidePath(
          '/home/ada', '/home/ada/docs/x.txt', false, r'C:\Users\ada', true);

      expect(mirrored, r'C:\Users\ada\docs\x.txt');
    });

    test('rejects names illegal on the target platform', () {
      // Windows forbids these; posix only forbids / and NUL.
      expect(PathUtil.isValidName('a:b', true), isFalse);
      expect(PathUtil.isValidName('a?b', true), isFalse);
      expect(PathUtil.isValidName('a:b', false), isTrue);

      expect(PathUtil.isValidName('a/b', false), isFalse);
      expect(PathUtil.isValidName('report.txt', true), isTrue);
    });
  });

  group('FileJob', () {
    test('reports percent and clamps the handled count', () {
      final job = FileJob(id: 1, type: JobType.transfer)
        ..totalSize = 200
        ..finishedSize = 50
        ..fileCount = 3
        ..fileNum = 5
        ..receivedResponse = true;

      expect(job.percent, 0.25);
      expect(job.percentText, '25%');
      // Never report more files handled than exist.
      expect(job.handledFileCount, 3);
    });

    test('a zero-size job does not divide by zero', () {
      final job = FileJob(id: 1)..totalSize = 0;

      expect(job.percent, 0.0);
      expect(job.percentText, '0%');
    });

    test('a done job counts every file', () {
      final job = FileJob(id: 1, state: JobState.done)
        ..fileCount = 4
        ..fileNum = 0;

      expect(job.handledFileCount, 4);
      expect(job.isFinished, isTrue);
    });

    test('distinguishes cancel from skip', () {
      final cancelled = FileJob(id: 1)..error = 'cancel';
      final skipped = FileJob(id: 2)..error = 'skipped';

      expect(cancelled.wasCancelled, isTrue);
      expect(cancelled.wasSkipped, isFalse);
      expect(skipped.wasSkipped, isTrue);
    });

    test('applies a progress event', () {
      final job = FileJob(id: 1);

      job.applyProgress({
        'file_num': '2',
        'speed': '1024.5',
        'finished_size': '500',
        'total_size': '1000',
      });

      expect(job.fileNum, 2);
      expect(job.speed, 1024.5);
      expect(job.percent, 0.5);
      expect(job.state, JobState.inProgress);
    });
  });

  group('readableFileSize', () {
    test('scales by unit', () {
      expect(readableFileSize(512), '512 B');
      expect(readableFileSize(2048), '2.0 kB');
      expect(readableFileSize(5 * 1024 * 1024), '5.0 MB');
      expect(readableFileSize(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });
}
