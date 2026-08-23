import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:openapi/api.dart';

/// immich-sync fork: [thumbhash] is a cache buster, as in
/// [getThumbnailUrlForRemoteId] — with `edited=true` this URL resolves to
/// `editedPath ?? originalPath`, so its bytes move. Only `offlineOriginalUrl`
/// passes it.
String getOriginalUrlForRemoteId(final String id, {bool edited = true, String? thumbhash}) {
  final url = '${Store.get(StoreKey.serverEndpoint)}/assets/$id/original?edited=$edited';
  return thumbhash != null ? '$url&c=${Uri.encodeComponent(thumbhash)}' : url;
}

String getThumbnailUrlForRemoteId(
  final String id, {
  AssetMediaSize type = AssetMediaSize.thumbnail,
  bool edited = true,
  String? thumbhash,
}) {
  final url = '${Store.get(StoreKey.serverEndpoint)}/assets/$id/thumbnail?size=$type&edited=$edited';
  return thumbhash != null ? '$url&c=${Uri.encodeComponent(thumbhash)}' : url;
}

String getPlaybackUrlForRemoteId(final String id) {
  return '${Store.get(StoreKey.serverEndpoint)}/assets/$id/video/playback?';
}

String getFaceThumbnailUrl(final String personId, {DateTime? updatedAt}) {
  final url = '${Store.get(StoreKey.serverEndpoint)}/people/$personId/thumbnail';
  return updatedAt != null ? '$url?c=${updatedAt.millisecondsSinceEpoch}' : url;
}
