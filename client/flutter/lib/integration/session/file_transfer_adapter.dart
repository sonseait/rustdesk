import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/integration/bridge/platform_ffi.dart';
import 'package:flutter_hbb/integration/platform/host_platform.dart';
import 'package:flutter_hbb/integration/session/file_models.dart';

/// Which side of the transfer a pane shows.
enum FileSide { local, remote }

/// A request from the core to confirm overwriting a file.
///
/// The core blocks the transfer until it is answered, so the UI must respond
/// to every one of these or the job stalls.
@immutable
class OverwriteRequest {
  const OverwriteRequest({
    required this.jobId,
    required this.fileNum,
    required this.path,
    required this.isUpload,
  });

  final int jobId;
  final int fileNum;
  final String path;
  final bool isUpload;
}

/// One side of the file manager.
///
/// Ported from `FileController` in `flutter_legacy/lib/models/file_model.dart`.
/// The local side is read straight off disk; the remote side is requested from
/// the core and arrives asynchronously on the `file_dir` event.
class FilePane extends ChangeNotifier {
  FilePane({
    required this.side,
    required this.sessionId,
    RustdeskImpl? bindOverride,
  }) : _bindOverride = bindOverride;

  final FileSide side;
  final UuidValue sessionId;
  final RustdeskImpl? _bindOverride;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  FileDirectory _directory = const FileDirectory();
  SortBy _sortBy = SortBy.name;
  bool _ascending = true;
  bool _showHidden = false;
  bool _loading = false;
  Object? _error;

  /// The peer's platform, which decides path separators for the remote side.
  bool isPeerWindows = false;

  bool get isWindowsSide => side == FileSide.local ? isWindows : isPeerWindows;

  FileDirectory get directory => _directory;

  List<FileEntry> get entries => _directory.entries;

  String get path => _directory.path;

  SortBy get sortBy => _sortBy;

  bool get ascending => _ascending;

  bool get showHidden => _showHidden;

  bool get isLoading => _loading;

  Object? get error => _error;

  /// Read [target], or refresh the current directory when null.
  Future<void> openDirectory([String? target]) async {
    final next = target ?? _directory.path;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      if (side == FileSide.local) {
        _apply(await _readLocalDirectory(next));
      } else {
        // The listing arrives later on the `file_dir` event.
        await _bind.sessionReadRemoteDir(
          sessionId: sessionId,
          path: next,
          includeHidden: _showHidden,
        );
      }
    } catch (e) {
      debugPrint('failed to open $next: $e');
      _error = e;
      _loading = false;
      notifyListeners();
    }
  }

  /// Go to the parent directory. No-op at the root.
  Future<void> goUp() async {
    final parent = PathUtil.dirname(_directory.path, isWindowsSide);
    if (parent == _directory.path) return;
    await openDirectory(parent);
  }

  /// Apply a listing that arrived on the `file_dir` event.
  void receiveDirectory(FileDirectory directory) {
    _apply(directory);
  }

  void _apply(FileDirectory directory) {
    _directory = directory.formatted(
      isWindows: isWindowsSide,
      sortBy: _sortBy,
      ascending: _ascending,
    );
    _loading = false;
    _error = null;
    notifyListeners();
  }

  Future<FileDirectory> _readLocalDirectory(String target) async {
    // An empty path means "wherever the user starts", which is home.
    final resolved = target.isEmpty ? _defaultLocalPath() : target;
    final dir = Directory(resolved);
    final entries = <FileEntry>[];
    await for (final item in dir.list(followLinks: false)) {
      final name = PathUtil.split(item.path, isWindows).last;
      if (!_showHidden && name.startsWith('.')) continue;
      final stat = await item.stat();
      entries.add(FileEntry(
        name: name,
        // Directories are entry type 1, files 4, matching the core.
        entryType: stat.type == FileSystemEntityType.directory ? 1 : 4,
        modifiedTime: stat.modified.millisecondsSinceEpoch ~/ 1000,
        size: stat.size,
      ));
    }
    return FileDirectory(entries: entries, path: resolved);
  }

  String _defaultLocalPath() =>
      Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.current.path;

  void setSort(SortBy sortBy, {bool? ascending}) {
    // Tapping the active column flips the direction.
    final nextAscending =
        ascending ?? (_sortBy == sortBy ? !_ascending : true);
    if (_sortBy == sortBy && _ascending == nextAscending) return;
    _sortBy = sortBy;
    _ascending = nextAscending;
    _directory = FileDirectory(
      entries: sortEntries(_directory.entries, _sortBy,
          ascending: _ascending),
      id: _directory.id,
      path: _directory.path,
    );
    notifyListeners();
  }

  Future<void> setShowHidden(bool value) async {
    if (_showHidden == value) return;
    _showHidden = value;
    await openDirectory();
  }
}

