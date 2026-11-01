/// immich-sync fork: which albums are kept offline. Shaped after upstream's `backup_album_selection.page.dart`, with
/// rungs and an exclusion instead of a checkbox.
library;

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/offline/offline_policy.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/presentation/widgets/offline/offline_album_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/offline/quality_menu.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/offline.provider.dart';
import 'package:immich_mobile/widgets/common/search_field.dart';

@RoutePage()
class OfflineAlbumsPage extends ConsumerStatefulWidget {
  const OfflineAlbumsPage({super.key});

  @override
  ConsumerState<OfflineAlbumsPage> createState() => _OfflineAlbumsPageState();
}

class _OfflineAlbumsPageState extends ConsumerState<OfflineAlbumsPage> {
  /// How many albums without a setting of their own are shown before "show all". Albums with one are always shown.
  static const _collapsed = 8;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  var _query = '';
  var _searching = false;
  var _expanded = false;

  @override
  void initState() {
    super.initState();
    // The album list is this screen's subject, so it is refreshed on the way in rather than by the screen behind it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(ref.read(remoteAlbumProvider.notifier).refresh());
    });
  }

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

    final query = _query.toLowerCase();
    final chosen = <RemoteAlbum>[];
    final rest = <RemoteAlbum>[];
    for (final album in albums) {
      if (query.isNotEmpty && !album.name.toLowerCase().contains(query)) {
        continue;
      }
      (policy.stateOf(album.id) == OfflineAlbumState.notIncluded ? rest : chosen).add(album);
    }

    final hasMore = rest.length > _collapsed;
    final capped = query.isEmpty && !_expanded && hasMore;
    final shown = capped ? rest.take(_collapsed) : rest;

    final WidgetBuilder? footer;
    if (chosen.isEmpty && shown.isEmpty) {
      footer = (_) => _Note(query.isEmpty ? 'No albums yet.' : 'No album matches "$_query".');
    } else if (capped) {
      footer = (_) => _more('Show all ${albums.length} albums', expanded: true);
    } else if (_expanded && hasMore && query.isEmpty) {
      footer = (_) => _more('Show fewer', expanded: false);
    } else {
      footer = null;
    }

    // Builders, so the sliver only builds what is on screen.
    final items = <WidgetBuilder>[
      for (final album in chosen) (_) => _AlbumRow(album: album, total: counts[album.id] ?? 0),
      // Chosen albums are listed first, so no summary chips are needed.
      if (chosen.isNotEmpty && shown.isNotEmpty) (_) => const Divider(height: 24, indent: 16, endIndent: 16),
      for (final album in shown) (_) => _AlbumRow(album: album, total: counts[album.id] ?? 0),
      ?footer,
    ];

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? SearchField(
                hintText: 'Search albums',
                autofocus: true,
                controller: _controller,
                focusNode: _focusNode,
                onChanged: (value) => setState(() => _query = value.trim()),
              )
            : const Text('Albums to keep offline'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              _query = '';
              _controller.clear();
            }),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _Explainer(total: albums.length)),
          SliverList.builder(itemCount: items.length, itemBuilder: (context, index) => items[index](context)),
          const SliverToBoxAdapter(child: SizedBox(height: 8)),
        ],
      ),
    );
  }

  Widget _more(String label, {required bool expanded}) => Center(
    child: TextButton(onPressed: () => setState(() => _expanded = expanded), child: Text(label)),
  );
}

/// What an album's own setting does. An item is kept at the most generous setting naming it, so an album asking for
/// less than the library is overruled. Excluding beats everything, but deletes nothing: earlier copies stay as spares
/// until freed.
class _Explainer extends StatelessWidget {
  const _Explainer({required this.total});

  final int total;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 6,
      children: [
        Text(
          'An album can only raise quality: photos are kept at the most generous setting that names them. '
          'Excluding an album is the exception — those photos are never downloaded, whatever else selects them. '
          'Copies an album no longer asks for stay on this device as spares, until space runs out or you free it up.',
          style: context.textTheme.bodyMedium?.copyWith(color: context.colorScheme.onSurfaceVariant),
        ),
        Text(total == 1 ? '1 album on the server' : '$total albums on the server', style: context.textTheme.titleSmall),
      ],
    ),
  );
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

class _AlbumRow extends ConsumerWidget {
  const _AlbumRow({required this.album, required this.total});

  final RemoteAlbum album;
  final int total;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(offlinePolicyProvider);
    return OfflineSelectionRow(
      title: album.name,
      subtitle: offlineAlbumSubtitle(ref, album.id, policy, total: total, stateShown: true),
      value: offlineChoiceOfAlbum(policy, album.id),
      labels: offlineAlbumChoices(policy, album.id),
      showState: true,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OfflineAlbumUplift(albumId: album.id),
          OfflineAlbumExcluded(albumId: album.id),
          OfflineAlbumSpares(albumId: album.id),
        ],
      ),
      // The change, not a rebuilt policy, which may be a frame old.
      onSelected: (choice) => unawaited(
        ref.read(offlineSyncServiceProvider).applyPolicy((current) => offlineAlbumPolicy(current, album.id, choice)),
      ),
    );
  }
}
