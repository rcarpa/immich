import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:openapi/api.dart';

/// immich-sync fork: [thumbhash] is a cache buster, since `edited=true` returns the edit once there is one. Only
/// `offlineOriginalUrl` passes it.
String getOriginalUrlForRemoteId(final String id, {bool edited = true, String? thumbhash}) {
  final url = '${Store.get(StoreKey.serverEndpoint)}/assets/$id/original?edited=$edited';
  return thumbhash != null ? '$url&c=${Uri.encodeComponent(thumbhash)}' : url;
}

String getThumbnailUrlForRemoteId(
  final String id, {
  AssetMediaSize type = AssetMediaSize.thumbnail,
  bool edited = true,
  String? thumbhash,
  // immich-sync fork: for working out a stored file's name, which leaves the address out, without a server.
  String? endpoint,
}) {
  final url = '${endpoint ?? Store.get(StoreKey.serverEndpoint)}/assets/$id/thumbnail?size=$type&edited=$edited';
  return thumbhash != null ? '$url&c=${Uri.encodeComponent(thumbhash)}' : url;
}

String getPlaybackUrlForRemoteId(final String id) {
  return '${Store.get(StoreKey.serverEndpoint)}/assets/$id/video/playback?';
}

String getFaceThumbnailUrl(final String personId, {DateTime? updatedAt}) {
  final url = '${Store.get(StoreKey.serverEndpoint)}/people/$personId/thumbnail';
  return updatedAt != null ? '$url?c=${updatedAt.millisecondsSinceEpoch}' : url;
}
