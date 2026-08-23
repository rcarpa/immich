import 'package:background_downloader/background_downloader.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/offline_paths.dart';
import 'package:logging/logging.dart';

/// immich-sync fork: the mirror's own downloader group, so its tasks can be counted, paused and cancelled without
/// touching anything else using the downloader.
const kOfflineDownloadGroup = 'immich-sync-offline';

/// immich-sync fork: one file the mirror wants to fetch, in the terms the downloader needs.
class OfflineDownload {
  const OfflineDownload({required this.assetId, required this.file, this.isErrand = false});

  final String assetId;
  final OfflineFile file;

  /// Asked for by hand, carried here because it is what the task priority turns on: the queue can order a batch by
  /// anything, but only what reaches the plugin survives the hand-over.
  final bool isErrand;
}

/// immich-sync fork: what a failed download says about the file, which decides whether it counts against the file.
enum OfflineFailureKind {
  /// The server answered, about this file: not found, cannot be produced, refused for this asset. Counted, and a file
  /// that keeps doing it is left alone.
  file,

  /// Nothing reached the server, or the server could not answer for anybody: no network, a timeout, a rejected
  /// session, a proxy with nothing behind it. Says nothing about the file, so it is never counted — and since it will
  /// be true of every file just as much, the queue stops handing work over for a while instead.
  transient,
}

/// Sorts a failure into an [OfflineFailureKind].
///
/// Counting every failure alike is how an expired token or an afternoon off-grid used to cost the mirror its
/// selection: three passes against a server that could not be reached, and every file they tried was given up on until
/// someone found the retry button. That is the very case this fork exists for.
///
/// A 403 is counted, not waited out: Immich answers it about one asset (a partner who stopped sharing), not about the
/// session, which is a 401. A 500 is counted too — it is how the server reports a file it cannot generate, and treating
/// it as an outage would let one broken photo stall the whole queue.
OfflineFailureKind classifyOfflineFailure(TaskStatusUpdate update) {
  if (update.status == TaskStatus.notFound) {
    return OfflineFailureKind.file;
  }
  final exception = update.exception;
  final code = exception is TaskHttpException && exception.httpResponseCode > 0
      ? exception.httpResponseCode
      : update.responseStatusCode;
  if (code != null && code > 0) {
    return switch (code) {
      401 || 407 || 408 || 429 || 502 || 503 || 504 => OfflineFailureKind.transient,
      _ => OfflineFailureKind.file,
    };
  }
  return exception is TaskConnectionException ? OfflineFailureKind.transient : OfflineFailureKind.file;
}

/// immich-sync fork: `background_downloader`, for the offline mirror.
class OfflineDownloadRepository {
  OfflineDownloadRepository() {
    _downloader.registerCallbacks(
      group: kOfflineDownloadGroup,
      taskStatusCallback: (update) {
        // Every transition, not only the ones that end a task: `enqueued` with no later `running` is what a task
        // waiting for one of the group's concurrent slots looks like, and nothing else can see it.
        _log.fine('${update.status.name}: ${update.task.taskId} <${update.task.url}>');
        if (update.status == TaskStatus.running) {
          onStarted?.call(update);
        }
        if (update.status.isFinalState) {
          onFinished?.call(update);
        }
      },
      taskProgressCallback: (update) => onProgress?.call(update),
    );
  }

  static final _downloader = FileDownloader();
  static final _log = Logger('OfflineDownloads');

  void Function(TaskStatusUpdate)? onFinished;

  /// A task left the plugin's holding queue and began transferring. Until then it is waiting its turn, which reports
  /// nothing and is not a sign of anything wrong.
  void Function(TaskStatusUpdate)? onStarted;

  /// How far a big file has got. Only full-size copies report it (see [_taskFor]), so this fires a few times a minute
  /// rather than thousands of times a pass.
  void Function(TaskProgressUpdate)? onProgress;

  /// Tasks the downloader is still holding. Their ids are the blob names, so re-enqueueing one replaces rather than
  /// duplicates it, and a pass can say what it is waiting on rather than only how many.
  Future<List<Task>> outstanding() => _downloader.allTasks(group: kOfflineDownloadGroup);

  /// Hands a batch over, and returns the ones the downloader would not take.
  ///
  /// `enqueueAll` answers per task, and discarding that answer loses files silently: a refused task never runs and
  /// never calls back, so the pass counts it as outstanding, the next pass finds it missing again, and nothing anywhere
  /// says why.
  Future<List<OfflineDownload>> enqueue(List<OfflineDownload> downloads, {required bool wifiOnly}) async {
    final tasks = [for (final download in downloads) _taskFor(download, wifiOnly: wifiOnly)];
    final accepted = await _downloader.enqueueAll(tasks);
    return [
      for (final (index, download) in downloads.indexed)
        if (index >= accepted.length || !accepted[index]) download,
    ];
  }

  /// Whether a task the downloader is holding still carries the token the app holds now.
  ///
  /// The header is fixed when the task is handed over, and the downloader's queue outlives the process — so tasks
  /// queued before a sign-in go on presenting the old token after it, and fail with 401 for as long as they are left
  /// there. A pass hands those back so they are queued again with the current one.
  bool carriesCurrentAuth(Task task) => task.headers['Authorization'] == _authHeaders()['Authorization'];

  Future<void> cancelAll() => _downloader.cancelAll(group: kOfflineDownloadGroup);

  /// Drops particular tasks, so the next pass can find their files missing and ask again.
  Future<void> cancel(Iterable<String> taskIds) => _downloader.cancelTasksWithIds(taskIds.toList());

  DownloadTask _taskFor(OfflineDownload download, {required bool wifiOnly}) => DownloadTask(
    // The filename is the identity, so re-enqueueing the same blob replaces
    // rather than duplicates the task.
    taskId: download.file.name,
    url: download.file.url,
    headers: _authHeaders(),
    filename: download.file.name,
    directory: offlinePinnedRelativeDirectory(download.file.name),
    baseDirectory: BaseDirectory.applicationSupport,
    group: kOfflineDownloadGroup,
    // Progress from the big ones only: they are the ones that can take minutes, and a preview reporting its way to
    // 100% would be thousands of callbacks a pass for something already over.
    updates: download.file.variant.isFullSize ? Updates.statusAndProgress : Updates.status,
    // The plugin runs at most eight of this group at once (`Config.holdingQueue` in `main.dart`)
    // and takes the rest in priority order, never re-ordering what it already holds. So the queue's ordering has to
    // reach the hand-over — as that order, not as a second version of it (FORK.md §3.3).
    priority: offlineTaskPriority(download.file.variant, isErrand: download.isErrand),
    // The completion callback gets a task id and nothing else, and writing down
    // what arrived needs to know whose file it is.
    metaData: '${download.assetId}|${download.file.variant.index}|${download.file.token}',
    // Nothing here is urgent enough to spend cellular data unasked.
    requiresWiFi: wifiOnly,
    retries: 2,
  );

  /// Auth for the downloader, which runs its own URLSession and never sees the app's session cookie — every task would
  /// come back 401. The same token works as a bearer.
  Map<String, String> _authHeaders() {
    final headers = {...ApiService.getRequestHeaders()};
    final token = Store.tryGet(StoreKey.accessToken);
    if (token != null && token.isNotEmpty) {
      headers['Authorization'] = 'Bearer $token';
    }
    return headers;
  }
}
