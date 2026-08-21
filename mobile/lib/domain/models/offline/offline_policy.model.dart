/// immich-sync fork — what the app keeps available offline. Selecting and storing are separate: a selection says what
/// the app *maintains*.
library;

import 'dart:convert';

import 'package:logging/logging.dart';

/// How much of an asset to keep.
enum OfflineQuality {
  none(0),
  preview(1),
  full(2),
  fullWithVideos(3);

  const OfflineQuality(this.code);

  final int code;

  bool get isWanted => this != OfflineQuality.none;

  /// Whether an image's original is kept, beyond the thumbnail and preview every kept item gets.
  bool get keepsOriginal => code >= OfflineQuality.full.code;

  /// Which video file is kept.
  OfflineVideoTier get videoTier =>
      code >= OfflineQuality.fullWithVideos.code ? OfflineVideoTier.playback : OfflineVideoTier.none;

  static OfflineQuality fromCode(int code) => switch (code) {
    3 => OfflineQuality.fullWithVideos,
    2 => OfflineQuality.full,
    1 => OfflineQuality.preview,
    _ => OfflineQuality.none,
  };

  static OfflineQuality? fromName(String? name) =>
      OfflineQuality.values.where((quality) => quality.name == name).firstOrNull;

  OfflineQuality atLeast(OfflineQuality other) => code >= other.code ? this : other;
}

/// Which video file a rung asks for.
enum OfflineVideoTier { none, playback }

/// What an errand asks for: the whole item, whatever the ladder says (FORK.md §3.6).
///
/// One definition, because three places have to agree on it and none of them can read it off the `wanted` row — that
/// column means what the *selection* maintains, which is a different question (§3.2). `filesFor` fetches to this rung
/// for a marked item, `OfflineIndex.barOf` draws a track to it, and `fetchForOffline` records it as the rung only when
/// nothing else selects the item at all.
const OfflineQuality kOfflineErrandQuality = OfflineQuality.fullWithVideos;

/// What an asset can show with no network.
enum OfflineAvailability {
  /// Nothing usable off-grid.
  none,

  /// Opens as a picture — a photo without its original, or a video's still, which is what a video kept below the top
  /// rung has.
  preview,

  /// Everything this asset has: a photo's original, a video's playable file.
  full;

  bool get isAvailable => this != OfflineAvailability.none;
}

/// What an album contributes. Mirrors `BackupSelection`.
enum OfflineAlbumState {
  /// Contributes nothing. Something else may still select these items.
  notIncluded,

  /// Selects the album, at a quality.
  included,

  /// These are never kept, whatever else selects them. This is what makes "everything except Screenshots" expressible —
  /// a plain union could not.
  excluded,
}

class OfflinePolicy {
  const OfflinePolicy({this.library, this.albums = const {}, this.excluded = const {}});

  /// Quality for the whole library, or null when the library is not selected.
  final OfflineQuality? library;

  /// Included albums and the quality each is kept at.
  final Map<String, OfflineQuality> albums;

  /// Albums whose items are never kept. Checked before [albums] and [library].
  final Set<String> excluded;

  static const empty = OfflinePolicy();

  /// Whether anything is selected at all.
  bool get selectsAnything => (library?.isWanted ?? false) || albums.values.any((quality) => quality.isWanted);

  OfflineAlbumState stateOf(String albumId) {
    if (excluded.contains(albumId)) {
      return OfflineAlbumState.excluded;
    }
    return albums.containsKey(albumId) ? OfflineAlbumState.included : OfflineAlbumState.notIncluded;
  }

  /// The quality an item is selected at, or null if nothing selects it.
  OfflineQuality? resolve(Iterable<String> albumIds) {
    OfflineQuality? best;
    for (final id in albumIds) {
      if (excluded.contains(id)) {
        return null;
      }
      final album = albums[id];
      if (album != null) {
        best = best?.atLeast(album) ?? album;
      }
    }
    return best == null ? library : (library == null ? best : best.atLeast(library!));
  }

  OfflinePolicy withLibrary(OfflineQuality? quality) =>
      OfflinePolicy(library: quality, albums: albums, excluded: excluded);

  OfflinePolicy withAlbum(String albumId, OfflineAlbumState state, {OfflineQuality? quality}) {
    final nextAlbums = Map<String, OfflineQuality>.from(albums)..remove(albumId);
    final nextExcluded = Set<String>.from(excluded)..remove(albumId);
    switch (state) {
      case OfflineAlbumState.included:
        nextAlbums[albumId] = quality ?? OfflineQuality.full;
      case OfflineAlbumState.excluded:
        nextExcluded.add(albumId);
      case OfflineAlbumState.notIncluded:
        break;
    }
    return OfflinePolicy(library: library, albums: nextAlbums, excluded: nextExcluded);
  }

  String encode() => jsonEncode({
    if (library != null) 'library': library!.name,
    'albums': {for (final entry in albums.entries) entry.key: entry.value.name},
    'excluded': excluded.toList(),
  });

  /// Never throws: a malformed value degrades to "select nothing" rather than blocking startup.
  static OfflinePolicy decode(String? raw) {
    if (raw == null || raw.isEmpty) {
      return empty;
    }
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final albums = <String, OfflineQuality>{};
      for (final entry in (json['albums'] as Map<String, dynamic>? ?? const {}).entries) {
        final quality = OfflineQuality.fromName(entry.value as String?);
        if (quality != null && quality.isWanted) {
          albums[entry.key] = quality;
        }
      }
      return OfflinePolicy(
        library: OfflineQuality.fromName(json['library'] as String?),
        albums: albums,
        excluded: {for (final id in (json['excluded'] as List<dynamic>? ?? const [])) id as String},
      );
    } catch (error, stackTrace) {
      Logger('OfflinePolicy').severe('Could not read the offline selection; nothing is selected', error, stackTrace);
      return empty;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is OfflinePolicy &&
      other.library == library &&
      other.albums.length == albums.length &&
      other.albums.entries.every((entry) => albums[entry.key] == entry.value) &&
      other.excluded.length == excluded.length &&
      other.excluded.every(excluded.contains);

  @override
  int get hashCode => Object.hash(library, albums.length, excluded.length);
}