/// Drives file transfer for one session.
///
/// Owns both panes, the job queue, and the events the core sends while a
/// transfer runs. Ported from `FileModel`/`JobController`.
class FileTransferAdapter extends ChangeNotifier {
  FileTransferAdapter({
    required this.sessionId,
    RustdeskImpl? bindOverride,
  })  : _bindOverride = bindOverride,
        local = FilePane(
            side: FileSide.local,
            sessionId: sessionId,
            bindOverride: bindOverride),
        remote = FilePane(
            side: FileSide.remote,
            sessionId: sessionId,
            bindOverride: bindOverride);

  final UuidValue sessionId;
  final RustdeskImpl? _bindOverride;

  final FilePane local;
  final FilePane remote;

  RustdeskImpl get _bind => _bindOverride ?? bind;

  final Map<int, FileJob> _jobs = {};
  int _nextJobId = 1;
  OverwriteRequest? _overwriteRequest;

  /// Active and finished jobs, newest first.
  List<FileJob> get jobs =>
      _jobs.values.toList()..sort((a, b) => b.id.compareTo(a.id));

  List<FileJob> get activeJobs =>
      _jobs.values.where((j) => !j.isFinished).toList();

  /// The overwrite confirmation the core is waiting on, if any.
  OverwriteRequest? get overwriteRequest => _overwriteRequest;

  FilePane paneOf(FileSide side) => side == FileSide.local ? local : remote;

  /// Load both sides.
  Future<void> start({required bool isPeerWindows}) async {
    remote.isPeerWindows = isPeerWindows;
    local.addListener(notifyListeners);
    remote.addListener(notifyListeners);
    await local.openDirectory();
    // An empty remote path asks the core for the peer's default directory.
    await remote.openDirectory('');
  }

  /// Handle a session event. Returns true when it was a file event.
  bool handleEvent(Map<String, dynamic> event) {
    switch (event['name']) {
      case 'file_dir':
        _handleFileDir(event);
        return true;
      case 'job_progress':
        _handleJobProgress(event);
        return true;
      case 'job_done':
        _handleJobDone(event);
        return true;
      case 'job_error':
        _handleJobError(event);
        return true;
      case 'override_file_confirm':
        _handleOverwriteConfirm(event);
        return true;
      default:
        return false;
    }
  }

  void _handleFileDir(Map<String, dynamic> event) {
    final raw = event['value'];
    if (raw is! String || raw.isEmpty) return;
    try {
      final decoded = jsonDecodeMap(raw);
      if (decoded == null) return;
      final directory = FileDirectory.fromJson(decoded);
      // `is_local` tells which pane asked for it.
      final isLocal = event['is_local'] == 'true' || event['is_local'] == true;
      (isLocal ? local : remote).receiveDirectory(directory);
    } catch (e) {
      debugPrint('failed to decode a directory listing: $e');
    }
  }

  void _handleJobProgress(Map<String, dynamic> event) {
    final id = int.tryParse('${event['id']}');
    if (id == null) return;
    final job = _jobs[id];
    if (job == null) return;
    job.applyProgress(event);
    notifyListeners();
  }

  void _handleJobDone(Map<String, dynamic> event) {
    final id = int.tryParse('${event['id']}');
    if (id == null) return;
    final job = _jobs[id];
    if (job == null) return;
    job.state = JobState.done;
    job.finishedSize = job.totalSize;
    notifyListeners();
    // The listing changed on whichever side received the files.
    unawaited(refreshAfterJob(job));
  }

  void _handleJobError(Map<String, dynamic> event) {
    final id = int.tryParse('${event['id']}');
    if (id == null) return;
    final job = _jobs[id];
    if (job == null) return;
    job.state = JobState.error;
    job.error = event['err']?.toString() ?? '';
    notifyListeners();
  }

  void _handleOverwriteConfirm(Map<String, dynamic> event) {
    final id = int.tryParse('${event['id']}');
    final fileNum = int.tryParse('${event['file_num']}');
    if (id == null || fileNum == null) return;
    _overwriteRequest = OverwriteRequest(
      jobId: id,
      fileNum: fileNum,
      path: event['read_path']?.toString() ?? '',
      isUpload: event['is_upload'] == 'true' || event['is_upload'] == true,
    );
    notifyListeners();
  }

