/// immich-sync fork: what the app keeps available offline. A selection says what the app maintains; it never deletes.
library;

import 'dart:convert';

import 'package:logging/logging.dart';

/// How much of an asset to keep. The codes are stored in `wanted` and compared with `MAX` and `>=`, so they follow the
/// ladder order. [thumbnail] was added under [preview] later (see `_rungsRenumberedKey`).
enum OfflineQuality {
  none(0),
  thumbnail(1),
  preview(2),
  full(3),
  fullWithVideos(4);

  const OfflineQuality(this.code);

  final int code;

  bool get isWanted => this != OfflineQuality.none;

  /// Whether the preview is kept. Every rung keeps the thumbnail; the lowest keeps nothing else.
  bool get keepsPreview => code >= OfflineQuality.preview.code;

  bool get keepsOriginal => code >= OfflineQuality.full.code;

  OfflineVideoTier get videoTier =>
      code >= OfflineQuality.fullWithVideos.code ? OfflineVideoTier.playback : OfflineVideoTier.none;

  /// The least an item at this rung must show offline to count as available: the preview, or at [thumbnail] the
  /// thumbnail.
  OfflineAvailability get availableAt => keepsPreview
      ? OfflineAvailability.preview
      : (isWanted ? OfflineAvailability.thumbnail : OfflineAvailability.none);

  static OfflineQuality fromCode(int code) =>
      OfflineQuality.values.where((quality) => quality.code == code).firstOrNull ?? OfflineQuality.none;

  static OfflineQuality? fromName(String? name) =>
      OfflineQuality.values.where((quality) => quality.name == name).firstOrNull;

  OfflineQuality atLeast(OfflineQuality other) => code >= other.code ? this : other;
}

enum OfflineVideoTier { none, playback }

/// What *Save offline* asks for: the whole item. Kept apart from the `wanted` rung, which says what the selection
/// maintains.
const OfflineQuality kOfflineErrandQuality = OfflineQuality.fullWithVideos;

/// What an asset can show with no network.
enum OfflineAvailability {
  none,

  /// The thumbnail: the item draws in the grid and opens as that small picture.
  thumbnail,

  /// Opens as a picture: a photo without its original, or a video's still.
  preview,

  full;

  /// Whether this is at least [other], in the enum's order, which is the order of what can be shown.
  bool covers(OfflineAvailability other) => index >= other.index;
}

/// What an album contributes. Mirrors `BackupSelection`.
enum OfflineAlbumState {
  /// Contributes nothing. Something else may still select these items.
  notIncluded,

  included,

  /// Never selected, whatever else names them, which makes "everything except Screenshots" possible. Removes nothing:
  /// earlier copies stay as spares until the user frees space.
  excluded,
}

class OfflinePolicy {
  const OfflinePolicy({this.library, this.albums = const {}, this.excluded = const {}});

  final OfflineQuality? library;

  final Map<String, OfflineQuality> albums;

  /// Albums whose items nothing selects. Checked before [albums] and [library].
  final Set<String> excluded;

  static const empty = OfflinePolicy();

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
