import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// How a directory listing is ordered.
enum SortBy { name, type, modified, size }

/// One entry in a directory listing.
///
/// Ported from `Entry` in `flutter_legacy/lib/models/file_model.dart`. The
/// `entry_type` numbering is the Rust contract: below 3 is a directory, 3 is a
/// drive, above 3 is a file.
@immutable
class FileEntry {
  const FileEntry({
    required this.name,
    this.path = '',
    this.entryType = 4,
    this.modifiedTime = 0,
    this.size = 0,
  });

  FileEntry.fromJson(Map<String, dynamic> json)
      : name = json['name'] ?? '',
        path = '',
        entryType = json['entry_type'] ?? 4,
        modifiedTime = json['modified_time'] ?? 0,
        size = json['size'] ?? 0;

  final String name;

  /// Full path, filled in by [FileDirectory.formatted].
  final String path;

  final int entryType;

  /// Seconds since the epoch, as the core reports it.
  final int modifiedTime;

  final int size;

  bool get isDirectory => entryType < 3;

  bool get isDrive => entryType == 3;

  bool get isFile => entryType > 3;

  DateTime get lastModified =>
      DateTime.fromMillisecondsSinceEpoch(modifiedTime * 1000);

  FileEntry withPath(String value) => FileEntry(
        name: name,
        path: value,
        entryType: entryType,
        modifiedTime: modifiedTime,
        size: size,
      );

  @override
  bool operator ==(Object other) =>
      other is FileEntry && other.path == path && other.name == name;

  @override
  int get hashCode => Object.hash(path, name);

  @override
  String toString() => 'FileEntry($name, dir: $isDirectory)';
}

/// A directory listing.
@immutable
class FileDirectory {
  const FileDirectory({
    this.entries = const [],
    this.id = 0,
    this.path = '',
  });

  FileDirectory.fromJson(Map<String, dynamic> json)
      : id = json['id'] ?? 0,
        path = json['path'] ?? '',
        entries = [
          for (final e in (json['entries'] as List<dynamic>? ?? []))
            if (e is Map<String, dynamic>) FileEntry.fromJson(e)
        ];

  final List<FileEntry> entries;
  final int id;
  final String path;

  bool get isEmpty => entries.isEmpty;

  /// Fill in each entry's full path and sort.
  ///
  /// Paths are joined with the *remote* platform's separator, so a Windows
  /// peer browsed from macOS still produces backslash paths the peer accepts.
  FileDirectory formatted({required bool isWindows, SortBy? sortBy,
      bool ascending = true}) {
    var formatted = [
      for (final entry in entries)
        entry.withPath(PathUtil.join(path, entry.name, isWindows))
    ];
    if (sortBy != null) {
      formatted = sortEntries(formatted, sortBy, ascending: ascending);
    }
    return FileDirectory(entries: formatted, id: id, path: path);
  }
}

/// Sort a listing, keeping directories above files.
///
/// Ported from `_sortList`. Directories always come first regardless of the
/// key, which is what makes a listing navigable.
List<FileEntry> sortEntries(List<FileEntry> entries, SortBy sortBy,
    {bool ascending = true}) {
  final dirs = entries.where((e) => e.isDirectory || e.isDrive).toList();
  final files = entries.where((e) => e.isFile).toList();

  int compare(FileEntry a, FileEntry b) {
    final int result;
    switch (sortBy) {
      case SortBy.name:
        result = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        break;
      case SortBy.type:
        result = _extensionOf(a.name).compareTo(_extensionOf(b.name));
        break;
      case SortBy.modified:
        result = a.modifiedTime.compareTo(b.modifiedTime);
        break;
      case SortBy.size:
        result = a.size.compareTo(b.size);
        break;
    }
    return ascending ? result : -result;
  }

  dirs.sort(compare);
  files.sort(compare);
  return [...dirs, ...files];
}

String _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? '' : name.substring(dot + 1).toLowerCase();
}

/// What a job is doing.
enum JobType { none, transfer, deleteFile, deleteDir }

/// Where a job is in its lifecycle.
enum JobState { none, inProgress, done, error, paused }

