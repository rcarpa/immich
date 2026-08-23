/// immich-sync fork — choosing which albums are kept offline, on a screen of its own (FORK.md §3.6).
///
/// Split out of the offline copies screen, and shaped after upstream's own album picker
/// (`backup_album_selection.page.dart`) so the two read as the same app: the same place for the title, the same
/// search in the app bar, the same marks and tints down the list. The question is a different one — those are albums on
/// this device chosen for upload, these are albums on the server chosen for download — so what differs is only what
/// each row offers: four rungs and an exclusion rather than a checkbox.
///
/// It has a screen to itself because the alternative crowded the one control the other screen exists for. A library can
/// have hundreds of albums and every selected one is drawn; *Storage*, which sits after them, was that far down the
/// page. §3.6 already says a pause found past a hundred album rows is not a pause, and the same is true of the button
/// that frees space.
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
  /// How many albums with no setting of their own are shown before the list has to be asked for. The ones that *have*
  /// a setting are always shown: they are what the screen was opened to check.
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

    // Builders rather than widgets: the sliver below builds only what is on screen, and a list of already-built rows
    // would give that up.
    final items = <WidgetBuilder>[
      for (final album in chosen) (_) => _AlbumRow(album: album, total: counts[album.id] ?? 0),
      // Chosen albums are kept at the top rather than summarised in chips as upstream does: the summary exists there
      // because that list is in album order, and a list that puts them first has already answered the same question.
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

/// What an album's own setting does, which is the one thing that cannot be read off a row.
///
/// The ladder only ever goes up: an item is kept at the most generous setting naming it, so an album asking for less
/// than the library does is recorded and then overruled — and says so on its own row. Exclusion is the exception that
/// makes "everything except this" expressible at all, and it beats every other setting.
///
/// What it beats them at is *fetching*, and the wording has to be that careful. Excluding an album does not delete
/// anything by itself: copies an earlier setting already fetched stay, as spares, until *Free up space* or eviction
/// takes them (FORK.md §3.4.1) — and the same row offers to free them, so a line above it promising they are "never
/// kept" is contradicted a centimetre lower.
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
      // The one list long enough to need reading at a glance, and the one whose rows are otherwise identical until
      // the trailing label on each is read.
      showState: true,
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OfflineAlbumUplift(albumId: album.id),
          OfflineAlbumExcluded(albumId: album.id),
          OfflineAlbumSpares(albumId: album.id),
        ],
      ),
      // The change, not a rebuilt policy: `policy` is a frame old, and a tap on
      // another row in between would be overwritten by what it produced.
      onSelected: (choice) => unawaited(
        ref.read(offlineSyncServiceProvider).applyPolicy((current) => offlineAlbumPolicy(current, album.id, choice)),
      ),
    );
  }
}
