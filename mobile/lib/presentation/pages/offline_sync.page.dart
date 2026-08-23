/// immich-sync fork — what stays available offline (FORK.md §3.6). Three sections: *Downloading* — status and its two
/// controls, first because it is what the screen is opened to check — then *What to keep offline*, then *Storage*,
/// which reports what those selections cost.
///
/// The albums themselves are one screen further in (`offline_albums.page.dart`). Here they are a row and a count: every
/// album with a setting of its own is drawn, so a library with forty of them left *Storage* forty rows past the fold,
/// which is the thing this section order exists to prevent.
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
    // Refresh the figures and look for anything missing, without downloading:
    // opening a screen is not the user asking to spend their data. The album
    // list refreshes itself on the screen that shows it.
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
      // Slivers rather than one list of children: a library can have hundreds of albums, and a column of them is built
      // in full on every frame whether or not any of it is on screen.
      body: CustomScrollView(
        slivers: [
          SliverList.list(
            children: [
              const _SectionTitle('Downloading'),
              _Summary(status: status),
              // The standing decision first, then what qualifies it: Wi-Fi only says nothing at all while the switch
              // above it is off.
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
              // No icon and no state mark: this is the setting everything falls back to rather than an entry in a list
              // to be picked out of, and the row under it wears neither either.
              OfflineSelectionRow(
                title: 'Entire library',
                subtitle: 'Everything on the server, now and later',
                value: OfflineChoice.ofQuality(policy.library),
                labels: kOfflineLibraryChoices,
                onSelected: (choice) =>
                    unawaited(service.applyPolicy((current) => current.withLibrary(choice.quality))),
              ),
              // Nothing between the two: the rule and the way to its exceptions are one thought, and the line that used
              // to sit here was keeping "Entire library" from reading as the first name in the list of albums that
              // followed it. That list is a screen of its own now, and a row ending in a chevron cannot be misread as
              // an album.
              const _AlbumsRow(),
            ],
          ),
          SliverList.list(
            children: const [Divider(height: 1), _SectionTitle('Storage'), _StorageOverview(), SizedBox(height: 8)],
          ),
        ],
      ),
    );
  }

  Future<void> _setWifiOnly(bool value) async {
    final settings = ref.read(settingsProvider);
    final service = ref.read(offlineSyncServiceProvider);
    await settings.write(SettingsKey.offlineWifiOnly, value);
    // Queued tasks carry the old constraint, so they are dropped rather than
    // left to download over cellular after the switch says not to. Through
    // `stopDownloads` rather than a pause and a resume: those write the persisted
    // flag twice, and being killed between the two writes left downloading paused
    // with nothing to explain it.
    if (!service.current.isPaused) {
      await service.stopDownloads();
      await service.sync();
    }
  }
}

/// A heading for one half of Storage, carrying what that half holds.
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

/// The way to the albums, and a summary of what they are doing.
///
/// A row rather than the list itself (FORK.md §3.6): every album with a setting of its own is drawn, so a library with
/// forty of them put *Storage* forty rows past the fold — and the section order this screen is built on exists
/// precisely so that the controls are not found past a hundred album rows.
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

// ----------------------------------------------------------------------------- Storage

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

/// The four kinds of file the store is made of. Previews and thumbnails are apart here, though the cleanup sheet takes
/// them as one: at the thumbnail rung the thumbnail is library and the preview a spare, and one row could not say so.
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
              // Said beside the colour that names them: one figure covering two ways a file gets there reads as a
              // mistake until it is spelled out, and neither way is maintained by anything.
              Text(
                'Spares are photos you opened, copies you saved by hand, and copies a changed selection left behind. '
                'When space runs out, the least recently used spares are removed first.',
                style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
              ),
              // Here rather than beside the progress bar: it is a saving, not a failure, and next to downloading it read
              // as a stack of errors. Storage is the section it actually belongs to — it is why the store is smaller
              // than the selection implies.
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
        // One row per kind, always present, whether or not it holds anything: a list whose rows come and go cannot be
        // learned, and `0 B` is an answer.
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
        // The only way to remove anything by hand, and a screen of its own: what is above this row reports, and
        // reporting must not be one mistap from deleting.
        _FreeUpSpaceRow(bytes: storage.spareBytes),
      ],
    );
  }
}

/// The total, split the way the rows beneath it are.
class _StorageBar extends StatelessWidget {
  const _StorageBar({required this.storage, required this.palette});

  final OfflineStorage storage;
  final _Palette palette;