/// A file transfer or deletion in progress.
///
/// Ported from `JobProgress`. The core reports progress by job id, so this is
/// mutable and updated in place as events arrive.
class FileJob {
  FileJob({
    required this.id,
    this.type = JobType.none,
    this.state = JobState.none,
    this.fileName = '',
    this.jobName = '',
    this.to = '',
    this.isRemoteToLocal = false,
  });

  final int id;

  JobType type;
  JobState state;

  /// True when the transfer goes remote -> local (a download).
  bool isRemoteToLocal;

  String jobName;
  String fileName;
  String to;

  int fileNum = 0;
  int fileCount = 0;
  double speed = 0;
  int finishedSize = 0;
  int totalSize = 0;
  String error = '';

  /// True once the core acknowledged the job.
  bool receivedResponse = false;

  double get percent => totalSize > 0 ? finishedSize / totalSize : 0.0;

  String get percentText => '${(percent * 100).toStringAsFixed(0)}%';

  bool get isFinished => state == JobState.done || state == JobState.error;

  bool get wasCancelled => error == 'cancel';

  bool get wasSkipped => error == 'skipped';

  /// Files handled so far, clamped to the total.
  int get handledFileCount {
    if (state == JobState.done) return fileCount;
    final handled = receivedResponse ? fileNum + 1 : fileNum;
    return handled > fileCount ? fileCount : handled;
  }

  void applyProgress(Map<String, dynamic> event) {
    fileNum = int.tryParse('${event['file_num']}') ?? fileNum;
    speed = double.tryParse('${event['speed']}') ?? speed;
    finishedSize = int.tryParse('${event['finished_size']}') ?? finishedSize;
    totalSize = int.tryParse('${event['total_size']}') ?? totalSize;
    state = JobState.inProgress;
    receivedResponse = true;
  }

  @override
  String toString() => 'FileJob($id, $type, $state, $percentText)';
}

/// Path helpers that respect the *remote* platform's separator.
///
/// Ported from `PathUtil`. A file manager always deals with two platforms at
/// once, so every path operation has to say which side it is for.
class PathUtil {
  static final windows = p.Context(style: p.Style.windows);
  static final posix = p.Context(style: p.Style.posix);

  static p.Context _context(bool isWindows) => isWindows ? windows : posix;

  static String join(String a, String b, bool isWindows) =>
      _context(isWindows).join(a, b);

  static List<String> split(String path, bool isWindows) =>
      _context(isWindows).split(path);

  static String dirname(String path, bool isWindows) =>
      _context(isWindows).dirname(path);

  /// Translate a path from one platform's style to the other's.
  static String convert(String path, bool fromWindows, bool toWindows) =>
      _context(toWindows).joinAll(_context(fromWindows).split(path));

  /// The path on the other side that mirrors [mainPath] under [otherRoot].
  static String otherSidePath(
    String mainRoot,
    String mainPath,
    bool isMainWindows,
    String otherRoot,
    bool isOtherWindows,
  ) {
    final relative = _context(isMainWindows).relative(mainPath, from: mainRoot);
    final names = _context(isMainWindows).split(relative);
    var result = otherRoot;
    for (final name in names) {
      result = _context(isOtherWindows).join(result, name);
    }
    return result;
  }

  /// Whether [name] is a legal file name on the target platform.
  static bool isValidName(String name, bool isWindows) {
    final pattern = isWindows
        ? RegExp(r'^[^<>:"/\\|?*]+$')
        : RegExp(r'^[^/\0]+$');
    return pattern.hasMatch(name);
  }
}

const int _kB = 1024;
const int _mB = _kB * _kB;
const int _gB = _mB * _kB;

/// Human-readable byte size, matching the legacy `readableFileSize`.
String readableFileSize(num size, {int decimals = 1}) {
  if (size < _kB) return '${size.toStringAsFixed(0)} B';
  if (size < _mB) return '${(size / _kB).toStringAsFixed(decimals)} kB';
  if (size < _gB) return '${(size / _mB).toStringAsFixed(decimals)} MB';
  return '${(size / _gB).toStringAsFixed(decimals)} GB';
}
