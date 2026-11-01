/// immich-sync fork: the offline copies screen. *Downloading* first, since that is what it is opened to check, then
/// *What to keep offline*, then *Storage*. The albums are one screen further in (`offline_albums.page.dart`).
library;

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/offline_sync.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_cleanup_sheet.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_reclaim_dialog.dart';
import 'package:immich_mobile/presentation/widgets/offline/quality_menu.widget.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/session_state.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';

@RoutePage()
class OfflineSyncPage extends ConsumerStatefulWidget {
  const OfflineSyncPage({super.key});

  @override
  ConsumerState<OfflineSyncPage> createState() => _OfflineSyncPageState();
}

class _OfflineSyncPageState extends ConsumerState<OfflineSyncPage> {
  @override
  void initState() {
    super.initState();
    // Refresh the figures without downloading: opening a screen is not a request to spend data.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(offlineSyncServiceProvider).sync(download: false));
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(offlineStatusProvider).valueOrNull ?? const OfflineStatus();
    final service = ref.watch(offlineSyncServiceProvider);
    final policy = ref.watch(offlinePolicyProvider);
    final wifiOnly = ref.watch(appConfigProvider.select((config) => config.offlineWifiOnly));

    return Scaffold(
      appBar: AppBar(title: const Text('Offline copies')),
      body: CustomScrollView(
        slivers: [
          SliverList.list(
            children: [
              const _SectionTitle('Downloading'),
              _Summary(status: status),
              _DownloadingSwitch(status: status, service: service),
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.wifi),
                title: const Text('Wi-Fi only'),
                subtitle: const Text('Downloads wait until you are on Wi-Fi'),
                value: wifiOnly,
                onChanged: (value) => unawaited(_setWifiOnly(value)),
              ),

              const Divider(height: 1),
              const _SectionTitle('Persistent offline library'),
              const _Explainer(),
              OfflineSelectionRow(
                title: 'Entire library',
                subtitle: 'Everything on the server, now and later',
                value: OfflineChoice.ofQuality(policy.library),
                labels: kOfflineLibraryChoices,
                onSelected: (choice) =>
                    unawaited(service.applyPolicy((current) => current.withLibrary(choice.quality))),
              ),
              const _AlbumsRow(),
            ],
          ),
          // The app draws under the navigation bar, and a CustomScrollView does not pad for it like a ListView does.
          SliverSafeArea(
            top: false,
            sliver: SliverList.list(
              children: const [Divider(height: 1), _SectionTitle('Storage'), _StorageOverview(), SizedBox(height: 8)],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _setWifiOnly(bool value) async {
    final settings = ref.read(settingsProvider);
    final service = ref.read(offlineSyncServiceProvider);
    await settings.write(SettingsKey.offlineWifiOnly, value);
    // Restart, so running downloads follow the new setting too. `stopDownloads` does not persist a pause.
    if (!service.current.isPaused) {
      await service.stopDownloads();
      await service.sync();
    }
  }
}

class _SubSection extends StatelessWidget {
  const _SubSection({required this.title, required this.bytes});

  final String title;
  final int bytes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: context.textTheme.titleMedium),
        Text(formatBytes(bytes), style: context.textTheme.titleMedium),
      ],
    ),
  );
}

class _AlbumsRow extends ConsumerWidget {
  const _AlbumsRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(offlinePolicyProvider);
    final kept = policy.albums.length;
    final excluded = policy.excluded.length;

    final parts = [if (kept > 0) '$kept kept', if (excluded > 0) '$excluded excluded'];

    return ListTile(
      title: const Text('Albums'),
      subtitle: Text(parts.isEmpty ? 'All following the setting above' : parts.join(' · ')),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: () => unawaited(context.pushRoute(const OfflineAlbumsRoute())),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(title, style: context.textTheme.titleSmall?.copyWith(color: context.colorScheme.primary)),
  );
}

/// Above both the library row and the albums, because it governs both.
class _Explainer extends ConsumerWidget {
  const _Explainer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selects = ref.watch(offlinePolicyProvider).selectsAnything;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        selects
            ? 'What you choose is downloaded and kept up to date with new arrivals. Turning a row off stops '
                  'downloading it; what is already here becomes spares, removed first when space runs out.'
            : 'You have not chosen anything to keep offline yet. Nothing new will be downloaded.',
        style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

/// Eight colours, fixed: four for the offline library, and four for the same kinds once nothing asks for them.
class _Palette {
  const _Palette({
    required this.libraryVideo,
    required this.libraryOriginal,
    required this.libraryPreview,
    required this.libraryThumbnail,
    required this.freeVideo,
    required this.freeOriginal,
    required this.freePreview,
    required this.freeThumbnail,
  });

