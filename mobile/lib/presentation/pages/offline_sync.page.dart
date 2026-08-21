/// immich-sync fork — the one screen for what stays available offline (FORK.md §3.6). Three sections: *Downloading* —
/// status and its two controls, first because it is what the screen is opened to check — then *What to keep offline*,
/// then *Storage*, which reports what those selections cost.
library;

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/offline/offline.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/offline_sync.service.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_album_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_cleanup_sheet.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_reclaim_dialog.dart';
import 'package:immich_mobile/presentation/widgets/offline/quality_menu.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/providers/session_state.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';

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
    // opening a screen is not the user asking to spend their data.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(remoteAlbumProvider.notifier).refresh());
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
              SwitchListTile.adaptive(
                secondary: const Icon(Icons.wifi),
                title: const Text('Wi-Fi only'),
                subtitle: const Text('Downloads wait until you are on Wi-Fi'),
                value: wifiOnly,
                onChanged: (value) => unawaited(_setWifiOnly(value)),
              ),
              _PauseRow(status: status, service: service),

              const Divider(height: 1),
              const _SectionTitle('Persistent offline library'),
              const _Explainer(),
              // No icon: the album rows below have none, and one row wearing an icon the rest do not reads as a
              // different kind of thing rather than as the setting they all fall back to.
              OfflineSelectionRow(
                title: 'Entire library',
                subtitle: 'Everything on the server, now and later',
                value: OfflineChoice.ofQuality(policy.library),
                labels: kOfflineLibraryChoices,
                onSelected: (choice) =>
                    unawaited(service.applyPolicy((current) => current.withLibrary(choice.quality))),
              ),
              // The line and the label keep "Entire library" from reading as the name of an album: above it is the
              // setting everything falls back to, below it are the albums that may override it.
              const Divider(height: 24, indent: 16, endIndent: 16),
              const _ListLabel('Albums'),
            ],
          ),
          const _AlbumList(),
          SliverList.list(
            children: const [
              Divider(height: 1),
              _SectionTitle('Storage'),
              _StorageOverview(),
              SizedBox(height: 8),
            ],
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
    // left to download over cellular after the switch says not to.
    if (!service.current.isPaused) {
      await service.setPaused(true);
      await service.setPaused(false);
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

/// A quieter heading than [_SectionTitle], for a list inside a section.
class _ListLabel extends StatelessWidget {
  const _ListLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
    child: Text(text, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant)),
  );
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
            ? 'What you choose is downloaded and kept up to date with new arrivals. Turning a row '
                  'off stops new downloads, but does not delete existing ones.'
            : 'You have not chosen anything to keep offline yet. Nothing new will be downloaded.',
        style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
      ),
    );
  }
}

// ----------------------------------------------------------------------------- Storage

/// Seven colours, fixed: three for the offline library, three for the same kinds once nothing asks for them any more,
/// and one for the cache.
class _Palette {
  const _Palette({
    required this.libraryVideo,
    required this.libraryOriginal,
    required this.libraryPreview,
    required this.freeVideo,
    required this.freeOriginal,
    required this.freePreview,
  });

  factory _Palette.of(BuildContext context) => _Palette(
    libraryVideo: context.colorScheme.primary,
    libraryOriginal: context.colorScheme.primary.withValues(alpha: 0.72),
    libraryPreview: context.colorScheme.primary.withValues(alpha: 0.45),
    freeVideo: context.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
    freeOriginal: context.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
    freePreview: context.colorScheme.onSurfaceVariant.withValues(alpha: 0.32),
  );

  final Color libraryVideo;
  final Color libraryOriginal;
  final Color libraryPreview;
  final Color freeVideo;
  final Color freeOriginal;
  final Color freePreview;
}

/// The three kinds of file the store is made of.
const _videosLabel = 'Videos';
const _originalsLabel = 'Full-size photos';
const _previewsLabel = 'Previews & thumbnails';

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
        subtitle: Text('Selected items appear as they download'),
      );
    }

    final palette = _Palette.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SubSection(title: 'Persistent library', bytes: storage.libraryBytes + storage.spareBytes),
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
                'Spares are copies you saved by hand, and copies a changed selection left behind.',
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
        const _StorageLimitRow(),
        // The only way to remove anything, and a screen of its own: what is above this row reports, and reporting must
        // not be one mistap from deleting.
        _FreeUpSpaceRow(bytes: storage.spareBytes),

        // The opportunistic region gets its own heading rather than a row in the table above.
        const Divider(height: 24, indent: 16, endIndent: 16),
        _SubSection(title: 'Cache', bytes: storage.browsingBytes),
        const _CacheBudgetRow(),
        _ClearCacheRow(bytes: storage.browsingBytes),
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
      (palette.freeVideo, storage.spareVideoBytes),
      (palette.freeOriginal, storage.spareOriginalBytes),
      (palette.freePreview, storage.sparePreviewBytes),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
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
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
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

  /// Absent for the cache, which no selection maintains, so its half of the row is a dash rather than a zero it could
  /// be mistaken for.
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