  @override
  Widget build(BuildContext context) {
    // The library and its spares, and not the cache: the bar is what the selections above cost, and a segment nobody
    // chose sitting in it made the rest of it read as a smaller share than it is.
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

/// What the bar's colours mean, said once.
class _Legend extends StatelessWidget {
  const _Legend({required this.palette});

  final _Palette palette;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 14,
    runSpacing: 4,
    children: [
      // The words the columns below are headed with, so the colours and the
      // figures are read as one thing.
      _chip(context, palette.libraryVideo, 'library'),
      _chip(context, palette.freeVideo, 'spares'),
    ],
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

/// One kind of file: what the settings above ask for, what nothing asks for any more, and the button that takes the
/// second away.
class _KindRow extends StatelessWidget {
  const _KindRow({
    required this.title,
    this.libraryBytes,
    this.libraryColor,
    required this.freeBytes,
    required this.freeColor,
  });

  final String title;

  /// Absent for a row no selection could ever maintain, so its half is a dash rather than a zero it could be mistaken
  /// for. Every kind today has both halves.
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

  /// Fixed, so the table keeps its shape as figures reach zero and leave it, which is exactly when someone is looking
  /// at it.
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

  /// Printed in the colour of its own slice of the bar, which is what ties the two together without a third column of
  /// labels.
  Widget _figure(BuildContext context, (String, Color)? value) => Text(
    value == null ? '—' : value.$1,
    textAlign: TextAlign.end,
    style: context.textTheme.labelLarge?.copyWith(color: value?.$2 ?? context.colorScheme.onSurfaceVariant),
  );
}

/// The ceiling on the whole store. Spares are evicted to stay under it, least recently used first; the library never
/// is — once only the library is left, downloading stops instead (FORK.md §3.4.1).
class _StorageLimitRow extends ConsumerWidget {
  const _StorageLimitRow();

  /// No limit sits at the far end, where the axis is heading: each step to the right allows more, and the last one
  /// allows everything.
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

/// A size, chosen by dragging. The slider moves over *steps*, not over bytes: a linear byte axis would spend nine
/// tenths of its travel between 20 and 200 GB and make 256 MB impossible to hit.
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
  /// Where the finger is, while it is down.
  double? _dragging;

  int get _index {
    final exact = widget.steps.indexWhere((step) => step.$1 == widget.value);
    if (exact >= 0) {
      return exact;
    }
    // A value no longer on the ladder — an older build's, or a hand-edited
    // setting: show the nearest step at or above it rather than snapping to zero.
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
        // A block of its own, because a bare slider under a table of figures reads as part of the table: its value
        // landed in the spares column, and the two limits looked like two more rows of storage.
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
                  // What the ends of the axis are, which the slider alone never says.
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

/// The way to any deletion, and a screen of its own (`offline_cleanup_sheet.dart`).
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

/// Whether the mirror may spend bandwidth at all — the standing decision the rest of the section qualifies.
///
/// A switch rather than the button it used to be, because that is what it always was: a persisted preference that
/// survives restarts, not an action. A button whose label flips between *Pause* and *Resume* also has to be read
/// before its own state can be known, while a switch shows the state and the control in one — which is how the
/// Wi-Fi row under it and upstream's backup toggles already work.
///
/// Worded so that on means on. "Pause downloading" as a switch would be an inverted one, where flicking it *on* stops
/// something; the sentence has to be true when the switch is true.
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
      // What is waiting is worth saying while it is off, since nothing else on the screen is moving to imply it. While
      // it is on, the summary above is already counting.
      subtitle: Text(
        paused
            ? (waiting > 0 ? 'Off · $waiting files still to fetch' : 'Off · nothing waiting')
            : 'What you selected is fetched and kept up to date',
      ),
      value: !paused,
      onChanged: (value) => unawaited(service.setPaused(!value)),
    );
  }
}

/// How the mirror is doing, in one paragraph: what opens offline, what it costs, what is still coming, and anything
/// standing in the way.
class _Summary extends ConsumerWidget {
  const _Summary({required this.status});

  final OfflineStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final issue = ref.watch(sessionIssueProvider);
    final storage = ref.watch(offlineStorageProvider).valueOrNull ?? OfflineStorage.empty;

    // What is on the device, not what was asked for: counting only selections
    // would say "nothing kept offline yet" over ten gigabytes that open fine.
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
                // Paused is the user's own doing, so it is stated plainly — until there is work waiting on it, when it
                // becomes the reason nothing is happening and is coloured to say so.
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
                // Only what the downloader actually holds is called downloading. What a pass merely planned is named
                // separately and honestly: for as long as anything stops the hand-over — the limit, a backup in
                // progress, a read-only pass — those files are waiting, not moving, and counting them as in progress is
                // how a queue that had stopped went on presenting itself as busy.
                if (!status.isPaused && !status.isOverLimit) ...[
                  if (status.queued > 0) TextSpan(text: ' · ${status.queued} downloading'),
                  if (status.queued == 0 && status.pending > 0) TextSpan(text: ' · ${status.pending} waiting'),
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
          // Named, or the total is short of the selection by a few files and nothing says why. They are not failures
          // and there is nothing to retry: the items are simply not there to download.
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
            // The way out, as a control rather than as an instruction to go and find one: this is the only stopped
            // state with something to do about it on this screen.
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
          // The one place the fork mentions the session: what is stored keeps
          // working regardless, so this is information, not a demand.
          if (issue != null) ...[const SizedBox(height: 12), _SessionNote(issue: issue)],
          // Files the server would not give us, after several tries. Named and
          // actionable rather than a counter that never reaches zero.
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
          if (status.lastError != null) ...[
            const SizedBox(height: 8),
            Text(status.lastError!, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error)),
          ],
        ],
      ),
    );
  }
}

/// Why nothing is downloading, when the reason is the session rather than the store.
///
/// An expired session is the only one of the three the user can do anything about, so it is the only one that shouts
/// and the only one that is a control: the message told them to sign in while the sole route to the login screen was
/// *Sign out*, which is the opposite of what they want. Nothing here logs anyone out or clears anything (R2) — it opens
/// the login screen, and the stored server address is still there to sign in against.
class _SessionNote extends StatelessWidget {
  const _SessionNote({required this.issue});

  final SessionIssue issue;

  @override
  Widget build(BuildContext context) {
    final (icon, text) = switch (issue) {
      SessionIssue.offline => (Icons.wifi_off_rounded, 'No network. Downloads will resume.'),
      SessionIssue.unreachable => (Icons.cloud_off_rounded, 'Server unreachable. Downloads will resume.'),
      SessionIssue.expired => (Icons.login_rounded, 'Signed out on the server. Sign in to resume downloading.'),
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