  factory _Palette.of(BuildContext context) => _Palette(
    libraryVideo: context.colorScheme.primary,
    libraryOriginal: context.colorScheme.primary.withValues(alpha: 0.72),
    libraryPreview: context.colorScheme.primary.withValues(alpha: 0.45),
    libraryThumbnail: context.colorScheme.primary.withValues(alpha: 0.25),
    freeVideo: context.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
    freeOriginal: context.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
    freePreview: context.colorScheme.onSurfaceVariant.withValues(alpha: 0.32),
    freeThumbnail: context.colorScheme.onSurfaceVariant.withValues(alpha: 0.18),
  );

  final Color libraryVideo;
  final Color libraryOriginal;
  final Color libraryPreview;
  final Color libraryThumbnail;
  final Color freeVideo;
  final Color freeOriginal;
  final Color freePreview;
  final Color freeThumbnail;
}

/// The four kinds of file in the store. Previews and thumbnails are separate here: at the thumbnail rung one is library
/// and the other a spare.
const _videosLabel = 'Videos';
const _originalsLabel = 'Full-size photos';
const _previewsLabel = 'Previews';
const _thumbnailsLabel = 'Thumbnails';

/// Where the bytes went, and the only controls that take any back.
class _StorageOverview extends ConsumerWidget {
  const _StorageOverview();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final storage = ref.watch(offlineStorageProvider).valueOrNull;
    final onDevice = ref.watch(offlineStatusProvider).valueOrNull?.onDevice ?? 0;
    if (storage == null) {
      return const ListTile(title: Text('Measuring…'));
    }
    if (storage.isEmpty) {
      return const ListTile(
        leading: Icon(Icons.inbox_outlined),
        title: Text('Nothing stored yet'),
        subtitle: Text('Selected items appear as they download, and photos you open are kept as spares'),
      );
    }

    final palette = _Palette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SubSection(title: 'On this device', bytes: storage.bytes),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _StorageBar(storage: storage, palette: palette),
              const SizedBox(height: 8),
              _Legend(palette: palette),
              const SizedBox(height: 6),
              Text(
                'Spares are photos you opened, copies you saved by hand, and copies a changed selection left behind. '
                'When space runs out, the least recently used spares are removed first.',
                style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
              // A saving, not a failure, so it is shown here rather than beside downloading.
              if (onDevice > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '$onDevice files are not stored here: your camera roll already holds them at full size, and the app '
                  'reads them from there. They are fetched if that copy goes.',
                  style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ],
            ],
          ),
        ),

        const _StorageHeader(),
        _KindRow(
          title: _videosLabel,
          libraryBytes: storage.libraryVideoBytes,
          libraryColor: palette.libraryVideo,
          freeBytes: storage.spareVideoBytes,
          freeColor: palette.freeVideo,
        ),
        _KindRow(
          title: _originalsLabel,
          libraryBytes: storage.libraryOriginalBytes,
          libraryColor: palette.libraryOriginal,
          freeBytes: storage.spareOriginalBytes,
          freeColor: palette.freeOriginal,
        ),
        _KindRow(
          title: _previewsLabel,
          libraryBytes: storage.libraryPreviewBytes,
          libraryColor: palette.libraryPreview,
          freeBytes: storage.sparePreviewBytes,
          freeColor: palette.freePreview,
        ),
        _KindRow(
          title: _thumbnailsLabel,
          libraryBytes: storage.libraryThumbnailBytes,
          libraryColor: palette.libraryThumbnail,
          freeBytes: storage.spareThumbnailBytes,
          freeColor: palette.freeThumbnail,
        ),
        const _StorageLimitRow(),
        // Removal has a screen of its own, so this one only reports.
        _FreeUpSpaceRow(bytes: storage.spareBytes),
      ],
    );
  }
}

class _StorageBar extends StatelessWidget {
  const _StorageBar({required this.storage, required this.palette});

  final OfflineStorage storage;
  final _Palette palette;