/// The opportunistic region: not part of the library, and emptied rather than freed, so it has no first figure and its
/// own verb.
class _StorageLine extends StatelessWidget {
  const _StorageLine({required this.title, required this.first, required this.second});

  final String title;

  /// Null where the row has no library half — the cache, which no selection maintains. A dash rather than `0 B`, which
  /// would read as "none yet".
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

class _CacheBudgetRow extends ConsumerWidget {
  const _CacheBudgetRow();

  /// Ends at Off, because zero bytes is where the axis starts.
  static const _steps = <(int, String)>[
    (0, 'Off'),
    (128 * 1024 * 1024, '128 MB'),
    (256 * 1024 * 1024, '256 MB'),
    (512 * 1024 * 1024, '512 MB'),
    (1024 * 1024 * 1024, '1 GB'),
    (2 * 1024 * 1024 * 1024, '2 GB'),
    (4 * 1024 * 1024 * 1024, '4 GB'),
    (8 * 1024 * 1024 * 1024, '8 GB'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) => _SizeSliderRow(
    title: 'Cache limit',
    subtitle: 'Dynamically used for temporary photos as you navigate',
    steps: _steps,
    value: ref.watch(appConfigProvider.select((config) => config.offlineCacheBudget)),
    onChanged: (value) => unawaited(ref.read(offlineSyncServiceProvider).setCacheBudget(value)),
  );
}

/// The ceiling on the mirror. It pauses downloading and never deletes: evicting the library to stay under a number
/// would be exactly the automatic removal this screen promises does not happen.
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
    title: 'Persistent library limit',
    subtitle: 'Offline copies stop downloading at this limit',
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
          borderRadius: BorderRadius.circular(12),
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

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
    child: Text(text, style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant)),
  );
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

/// Emptying the cache, under the limit that governs it.
class _ClearCacheRow extends ConsumerWidget {
  const _ClearCacheRow({required this.bytes});

  final int bytes;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ListTile(
    dense: true,
    contentPadding: const EdgeInsets.only(left: 16, right: 24),
    title: Text('Clear cache now', style: context.textTheme.bodyMedium),
    trailing: Text(
      formatBytes(bytes),
      style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
    ),
    enabled: bytes > 0,
    onTap: bytes <= 0 ? null : () => unawaited(confirmClearCache(context, ref, bytes)),
  );
}

class _PauseRow extends StatelessWidget {
  const _PauseRow({required this.status, required this.service});

  final OfflineStatus status;
  final OfflineSyncService service;

  @override
  Widget build(BuildContext context) {
    final paused = status.isPaused;
    return ListTile(
      leading: Icon(paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
      title: Text(paused ? 'Resume downloading' : 'Pause downloading'),
      subtitle: Text(
        paused
            ? (status.missing > 0 ? '${status.missing} files still to fetch' : 'Nothing waiting')
            : 'Stops until you resume',
      ),
      onTap: () => unawaited(service.setPaused(!paused)),
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
                    text: ' · persistent limit reached',
                    style: TextStyle(color: context.colorScheme.error, fontWeight: FontWeight.w600),
                  ),
                // Only while something is actually being fetched: paused or at the limit, the queue still holds what
                // the last pass planned, and calling that "downloading" contradicts the word beside it.
                if (!status.isPaused && !status.isOverLimit && status.queued > 0)
                  TextSpan(text: ' · ${status.queued} downloading'),
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
          if (status.fetchable > 0) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(value: status.fraction),
          ],
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
              'Downloading has stopped: the persistent library is at its limit. Free up space, or raise '
              'the limit under Storage below.',
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
          if (issue != null) ...[
            const SizedBox(height: 12),
            _SessionNote(issue: issue),
          ],
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
class _SessionNote extends ConsumerWidget {
  const _SessionNote({required this.issue});

  final SessionIssue issue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
            style: context.textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: expired ? FontWeight.w600 : null,
            ),
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
      borderRadius: BorderRadius.circular(6),
      child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: row),
    );
  }
}

