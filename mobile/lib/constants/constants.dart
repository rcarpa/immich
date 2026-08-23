import 'dart:io';

// immich-sync fork: the product's name, and the one it is a fork of. Used to
// rename the product in upstream's translated strings as they are loaded (see
// utils/brand_translation_loader.dart), so the catalogue itself is never edited.
const String kAppName = "Mirrich";
const String kUpstreamName = "Immich";

const String kMobileMetadataKey = "mobile-app";

// Number of log entries to retain on app start
const int kLogTruncateLimit = 2000;

// Sync
const int kSyncEventBatchSize = 5000;

// Hash batch limits
final int kBatchHashFileLimit = Platform.isIOS ? 32 : 512;

// Secure storage keys
const String kSecuredPinCode = "secured_pin_code";

// background_downloader task groups
const String kManualUploadGroup = 'manual_upload_group';
const String kBackupGroup = 'backup_group';
const String kBackupLivePhotoGroup = 'backup_live_photo_group';
const String kDownloadGroupImage = 'group_image';
const String kDownloadGroupVideo = 'group_video';
const String kDownloadGroupLivePhoto = 'group_livephoto';
const String kShareDownloadGroup = 'group_share';

// immich-sync fork: the groups whose tasks are tracked in the plugin's database, in place of upstream's global
// `trackTasks()`. The offline mirror's group is left out on purpose: it enqueues one task per file, six figures of
// them, and never reads their records back. [kDownloadGroupLivePhoto] is tracked on its own, with different options.
// Shared by the app and the background worker, so neither tracks the mirror by accident.
const List<String> kTrackedTaskGroups = [
  '',
  kBackupGroup,
  kManualUploadGroup,
  kBackupLivePhotoGroup,
  kDownloadGroupImage,
  kDownloadGroupVideo,
  kShareDownloadGroup,
];

// Timeline constants
const int kTimelineAssetLoadBatchSize = 1024;
const int kTimelineAssetLoadOppositeSize = 64;

// Widget keys
const String kWidgetAuthToken = "widget_auth_token";
const String kWidgetServerEndpoint = "widget_server_url";
const String kWidgetCustomHeaders = "widget_custom_headers";

// add widget identifiers here for new widgets
// these are used to force a widget refresh
// (iOSName, androidFQDN)
const List<(String, String)> kWidgetNames = [
  ('com.immich.widget.random', 'app.alextran.immich.widget.RandomReceiver'),
  ('com.immich.widget.memory', 'app.alextran.immich.widget.MemoryReceiver'),
];

const int kMinMonthsToEnableScrubberSnap = 12;

const String kImmichAppStoreLink = "https://apps.apple.com/app/immich/id1613945652";
const String kImmichPlayStoreLink = "https://play.google.com/store/apps/details?id=app.alextran.immich";
const String kImmichLatestRelease = "https://github.com/immich-app/immich/releases/latest";

const int kPhotoTabIndex = 0;
const int kSearchTabIndex = 1;
const int kAlbumTabIndex = 2;
// ignore: unused-code
const int kLibraryTabIndex = 3;

// Workaround for SQLite's variable limit (SQLITE_MAX_VARIABLE_NUMBER = 32766)
const int kDriftMaxChunk = 32000;