  /// Answer the pending overwrite request.
  ///
  /// The transfer stays blocked until this is called.
  Future<void> answerOverwrite(
      {required bool overwrite, bool remember = false}) async {
    final request = _overwriteRequest;
    if (request == null) return;
    _overwriteRequest = null;
    notifyListeners();
    await _bind.sessionSetConfirmOverrideFile(
      sessionId: sessionId,
      actId: request.jobId,
      fileNum: request.fileNum,
      needOverride: overwrite,
      remember: remember,
      isUpload: request.isUpload,
    );
  }

  /// Copy [entries] from [from] to the other side's current directory.
  Future<void> transfer(List<FileEntry> entries, FileSide from) async {
    if (entries.isEmpty) return;
    final source = paneOf(from);
    final target = paneOf(from == FileSide.local
        ? FileSide.remote
        : FileSide.local);

    for (final entry in entries) {
      final id = _nextJobId++;
      final destination =
          PathUtil.join(target.path, entry.name, target.isWindowsSide);
      _jobs[id] = FileJob(
        id: id,
        type: JobType.transfer,
        state: JobState.inProgress,
        fileName: entry.name,
        jobName: entry.path,
        to: destination,
        // isRemote tells the core which side to read from.
        isRemoteToLocal: from == FileSide.remote,
      )..fileCount = 1;

      await _bind.sessionSendFiles(
        sessionId: sessionId,
        actId: id,
        path: entry.path,
        to: destination,
        fileNum: 0,
        includeHidden: source.showHidden,
        isRemote: from == FileSide.remote,
        isDir: entry.isDirectory,
      );
    }
    notifyListeners();
  }

  /// Delete [entry] on [side].
  Future<void> remove(FileEntry entry, FileSide side) async {
    final id = _nextJobId++;
    _jobs[id] = FileJob(
      id: id,
      type: entry.isDirectory ? JobType.deleteDir : JobType.deleteFile,
      state: JobState.inProgress,
      fileName: entry.name,
      jobName: entry.path,
    )..fileCount = 1;
    notifyListeners();

    if (entry.isDirectory) {
      await _bind.sessionReadDirToRemoveRecursive(
        sessionId: sessionId,
        actId: id,
        path: entry.path,
        isRemote: side == FileSide.remote,
        showHidden: paneOf(side).showHidden,
      );
    } else {
      await _bind.sessionRemoveFile(
        sessionId: sessionId,
        actId: id,
        path: entry.path,
        fileNum: 0,
        isRemote: side == FileSide.remote,
      );
    }
  }

  /// Create a directory named [name] on [side].
  Future<void> createDirectory(String name, FileSide side) async {
    final pane = paneOf(side);
    if (!PathUtil.isValidName(name, pane.isWindowsSide)) {
      throw ArgumentError('invalid directory name: $name');
    }
    await _bind.sessionCreateDir(
      sessionId: sessionId,
      actId: _nextJobId++,
      path: PathUtil.join(pane.path, name, pane.isWindowsSide),
      isRemote: side == FileSide.remote,
    );
    await pane.openDirectory();
  }

  /// Cancel a running job.
  Future<void> cancel(int jobId) async {
    await _bind.sessionCancelJob(sessionId: sessionId, actId: jobId);
    final job = _jobs[jobId];
    if (job != null) {
      job.state = JobState.done;
      job.error = 'cancel';
      notifyListeners();
    }
  }

  /// Refresh whichever side a finished job wrote to.
  Future<void> refreshAfterJob(FileJob job) async {
    if (job.type == JobType.transfer) {
      await (job.isRemoteToLocal ? local : remote).openDirectory();
    } else {
      await local.openDirectory();
      await remote.openDirectory();
    }
  }

  /// Forget finished jobs.
  void clearFinishedJobs() {
    _jobs.removeWhere((_, job) => job.isFinished);
    notifyListeners();
  }

  @override
  void dispose() {
    local.removeListener(notifyListeners);
    remote.removeListener(notifyListeners);
    local.dispose();
    remote.dispose();
    super.dispose();
  }
}

/// Decode a JSON object, returning null rather than throwing.
Map<String, dynamic>? jsonDecodeMap(String raw) {
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (e) {
    debugPrint('failed to decode json: $e');
    return null;
  }
}