/// The albums, with the ones that are selected kept in view and the rest out of the way.
class _AlbumList extends ConsumerStatefulWidget {
  const _AlbumList();

  @override
  ConsumerState<_AlbumList> createState() => _AlbumListState();
}

class _AlbumListState extends ConsumerState<_AlbumList> {
  /// How many unselected albums are shown before the list has to be asked for, and the number above which searching is
  /// offered at all: a handful of rows is quicker to read than to search.
  static const _collapsed = 8;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  var _query = '';
  var _expanded = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final albums = ref.watch(remoteAlbumProvider.select((state) => state.albums));
    final counts = ref.watch(offlineAlbumCountsProvider).valueOrNull ?? const {};
    final policy = ref.watch(offlinePolicyProvider);

    if (albums.isEmpty) {
      return const SliverToBoxAdapter(child: _Note('No albums yet.'));
    }

    final query = _query.toLowerCase();
    final selected = <RemoteAlbum>[];
    final rest = <RemoteAlbum>[];
    for (final album in albums) {
      if (query.isNotEmpty && !album.name.toLowerCase().contains(query)) {
        continue;
      }
      (policy.stateOf(album.id) == OfflineAlbumState.notIncluded ? rest : selected).add(album);
    }

    final hasMore = rest.length > _collapsed;
    final capped = query.isEmpty && !_expanded && hasMore;
    final shown = capped ? rest.take(_collapsed) : rest;

    final WidgetBuilder? footer;
    if (selected.isEmpty && shown.isEmpty) {
      footer = (_) => _Note('No album matches "$_query".');
    } else if (capped) {
      footer = (_) => _more('Show all ${albums.length} albums', expanded: true);
    } else if (_expanded && hasMore && query.isEmpty) {
      footer = (_) => _more('Show fewer', expanded: false);
    } else {
      footer = null;
    }

    // Builders rather than widgets: the sliver below builds only what is on
    // screen, and a list of already-built rows would give that up.
    final items = <WidgetBuilder>[
      if (albums.length > _collapsed) _searchField,
      for (final album in selected) (_) => _AlbumRow(album: album, total: counts[album.id] ?? 0),
      if (selected.isNotEmpty && shown.isNotEmpty) (_) => const Divider(height: 24, indent: 16, endIndent: 16),
      for (final album in shown) (_) => _AlbumRow(album: album, total: counts[album.id] ?? 0),
      ?footer,
    ];

    return SliverList.builder(itemCount: items.length, itemBuilder: (context, index) => items[index](context));
  }

  Widget _searchField(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
    child: SearchField(
      controller: _controller,
      focusNode: _focusNode,
      hintText: 'Search albums',
      filled: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      prefixIcon: const Icon(Icons.search, size: 20),
      suffixIcon: _query.isEmpty
          ? null
          : IconButton(icon: const Icon(Icons.close, size: 20), onPressed: _clearQuery),
      onChanged: (value) => setState(() => _query = value.trim()),
    ),
  );

  Widget _more(String label, {required bool expanded}) => Center(
    child: TextButton(onPressed: () => setState(() => _expanded = expanded), child: Text(label)),
  );

  void _clearQuery() {
    _controller.clear();
    _focusNode.unfocus();
    setState(() => _query = '');
  }
}

class _AlbumRow extends ConsumerWidget {
  const _AlbumRow({required this.album, required this.total});

  final RemoteAlbum album;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(offlinePolicyProvider);
    return OfflineSelectionRow(
      title: album.name,
      subtitle: offlineAlbumSubtitle(ref, album.id, policy, total: total),
      value: offlineChoiceOfAlbum(policy, album.id),
      labels: offlineAlbumChoices(policy, album.id),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OfflineAlbumUplift(albumId: album.id, total: total),
          OfflineAlbumSpares(albumId: album.id),
        ],
      ),
      // The change, not a rebuilt policy: `policy` is a frame old, and a tap on
      // another row in between would be overwritten by what it produced.
      onSelected: (choice) => unawaited(
        ref
            .read(offlineSyncServiceProvider)
            .applyPolicy((current) => offlineAlbumPolicy(current, album.id, choice)),
      ),
    );
  }
}
