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

/// immich-sync fork: `background_downloader`, for the offline mirror.
class OfflineDownloadRepository {
  OfflineDownloadRepository() {
    _downloader.registerCallbacks(
      group: kOfflineDownloadGroup,
      taskStatusCallback: (update) {
        // Every transition, not only the ones that end a task: `enqueued` with no later `running` is what a task
        // waiting for one of the group's three concurrent slots looks like, and nothing else can see it.
        _log.fine('${update.status.name}: ${update.task.taskId} <${update.task.url}>');
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

  /// How far a big file has got. Only full-size copies report it (see [_taskFor]), so this fires a few times a minute
  /// rather than thousands of times a pass.
  void Function(TaskProgressUpdate)? onProgress;

  /// Tasks the downloader is still holding, by blob name — which is also the task id, so re-enqueueing a blob replaces
  /// rather than duplicates it.
  Future<Set<String>> outstandingIds() async => (await outstanding()).map((task) => task.taskId).toSet();

  /// The tasks themselves, for a pass that wants to say what it is waiting on rather than only how many.
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
    // The plugin runs at most three of this group at once (`Config.holdingQueue` in `main.dart`)
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