  @override
  Widget build(BuildContext context) {
    // The library and its spares: what the selections above cost.
    final total = storage.libraryBytes + storage.spareBytes;
    if (total <= 0) {
      return const SizedBox.shrink();
    }

    final segments = <(Color, int)>[
      (palette.libraryVideo, storage.libraryVideoBytes),
      (palette.libraryOriginal, storage.libraryOriginalBytes),
      (palette.libraryPreview, storage.libraryPreviewBytes),
      (palette.libraryThumbnail, storage.libraryThumbnailBytes),
      (palette.freeVideo, storage.spareVideoBytes),
      (palette.freeOriginal, storage.spareOriginalBytes),
      (palette.freePreview, storage.sparePreviewBytes),
      (palette.freeThumbnail, storage.spareThumbnailBytes),
    ];

    return ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(4)),
      child: Row(
        children: [
          for (final (color, bytes) in segments)
            if (bytes > 0)
              Expanded(
                flex: (bytes * 1000 / total).round().clamp(1, 1000),
                child: ColoredBox(color: color, child: const SizedBox(height: 10)),
              ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.palette});

  final _Palette palette;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 14,
    runSpacing: 4,
    children: [_chip(context, palette.libraryVideo, 'library'), _chip(context, palette.freeVideo, 'spares')],
  );

  Widget _chip(BuildContext context, Color color, String label) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 6,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: color, borderRadius: const BorderRadius.all(Radius.circular(2))),
      ),
      Text(label, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant)),
    ],
  );
}

/// Names the two columns, in the same geometry as the rows below so each word sits over its own figures.
class _StorageHeader extends StatelessWidget {
  const _StorageHeader();

  @override
  Widget build(BuildContext context) {
    final style = context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
      child: Row(
        children: [
          const Expanded(child: SizedBox.shrink()),
          SizedBox(
            width: _StorageLine.figureWidth,
            child: Text('library', textAlign: TextAlign.end, style: style),
          ),
          SizedBox(
            width: _StorageLine.figureWidth,
            child: Text('spares', textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }
}

/// One kind of file: what the settings keep, what nothing keeps, and a button to remove the latter.
class _KindRow extends StatelessWidget {
  const _KindRow({
    required this.title,
    this.libraryBytes,
    this.libraryColor,
    required this.freeBytes,
    required this.freeColor,
  });

  final String title;

  final int? libraryBytes;
  final Color? libraryColor;

  final int freeBytes;
  final Color freeColor;

  @override
  Widget build(BuildContext context) => _StorageLine(
    title: title,
    first: libraryBytes == null ? null : (formatBytes(libraryBytes!), libraryColor!),
    second: (formatBytes(freeBytes), freeColor),
  );
}

/// One row of the storage table: a title and two figures, each in the colour of its slice of the bar.
class _StorageLine extends StatelessWidget {
  const _StorageLine({required this.title, required this.first, required this.second});

  final String title;

  /// Null where the row has no library half. A dash rather than `0 B`, which would read as "none yet".
  final (String, Color)? first;
  final (String, Color) second;

  static const figureWidth = 84.0;

  static const _rowHeight = 44.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: _rowHeight,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
          SizedBox(width: figureWidth, child: _figure(context, first)),
          SizedBox(width: figureWidth, child: _figure(context, second)),
        ],
      ),
    ),
  );

  Widget _figure(BuildContext context, (String, Color)? value) => Text(
    value == null ? '—' : value.$1,
    textAlign: TextAlign.end,
    style: context.textTheme.labelLarge?.copyWith(color: value?.$2 ?? context.colorScheme.onSurfaceVariant),
  );
}

/// The ceiling on the whole store. Spares are evicted to stay under it; once only the library is left, downloading
/// stops.
class _StorageLimitRow extends ConsumerWidget {
  const _StorageLimitRow();

  static const _steps = <(int, String)>[
    (1024 * 1024 * 1024, '1 GB'),
    (2 * 1024 * 1024 * 1024, '2 GB'),
    (5 * 1024 * 1024 * 1024, '5 GB'),
    (10 * 1024 * 1024 * 1024, '10 GB'),
    (20 * 1024 * 1024 * 1024, '20 GB'),
    (50 * 1024 * 1024 * 1024, '50 GB'),
    (100 * 1024 * 1024 * 1024, '100 GB'),
    (200 * 1024 * 1024 * 1024, '200 GB'),
    (0, 'No limit'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) => _SizeSliderRow(
    title: 'Storage limit',
    subtitle: 'Spares make room first; downloading stops when only your library is left',
    steps: _steps,
    value: ref.watch(appConfigProvider.select((config) => config.offlineStorageLimit)),
    onChanged: (value) => unawaited(ref.read(offlineSyncServiceProvider).setStorageLimit(value)),
  );
}

/// A size, chosen by dragging over steps rather than bytes, so small limits are reachable.
class _SizeSliderRow extends StatefulWidget {
  const _SizeSliderRow({
    required this.title,
    required this.subtitle,
    required this.steps,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final List<(int, String)> steps;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_SizeSliderRow> createState() => _SizeSliderRowState();
}

class _SizeSliderRowState extends State<_SizeSliderRow> {
  double? _dragging;

  int get _index {
    final exact = widget.steps.indexWhere((step) => step.$1 == widget.value);
    if (exact >= 0) {
      return exact;
    }
    // A value not on the ladder (older build, hand-edited): show the nearest step at or above it.
    final above = widget.steps.indexWhere((step) => step.$1 >= widget.value);
    return above >= 0 ? above : widget.steps.length - 1;
  }

  @override
  Widget build(BuildContext context) {
    final index = _dragging ?? _index.toDouble();
    final label = widget.steps[index.round()].$2;
    final ends = context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: DecoratedBox(
        // A block of its own, so the slider does not read as part of the table.
        decoration: BoxDecoration(
          color: context.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: const BorderRadius.all(Radius.circular(12)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: Text(widget.title, style: context.textTheme.titleSmall)),
                  Text(label, style: context.textTheme.titleMedium?.copyWith(color: context.colorScheme.primary)),
                ],
              ),
              Text(
                widget.subtitle,
                style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
              Row(
                children: [
                  Text(widget.steps.first.$2, style: ends),
                  Expanded(
                    child: Slider(
                      value: index,
                      max: (widget.steps.length - 1).toDouble(),
                      divisions: widget.steps.length - 1,
                      label: label,
                      onChanged: (value) => setState(() => _dragging = value),
                      onChangeEnd: (value) {
                        setState(() => _dragging = null);
                        widget.onChanged(widget.steps[value.round()].$1);
                      },
                    ),
                  ),
                  Text(widget.steps.last.$2, style: ends),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FreeUpSpaceRow extends StatelessWidget {
  const _FreeUpSpaceRow({required this.bytes});

  final int bytes;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.cleaning_services_outlined),
    title: const Text('Free up space'),
    trailing: Text(
      bytes > 0 ? formatBytes(bytes) : '',
      style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
    ),
    onTap: () => unawaited(showOfflineCleanupSheet(context)),
  );
}

/// Whether the mirror may download at all. A switch, worded so that on means on.
class _DownloadingSwitch extends StatelessWidget {
  const _DownloadingSwitch({required this.status, required this.service});

  final OfflineStatus status;
  final OfflineSyncService service;

  @override
  Widget build(BuildContext context) {
    final paused = status.isPaused;
    final waiting = status.missing;
    return SwitchListTile.adaptive(
      secondary: const Icon(Icons.cloud_download_outlined),
      title: const Text('Download offline copies'),
      subtitle: Text(
        paused
            ? (waiting > 0 ? 'Off · $waiting files still to fetch' : 'Off · nothing waiting')
            : 'What you selected is fetched while the app is open, and kept up to date',
      ),
      value: !paused,
      onChanged: (value) => unawaited(service.setPaused(!value)),
    );
  }
}

/// An estimate to two significant digits, so it does not look more precise than it is: 4.2 GiB, 42 GiB.
String _roughBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value < 10 && unit > 0 ? 1 : 0)} ${units[unit]}';
}

/// How the mirror is doing, in one paragraph: what opens offline, what it costs, what is coming, and what is in the
/// way.
class _Summary extends ConsumerWidget {
  const _Summary({required this.status});

  final OfflineStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issue = ref.watch(sessionIssueProvider);
    final storage = ref.watch(offlineStorageProvider).valueOrNull ?? OfflineStorage.empty;

    final available = storage.availableAssets;
    final String headline;
    if (status.fetchable > 0 && status.missing > 0) {
      headline = '${status.held} of ${status.fetchable} files downloaded';
    } else if (available > 0) {
      headline = '$available ${available == 1 ? 'item' : 'items'} available offline';
    } else if (storage.bytes > 0) {
      headline = 'Nothing opens offline yet';
    } else {
      headline = 'Nothing stored offline yet';
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: context.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: '${formatBytes(storage.bytes)} used'),
                if (status.missing > 0 && status.remainingBytes > 0)
                  TextSpan(
                    text: status.remainingIsExact
                        ? ' · ${formatBytes(status.remainingBytes)} left'
                        : ' · estimated ${_roughBytes(status.remainingBytes)} left',
                  ),
                // Paused is the user's own choice; it is only highlighted when work is waiting on it.
                if (status.isPaused)
                  TextSpan(
                    text: ' · paused',
                    style: status.missing > 0
                        ? TextStyle(color: context.colorScheme.error, fontWeight: FontWeight.w600)
                        : null,
                  ),
                if (!status.isPaused && status.isOverLimit)
                  TextSpan(
                    text: ' · storage full',
                    style: TextStyle(color: context.colorScheme.error, fontWeight: FontWeight.w600),
                  ),
                // Only what is running is called downloading; planned files are named separately.
                if (!status.isPaused && !status.isOverLimit) ...[
                  if (status.queued > 0) TextSpan(text: ' · ${status.queued} downloading'),
                  if (status.queued == 0 && status.pending > 0)
                    TextSpan(
                      text:
                          ' · ${status.pending} waiting'
                          '${status.waitingBecause == null ? '' : ' (${status.waitingBecause})'}',
                    ),
                ],
                if (status.failed > 0) TextSpan(text: ' · ${status.failed} failed'),
                if (status.unavailable > 0) TextSpan(text: ' · ${status.unavailable} can\'t be downloaded'),
              ],
            ),
            style: context.textTheme.bodySmall,
          ),
          // Otherwise a contradiction: photos on the device, every selection off.
          if (status.wantedAssets == 0 && storage.bytes > 0) ...[
            const SizedBox(height: 4),
            Text(
              'Nothing selected — all of it can be freed.',
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ],
          if (status.fetchable > 0) ...[const SizedBox(height: 12), LinearProgressIndicator(value: status.fraction)],
          // Named, or the total falls short with no explanation. Not failures.
          if (status.unavailable > 0) ...[
            const SizedBox(height: 8),
            Text(
              '${status.unavailable} files cannot be downloaded: their items are in the trash or the locked folder, or '
              'are hidden — like the video half of a Live Photo, which the server keeps but never renders. They download '
              'again if that changes.',
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ],
          // Its own state, not a pause: nobody asked for it, and it clears itself.
          if (status.isOverLimit && !status.isPaused) ...[
            const SizedBox(height: 8),
            Text(
              'Downloading has stopped: your offline library fills the storage limit, or the phone is nearly full. '
              'Free up space, or raise the limit under Storage below.',
              style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
            ),
            // The only stopped state this screen can fix, so it is a control.
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => unawaited(showOfflineCleanupSheet(context)),
                icon: const Icon(Icons.cleaning_services_outlined, size: 18),
                label: const Text('Free up space'),
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              ),
            ),
          ],
          if (issue != null) ...[const SizedBox(height: 12), _SessionNote(issue: issue)],
          if (status.failed > 0) ...[
            const SizedBox(height: 8),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    '${status.failed} files failed and are no longer being retried.',
                    style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(ref.read(offlineSyncServiceProvider).retryFailed()),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Try again'),
                ),
              ],
            ),
          ],
          if (status.refusedReclaim > 0) ...[
            const SizedBox(height: 8),
            Row(
              spacing: 8,
              children: [
                Expanded(
                  child: Text(
                    '${status.refusedReclaim} files appear unused, too many to delete without asking, so they were kept.',
                    style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
                  ),
                ),
                TextButton(
                  onPressed: () => unawaited(confirmRefusedReclaim(context, ref, status.refusedReclaim)),
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  child: const Text('Review'),
                ),
              ],
            ),
          ],
          if (status.lastError != null) ...[
            const SizedBox(height: 8),
            Text(status.lastError!, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Why nothing is downloading, when the session is the reason. Only an expired session is a control: it opens the login
/// screen, logging nobody out (R2).
class _SessionNote extends StatelessWidget {
  const _SessionNote({required this.issue});

  final SessionIssue issue;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (issue) {
      SessionIssue.offline => (Icons.wifi_off_rounded, 'No network. Downloads will resume.'),
      SessionIssue.unreachable => (Icons.cloud_off_rounded, 'Server unreachable. Downloads will resume.'),
      SessionIssue.expired => (Icons.login_rounded, 'Signed out on the server. Sign in to resume downloading.'),
      SessionIssue.failed => (Icons.error_outline_rounded, 'Could not start syncing on this device. Restart the app.'),
    };
    final expired = issue == SessionIssue.expired;
    final color = expired ? context.colorScheme.error : context.colorScheme.onSurfaceVariant;

    final row = Row(
      spacing: 8,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        Expanded(
          child: Text(
            text,
            style: context.textTheme.bodySmall?.copyWith(color: color, fontWeight: expired ? FontWeight.w600 : null),
          ),
        ),
        if (expired) Icon(Icons.chevron_right_rounded, size: 16, color: color),
      ],
    );

    if (!expired) {
      return row;
    }
    return InkWell(
      onTap: () => unawaited(context.pushRoute(const LoginRoute())),
      borderRadius: const BorderRadius.all(Radius.circular(6)),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: row),
    );
  }
}
