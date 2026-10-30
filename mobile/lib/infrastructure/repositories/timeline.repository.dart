import 'dart:async';

import 'package:drift/drift.dart';
// immich-sync fork: `QueryStreamFetcher` is what lets a watched statement be driven by a fetch we supply rather
// than by drift's own — see [_watchMainBucket]. `data/db/main/database.dart` reaches into the same library, for the
// `StreamQueryStore` it subclasses.
// ignore: implementation_imports, invalid_use_of_internal_member
import 'package:drift/src/runtime/executor/stream_queries.dart' show QueryStreamFetcher, StreamKey;
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/map.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/repositories/map.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline_bucket_cache.repository.dart';
import 'package:immich_mobile/utils/serial_runner.dart';
import 'package:stream_transform/stream_transform.dart';

@DriftAccessor()
class TimelineRepository extends DatabaseAccessor<Drift> with $TimelineRepositoryMixin {
  TimelineRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  /// immich-sync fork: one runner per distinct bucket query, so two subscriptions to the same one — which happens
  /// whenever the timeline's service is rebuilt — share a single scan instead of racing two. See [_watchMainBucket].
  final Map<String, SerialRunner<List<Bucket>>> _bucketRunners = {};

  /// immich-sync fork: see [_cachedFirst]. One per repository, which is one per database.
  late final TimelineBucketCache _bucketCache = TimelineBucketCache(_db);

  /// immich-sync fork: keys whose live query has answered this session. From then on drift hands a new listener the
  /// current list straight away, so the cache could only put an older one in front of it. See [_cachedFirst].
  final Set<String> _answeredLive = {};

  /// immich-sync fork: when the query behind each bucket list started, for the cache — a list whose query started
  /// before the cache was last cleared describes a library that is gone (`TimelineBucketCache.clear`). Attached to the
  /// list itself, because the run that produced a list is shared, and by the time the stream delivers it the next run
  /// may already have started.
  static final _startedAt = Expando<DateTime>('bucket query started');

  /// immich-sync fork: the tables `mergedBucket` in `merged_asset.drift` reads, which is what invalidates the main
  /// bucket stream. Drift derives this list for its own `watch()`, but the generated statement is behind a `.map()`
  /// that does not expose it, so [_watchMainBucket] has to name it. A test reads the query and fails when the two
  /// disagree; without it, a table upstream adds to the query would never refresh the timeline.
  @visibleForTesting
  static const mainBucketTables = {
    'remote_asset_entity',
    'stack_entity',
    'local_asset_entity',
    'local_album_asset_entity',
    'local_album_entity',
  };

  Stream<List<String>> watchTimelineUserIds(String userId) {
    final query = _db.partnerEntity.selectOnly()
      ..addColumns([_db.partnerEntity.sharedById])
      ..where(_db.partnerEntity.inTimeline.equals(true) & _db.partnerEntity.sharedWithId.equals(userId));

    return query
        .map((row) => row.read(_db.partnerEntity.sharedById)!)
        .watch()
        // Add current user ID to the list
        .map((users) => users..add(userId));
  }

  TimelineQuery main(List<String> userIds, GroupAssetsBy groupBy) => (
    bucketSource: () => _watchMainBucket(userIds, groupBy: groupBy),
    assetSource: (offset, count) => _getMainBucketAssets(userIds, offset: offset, count: count),
    origin: TimelineOrigin.main,
  );

  Stream<List<Bucket>> _watchMainBucket(List<String> userIds, {GroupAssetsBy groupBy = GroupAssetsBy.day}) {
    if (groupBy == GroupAssetsBy.none) {
      throw UnsupportedError("GroupAssetsBy.none is not supported for watchMainBucket");
    }

    final query = _db.mergedAssetDrift.mergedBucket(userIds: userIds, groupBy: groupBy.index).map((row) {
      final date = row.bucketDate.truncateDate(groupBy);
      return TimeBucket(date: date, assetCount: row.assetCount);
    });

    // immich-sync fork: drift's own `watch()` calls the statement directly, and answers every write to a table it
    // reads by cancelling the run in flight and starting another. That cancellation cannot reach a statement SQLite
    // has already begun, so the abandoned run still performs its whole read — and on a large library this one reads
    // well over a hundred megabytes. Writes arrive far faster than that (hashing commits once per 32 photos, a first
    // sync once per 5,000-event chunk), so the query is restarted before it can ever finish, for as long as the
    // writing lasts. Supplying the fetch is what lets [SerialRunner] guarantee a run that starts also completes.
    // Everything else about the stream stays drift's.
    // One key for the runner, the drift stream and the cache, so they agree on what counts as the same query. Sorted
    // inside `keyFor`: the user list can resolve in any order, and the answer does not depend on it.
    final key = TimelineBucketCache.keyFor(userIds, groupBy);
    final runner = _bucketRunners.putIfAbsent(key, SerialRunner<List<Bucket>>.new);

    final live = _db.createStream(
      QueryStreamFetcher<List<Bucket>>(
        readsFrom: TableUpdateQuery.onAllTables(
          _db.allTables.where((table) => mainBucketTables.contains(table.actualTableName)),
        ),
        // immich-sync fork: what drift dedupes watched statements by. Supplying the fetch means supplying this
        // too, and without it the two timeline services alive at once — the tab shell builds one before the user
        // list resolves and one after — each get a stream of their own and each run the query, doubling the work
        // per generation. Drift's own keys are the statement's SQL text, so a namespaced name cannot collide with
        // one; and the only site that produces this key is this one, so the cast `registerStream` makes on a hit
        // is always to the type it was stored as.
        key: StreamKey('immich-sync:mergedBucket', [key]),
        fetchData: () => runner.run(() async {
          final startedAt = DateTime.now();
          final buckets = await query.get();
          _startedAt[buckets] = startedAt;
          return buckets;
        }),
      ),
    );

    // immich-sync fork: with no user there is nothing to count, so the query is already instant and a cache lookup
    // would be pure cost at the busiest moment of the launch.
    if (userIds.isEmpty) {
      return live;
    }

    return _cachedFirst(
      key,
      live.map((buckets) {
        _answeredLive.add(key);
        unawaited(_bucketCache.remember(key, buckets, startedAt: _startedAt[buckets]));
        return buckets;
      }),
    );
  }

  /// immich-sync fork: last launch's answer, then this launch's.
  ///
  /// The cached list is yielded before [live] is subscribed, so it can never arrive after a real result and undo it.
  /// A miss — which is every failure this cache has, see `timeline_bucket_cache.repository.dart` — leaves the stream
  /// exactly as it was: one that emits when the query finally returns.
  ///
  /// Only until the live query has answered for [key]. The grid re-subscribes whenever its layout changes (a rotation,
  /// a pinch to a different column count), and by then the cache is up to a write window behind what is on screen:
  /// drawing it first would flash an older list, and make the re-layout wait for the read.
  Stream<List<Bucket>> _cachedFirst(String key, Stream<List<Bucket>> live) async* {
    if (_answeredLive.contains(key)) {
      yield* live;
      return;
    }
    final cached = await _bucketCache.read(key);
    if (cached != null) {
      yield cached;
    }
    yield* live;
  }

  Future<List<BaseAsset>> _getMainBucketAssets(List<String> userIds, {required int offset, required int count}) {
    return _db.mergedAssetDrift
        .mergedAsset(userIds: userIds, limit: (_) => Limit(count, offset))
        .map(
          (row) => row.remoteId != null && row.ownerId != null
              ? RemoteAsset(
                  id: row.remoteId!,
                  localId: row.localId,
                  name: row.name,
                  ownerId: row.ownerId!,
                  checksum: row.checksum,
                  type: row.type,
                  createdAt: row.createdAt,
                  updatedAt: row.updatedAt,
                  uploadedAt: row.uploadedAt,
                  thumbHash: row.thumbHash,
                  width: row.width,
                  height: row.height,
                  isFavorite: row.isFavorite,
                  durationMs: row.durationMs,
                  livePhotoVideoId: row.livePhotoVideoId,
                  stackId: row.stackId,
                  isEdited: row.isEdited,
                )
              : LocalAsset(
                  id: row.localId!,
                  remoteId: row.remoteId,
                  name: row.name,
                  checksum: row.checksum,
                  type: row.type,
                  createdAt: row.createdAt,
                  updatedAt: row.updatedAt,
                  width: row.width,
                  height: row.height,
                  isFavorite: row.isFavorite,
                  durationMs: row.durationMs,
                  orientation: row.orientation,
                  playbackStyle: AssetPlaybackStyle.values[row.playbackStyle],
                  cloudId: row.iCloudId,
                  latitude: row.latitude,
                  longitude: row.longitude,
                  adjustmentTime: row.adjustmentTime,
                  isEdited: row.isEdited,
                ),
        )
        .get();
  }

  TimelineQuery localAlbum(String albumId, GroupAssetsBy groupBy) => (
    bucketSource: () => _watchLocalAlbumBucket(albumId, groupBy: groupBy),
    assetSource: (offset, count) => _getLocalAlbumBucketAssets(albumId, offset: offset, count: count),
    origin: TimelineOrigin.localAlbum,
  );

  Stream<List<Bucket>> _watchLocalAlbumBucket(String albumId, {GroupAssetsBy groupBy = GroupAssetsBy.day}) {
    if (groupBy == GroupAssetsBy.none) {
      return _db.localAlbumAssetEntity
          .count(where: (row) => row.albumId.equals(albumId))
          .map(_generateBuckets)
          .watchSingle();
    }

    final assetCountExp = _db.localAssetEntity.id.count();
    final dateExp = _db.localAssetEntity.createdAt.dateFmt(groupBy, toLocal: true);

    final query =
        _db.localAssetEntity.selectOnly().join([
            innerJoin(
              _db.localAlbumAssetEntity,
              _db.localAlbumAssetEntity.assetId.equalsExp(_db.localAssetEntity.id),
              useColumns: false,
            ),
          ])
          ..addColumns([assetCountExp, dateExp])
          ..where(_db.localAlbumAssetEntity.albumId.equals(albumId))
          ..groupBy([dateExp])
          ..orderBy([OrderingTerm.desc(dateExp)]);

    return query.map((row) {
      final timeline = row.read(dateExp)!.truncateDate(groupBy);
      final assetCount = row.read(assetCountExp)!;
      return TimeBucket(date: timeline, assetCount: assetCount);
    }).watch();
  }

  Future<List<BaseAsset>> _getLocalAlbumBucketAssets(String albumId, {required int offset, required int count}) {
    final query =
        _db.localAssetEntity.select().join([
            innerJoin(
              _db.localAlbumAssetEntity,
              _db.localAlbumAssetEntity.assetId.equalsExp(_db.localAssetEntity.id),
              useColumns: false,
            ),
            leftOuterJoin(
              _db.remoteAssetEntity,
              _db.localAssetEntity.checksum.equalsExp(_db.remoteAssetEntity.checksum) &
                  _db.remoteAssetEntity.ownerId.isInQuery(
                    _db.selectOnly(_db.authUserEntity)
                      ..addColumns([_db.authUserEntity.id])
                      ..limit(1),
                  ),
              useColumns: false,
            ),
          ])
          ..addColumns([_db.remoteAssetEntity.id])
          ..where(_db.localAlbumAssetEntity.albumId.equals(albumId))
          ..orderBy([OrderingTerm.desc(_db.localAssetEntity.createdAt)])
          ..limit(count, offset: offset);

    return query
        .map((row) => row.readTable(_db.localAssetEntity).toDto(remoteId: row.read(_db.remoteAssetEntity.id)))
        .get();
  }

  TimelineQuery remoteAlbum(String albumId, GroupAssetsBy groupBy) => (
    bucketSource: () => _watchRemoteAlbumBucket(albumId, groupBy: groupBy),
    assetSource: (offset, count) =>
        _getRemoteAlbumBucketAssets(albumId, groupBy: groupBy, offset: offset, count: count),
    origin: TimelineOrigin.remoteAlbum,
  );

  Stream<List<Bucket>> _watchRemoteAlbumBucket(String albumId, {GroupAssetsBy groupBy = GroupAssetsBy.day}) {
    if (groupBy == GroupAssetsBy.none) {
      return _db.remoteAlbumAssetEntity
          .count(where: (row) => row.albumId.equals(albumId))
          .map(_generateBuckets)
          .watch()
          .map((results) => results.isNotEmpty ? results.first : const <Bucket>[])
          .handleError((error) => const <Bucket>[]);
    }

    return (_db.remoteAlbumEntity.select()..where((row) => row.id.equals(albumId)))
        .watch()
        .switchMap((albums) {
          if (albums.isEmpty) {
            return Stream.value(const <Bucket>[]);
          }

          final album = albums.first;
          final isAscending = album.order == AlbumAssetOrder.asc;
          final assetCountExp = _db.remoteAssetEntity.id.count();
          final dateExp = _db.remoteAssetEntity.effectiveCreatedAt(groupBy);

          final query = _db.remoteAssetEntity.selectOnly()
            ..addColumns([assetCountExp, dateExp])
            ..join([
              innerJoin(
                _db.remoteAlbumAssetEntity,
                _db.remoteAlbumAssetEntity.assetId.equalsExp(_db.remoteAssetEntity.id),
                useColumns: false,
              ),
            ])
            ..where(_db.remoteAssetEntity.deletedAt.isNull() & _db.remoteAlbumAssetEntity.albumId.equals(albumId))
            ..groupBy([dateExp]);

          if (isAscending) {
            query.orderBy([OrderingTerm.asc(dateExp)]);
          } else {
            query.orderBy([OrderingTerm.desc(dateExp)]);
          }

          return query.map((row) {
            final timeline = row.read(dateExp)!.truncateDate(groupBy);
            final assetCount = row.read(assetCountExp)!;
            return TimeBucket(date: timeline, assetCount: assetCount);
          }).watch();
        })
        // If there's an error (e.g., album was deleted), return empty buckets
        .handleError((error) => const <Bucket>[]);
  }

  Future<List<BaseAsset>> _getRemoteAlbumBucketAssets(
    String albumId, {
    required int offset,
    required int count,
    GroupAssetsBy groupBy = GroupAssetsBy.day,
  }) async {
    final albumData = await (_db.remoteAlbumEntity.select()..where((row) => row.id.equals(albumId))).getSingleOrNull();

    // If album doesn't exist (was deleted), return empty list
    if (albumData == null) {
      return const <BaseAsset>[];
    }

    final isAscending = albumData.order == AlbumAssetOrder.asc;

    // Correlated subquery picks the first matching local asset by checksum,
    // avoiding fan-out when the same photo exists in multiple device albums (#23273).
    final localId = subqueryExpression<String>(
      _db.localAssetEntity.selectOnly()
        ..addColumns([_db.localAssetEntity.id])
        ..where(_db.localAssetEntity.checksum.equalsExp(_db.remoteAssetEntity.checksum))
        ..limit(1),
    );

    final query = _db.remoteAssetEntity.select().addColumns([localId]).join([
      innerJoin(
        _db.remoteAlbumAssetEntity,
        _db.remoteAlbumAssetEntity.assetId.equalsExp(_db.remoteAssetEntity.id),
        useColumns: false,
      ),
    ])..where(_db.remoteAssetEntity.deletedAt.isNull() & _db.remoteAlbumAssetEntity.albumId.equals(albumId));

    query.orderBy(
      _assetDateOrder(groupBy, ascending: isAscending).map((order) => order(_db.remoteAssetEntity)).toList(),
    );

    query.limit(count, offset: offset);

    return query.map((row) => row.readTable(_db.remoteAssetEntity).toDto(localId: row.read(localId))).get();
  }

  TimelineQuery fromAssets(List<BaseAsset> assets, TimelineOrigin origin) => (
    bucketSource: () => Stream.value(_generateBuckets(assets.length)),
    assetSource: (offset, count) => Future.value(assets.skip(offset).take(count).toList(growable: false)),
    origin: origin,
  );

  TimelineQuery fromAssetStream(List<BaseAsset> Function() getAssets, Stream<int> assetCount, TimelineOrigin origin) =>
      (
        bucketSource: () async* {
          yield _generateBuckets(getAssets().length);
          yield* assetCount.map(_generateBuckets);
        },
        assetSource: (offset, count) {
          final assets = getAssets();
          return Future.value(assets.skip(offset).take(count).toList(growable: false));
        },
        origin: origin,
      );

  TimelineQuery fromAssetsWithBuckets(List<BaseAsset> assets, TimelineOrigin origin) {
    // Sort assets by date descending and group by day
    final sorted = List<BaseAsset>.from(assets)..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final Map<DateTime, int> bucketCounts = {};
    for (final asset in sorted) {
      final localTime = asset.createdAt.toLocal();
      final date = DateTime(localTime.year, localTime.month, localTime.day);
      bucketCounts[date] = (bucketCounts[date] ?? 0) + 1;
    }

    final buckets = bucketCounts.entries.map((e) => TimeBucket(date: e.key, assetCount: e.value)).toList();

    return (
      bucketSource: () => Stream.value(buckets),
      assetSource: (offset, count) => Future.value(sorted.skip(offset).take(count).toList(growable: false)),
      origin: origin,
    );
  }

  TimelineQuery remote(String ownerId, GroupAssetsBy groupBy) => _remoteQueryBuilder(
    filter: (row) =>
        row.deletedAt.isNull() & row.visibility.equalsValue(AssetVisibility.timeline) & row.ownerId.equals(ownerId),
    groupBy: groupBy,
    origin: TimelineOrigin.remoteAssets,
  );

  TimelineQuery recentlyAdded(String userId, GroupAssetsBy groupBy) => _remoteQueryBuilder(
    filter: (row) =>
        row.uploadedAt.isNotNull() &
        row.deletedAt.isNull() &
        row.ownerId.equals(userId) &
        (row.visibility.equalsValue(AssetVisibility.timeline) | row.visibility.equalsValue(AssetVisibility.archive)),
    origin: TimelineOrigin.recentlyAdded,
    groupBy: groupBy,
    sortBy: SortAssetsBy.uploaded,
  );

  TimelineQuery favorite(String userId, GroupAssetsBy groupBy) => _remoteQueryBuilder(
    filter: (row) =>
        row.deletedAt.isNull() &
        row.isFavorite.equals(true) &
        row.ownerId.equals(userId) &
        (row.visibility.equalsValue(AssetVisibility.timeline) | row.visibility.equalsValue(AssetVisibility.archive)),
    groupBy: groupBy,
    origin: TimelineOrigin.favorite,
  );

  TimelineQuery trash(String userId, GroupAssetsBy groupBy) => _remoteQueryBuilder(
    filter: (row) => row.deletedAt.isNotNull() & row.ownerId.equals(userId),
    groupBy: groupBy,
    origin: TimelineOrigin.trash,
    joinLocal: true,
  );

  TimelineQuery archived(String userId, GroupAssetsBy groupBy) => _remoteQueryBuilder(
    filter: (row) =>
        row.deletedAt.isNull() & row.ownerId.equals(userId) & row.visibility.equalsValue(AssetVisibility.archive),
    groupBy: groupBy,
    origin: TimelineOrigin.archive,
    joinLocal: true,
  );

  TimelineQuery locked(String userId, GroupAssetsBy groupBy) => _remoteQueryBuilder(
    filter: (row) =>
        row.deletedAt.isNull() & row.visibility.equalsValue(AssetVisibility.locked) & row.ownerId.equals(userId),
    origin: TimelineOrigin.lockedFolder,
    groupBy: groupBy,
  );

  TimelineQuery video(String userId, GroupAssetsBy groupBy) => _remoteQueryBuilder(
    filter: (row) =>
        row.deletedAt.isNull() &
        row.type.equalsValue(AssetType.video) &
        row.visibility.equalsValue(AssetVisibility.timeline) &
        row.ownerId.equals(userId),
    origin: TimelineOrigin.video,
    groupBy: groupBy,
  );

  TimelineQuery place(String place, GroupAssetsBy groupBy) => (
    bucketSource: () => _watchPlaceBucket(place, groupBy: groupBy),
    assetSource: (offset, count) => _getPlaceBucketAssets(place, groupBy: groupBy, offset: offset, count: count),
    origin: TimelineOrigin.place,
  );

  TimelineQuery person(List<String> userIds, String personId, GroupAssetsBy groupBy) => (
    bucketSource: () => _watchPersonBucket(userIds, personId, groupBy: groupBy),
    assetSource: (offset, count) =>
        _getPersonBucketAssets(userIds, personId, groupBy: groupBy, offset: offset, count: count),
    origin: TimelineOrigin.person,
  );

  Stream<List<Bucket>> _watchPlaceBucket(String place, {GroupAssetsBy groupBy = GroupAssetsBy.day}) {
    if (groupBy == GroupAssetsBy.none) {
      // TODO: implement GroupAssetBy for place
      throw UnsupportedError("GroupAssetsBy.none is not supported for watchPlaceBucket");
    }

    final assetCountExp = _db.remoteAssetEntity.id.count();
    final dateExp = _db.remoteAssetEntity.effectiveCreatedAt(groupBy);

    final query = _db.remoteAssetEntity.selectOnly()
      ..addColumns([assetCountExp, dateExp])
      ..join([
        innerJoin(
          _db.remoteExifEntity,
          _db.remoteExifEntity.assetId.equalsExp(_db.remoteAssetEntity.id),
          useColumns: false,
        ),
      ])
      ..where(
        _db.remoteExifEntity.city.equals(place) &
            _db.remoteAssetEntity.deletedAt.isNull() &
            _db.remoteAssetEntity.visibility.equalsValue(AssetVisibility.timeline),
      )
      ..groupBy([dateExp])
      ..orderBy([OrderingTerm.desc(dateExp)]);

    return query.map((row) {
      final timeline = row.read(dateExp)!.truncateDate(groupBy);
      final assetCount = row.read(assetCountExp)!;
      return TimeBucket(date: timeline, assetCount: assetCount);
    }).watch();
  }

  Future<List<BaseAsset>> _getPlaceBucketAssets(
    String place, {
    required int offset,
    required int count,
    GroupAssetsBy groupBy = GroupAssetsBy.day,
  }) {
    final query =
        _db.remoteAssetEntity.select().join([
            innerJoin(
              _db.remoteExifEntity,
              _db.remoteExifEntity.assetId.equalsExp(_db.remoteAssetEntity.id),
              useColumns: false,
            ),
          ])
          ..where(
            _db.remoteAssetEntity.deletedAt.isNull() &
                _db.remoteAssetEntity.visibility.equalsValue(AssetVisibility.timeline) &
                _db.remoteExifEntity.city.equals(place),
          )
          ..orderBy(_assetDateOrder(groupBy).map((order) => order(_db.remoteAssetEntity)).toList())
          ..limit(count, offset: offset);
    return query.map((row) => row.readTable(_db.remoteAssetEntity).toDto()).get();
  }

  Expression<bool> _personAssetFilter(List<String> userIds, String personId) {
    final faceAssetIds = _db.assetFaceEntity.selectOnly()
      ..addColumns([_db.assetFaceEntity.assetId])
      ..where(
        _db.assetFaceEntity.personId.equals(personId) &
            _db.assetFaceEntity.isVisible.equals(true) &
            _db.assetFaceEntity.deletedAt.isNull(),
      );
    final albumAssetIds = _db.remoteAlbumAssetEntity.selectOnly()..addColumns([_db.remoteAlbumAssetEntity.assetId]);
    return _db.remoteAssetEntity.id.isInQuery(faceAssetIds) &
        (_db.remoteAssetEntity.ownerId.isIn(userIds) | _db.remoteAssetEntity.id.isInQuery(albumAssetIds)) &
        _db.remoteAssetEntity.deletedAt.isNull() &
        _db.remoteAssetEntity.visibility.equalsValue(AssetVisibility.timeline);
  }

  Stream<List<Bucket>> _watchPersonBucket(
    List<String> userIds,
    String personId, {
    GroupAssetsBy groupBy = GroupAssetsBy.day,
  }) {
    if (groupBy == GroupAssetsBy.none) {
      final query = _db.remoteAssetEntity.selectOnly()
        ..addColumns([_db.remoteAssetEntity.id.count()])
        ..where(_personAssetFilter(userIds, personId));

      return query.map((row) {
        final count = row.read(_db.remoteAssetEntity.id.count())!;
        return _generateBuckets(count);
      }).watchSingle();
    }

    final assetCountExp = _db.remoteAssetEntity.id.count();
    final dateExp = _db.remoteAssetEntity.effectiveCreatedAt(groupBy);

    final query = _db.remoteAssetEntity.selectOnly()
      ..addColumns([assetCountExp, dateExp])
      ..where(_personAssetFilter(userIds, personId))
      ..groupBy([dateExp])
      ..orderBy([OrderingTerm.desc(dateExp)]);

    return query.map((row) {
      final timeline = row.read(dateExp)!.truncateDate(groupBy);
      final assetCount = row.read(assetCountExp)!;
      return TimeBucket(date: timeline, assetCount: assetCount);
    }).watch();
  }

  Future<List<BaseAsset>> _getPersonBucketAssets(
    List<String> userIds,
    String personId, {
    required int offset,
    required int count,
    GroupAssetsBy groupBy = GroupAssetsBy.day,
  }) {
    final query = _db.remoteAssetEntity.select()
      ..where((_) => _personAssetFilter(userIds, personId))
      ..orderBy(_assetDateOrder(groupBy))
      ..limit(count, offset: offset);

    return query.map((row) => row.toDto()).get();
  }

  /// Creates a geographic map query that can dynamically filter on changing [TimelineMapOptions]
  /// (most notably the active map bounds)
  TimelineQuery geographicMap(
    List<String> userIds,
    TimelineMapOptions Function() currentOptions,
    Stream<TimelineMapOptions> optionsStream,
    GroupAssetsBy groupBy,
  ) => (
    bucketSource: () => Stream.value(currentOptions())
        .followedBy(optionsStream)
        .switchMap(
          // Any error would kill the stream for all options; make sure the stream stays alive
          (options) => _watchMapBucket(userIds, options, groupBy: groupBy).handleError((_) {}),
        ),
    assetSource: (offset, count) => _getMapBucketAssets(userIds, currentOptions(), offset: offset, count: count),
    origin: TimelineOrigin.map,
  );

  Stream<List<Bucket>> _watchMapBucket(
    List<String> userId,
    TimelineMapOptions options, {
    GroupAssetsBy groupBy = GroupAssetsBy.day,
  }) {
    if (groupBy == GroupAssetsBy.none) {
      // TODO: Support GroupAssetsBy.none
      throw UnsupportedError("GroupAssetsBy.none is not supported for _watchMapBucket");
    }

    final assetCountExp = _db.remoteAssetEntity.id.count();
    final dateExp = _db.remoteAssetEntity.effectiveCreatedAt(groupBy);

    final query = _db.remoteAssetEntity.selectOnly()
      ..addColumns([assetCountExp, dateExp])
      ..join([
        innerJoin(
          _db.remoteExifEntity,
          _db.remoteExifEntity.assetId.equalsExp(_db.remoteAssetEntity.id),
          useColumns: false,
        ),
      ])
      ..where(
        _db.remoteAssetEntity.ownerId.isIn(userId) &
            _db.remoteExifEntity.inBounds(options.bounds) &
            _db.remoteAssetEntity.visibility.isIn([
              AssetVisibility.timeline.index,
              if (options.includeArchived) AssetVisibility.archive.index,
            ]) &
            _db.remoteAssetEntity.deletedAt.isNull(),
      )
      ..groupBy([dateExp])
      ..orderBy([OrderingTerm.desc(dateExp)]);

    if (options.onlyFavorites) {
      query.where(_db.remoteAssetEntity.isFavorite.equals(true));
    }

    final timeRange = options.timeRange;

    final hasCustomRange = timeRange.from != null || timeRange.to != null;

    if (hasCustomRange) {
      if (timeRange.from != null) {
        query.where(_db.remoteAssetEntity.createdAt.isBiggerOrEqualValue(timeRange.from!));
      }

      if (timeRange.to != null) {
        query.where(_db.remoteAssetEntity.createdAt.isSmallerOrEqualValue(timeRange.to!));
      }
    } else if (options.relativeDays > 0) {
      final cutoffDate = DateTime.now().toUtc().subtract(Duration(days: options.relativeDays));

      query.where(_db.remoteAssetEntity.createdAt.isBiggerOrEqualValue(cutoffDate));
    }

    return query.map((row) {
      final timeline = row.read(dateExp)!.truncateDate(groupBy);
      final assetCount = row.read(assetCountExp)!;
      return TimeBucket(date: timeline, assetCount: assetCount);
    }).watch();
  }

  Future<List<BaseAsset>> _getMapBucketAssets(
    List<String> userId,
    TimelineMapOptions options, {
    required int offset,
    required int count,
  }) {
    final query =
        _db.remoteAssetEntity.select().join([
            innerJoin(
              _db.remoteExifEntity,
              _db.remoteExifEntity.assetId.equalsExp(_db.remoteAssetEntity.id),
              useColumns: false,
            ),
          ])
          ..where(
            _db.remoteAssetEntity.ownerId.isIn(userId) &
                _db.remoteExifEntity.inBounds(options.bounds) &
                _db.remoteAssetEntity.visibility.isIn([
                  AssetVisibility.timeline.index,
                  if (options.includeArchived) AssetVisibility.archive.index,
                ]) &
                _db.remoteAssetEntity.deletedAt.isNull(),
          )
          ..orderBy([OrderingTerm.desc(_db.remoteAssetEntity.createdAt)])
          ..limit(count, offset: offset);

    if (options.onlyFavorites) {
      query.where(_db.remoteAssetEntity.isFavorite.equals(true));
    }

    final timeRange = options.timeRange;

    final hasCustomRange = timeRange.from != null || timeRange.to != null;

    if (hasCustomRange) {
      if (timeRange.from != null) {
        query.where(_db.remoteAssetEntity.createdAt.isBiggerOrEqualValue(timeRange.from!));
      }

      if (timeRange.to != null) {
        query.where(_db.remoteAssetEntity.createdAt.isSmallerOrEqualValue(timeRange.to!));
      }
    } else if (options.relativeDays > 0) {
      final cutoffDate = DateTime.now().toUtc().subtract(Duration(days: options.relativeDays));

      query.where(_db.remoteAssetEntity.createdAt.isBiggerOrEqualValue(cutoffDate));
    }

    return query.map((row) => row.readTable(_db.remoteAssetEntity).toDto()).get();
  }

  @pragma('vm:prefer-inline')
  TimelineQuery _remoteQueryBuilder({
    required Expression<bool> Function($RemoteAssetEntityTable row) filter,
    required TimelineOrigin origin,
    GroupAssetsBy groupBy = GroupAssetsBy.day,
    bool joinLocal = false,
    SortAssetsBy sortBy = SortAssetsBy.taken,
  }) {
    return (
      bucketSource: () => _watchRemoteBucket(filter: filter, groupBy: groupBy, sortBy: sortBy),
      assetSource: (offset, count) =>
          _getRemoteAssets(filter: filter, offset: offset, count: count, joinLocal: joinLocal, sortBy: sortBy),
      origin: origin,
    );
  }

  Stream<List<Bucket>> _watchRemoteBucket({
    required Expression<bool> Function($RemoteAssetEntityTable row) filter,
    GroupAssetsBy groupBy = GroupAssetsBy.day,
    SortAssetsBy sortBy = SortAssetsBy.taken,
  }) {
    if (groupBy == GroupAssetsBy.none) {
      final query = _db.remoteAssetEntity.count(where: filter);
      return query.map(_generateBuckets).watchSingle();
    }

    final assetCountExp = _db.remoteAssetEntity.id.count();
    final dateExp = _db.remoteAssetEntity.effectiveCreatedAt(groupBy, sortBy: sortBy);

    final query = _db.remoteAssetEntity.selectOnly()
      ..addColumns([assetCountExp, dateExp])
      ..where(filter(_db.remoteAssetEntity))
      ..groupBy([dateExp])
      ..orderBy([OrderingTerm.desc(dateExp)]);

    return query.map((row) {
      final timeline = row.read(dateExp)!.truncateDate(groupBy);
      final assetCount = row.read(assetCountExp)!;
      return TimeBucket(date: timeline, assetCount: assetCount);
    }).watch();
  }

  @pragma('vm:prefer-inline')
  Future<List<BaseAsset>> _getRemoteAssets({
    required Expression<bool> Function($RemoteAssetEntityTable row) filter,
    required int offset,
    required int count,
    bool joinLocal = false,
    SortAssetsBy sortBy = SortAssetsBy.taken,
  }) {
    if (joinLocal) {
      final query =
          _db.remoteAssetEntity.select().join([
              leftOuterJoin(
                _db.localAssetEntity,
                _db.remoteAssetEntity.checksum.equalsExp(_db.localAssetEntity.checksum),
                useColumns: false,
              ),
            ])
            ..addColumns([_db.localAssetEntity.id])
            ..where(filter(_db.remoteAssetEntity))
            ..orderBy([
              OrderingTerm.desc(
                sortBy == SortAssetsBy.uploaded ? _db.remoteAssetEntity.uploadedAt : _db.remoteAssetEntity.createdAt,
              ),
            ])
            ..limit(count, offset: offset);

      return query
          .map((row) => row.readTable(_db.remoteAssetEntity).toDto(localId: row.read(_db.localAssetEntity.id)))
          .get();
    } else {
      final query = _db.remoteAssetEntity.select()
        ..where(filter)
        ..orderBy([(row) => OrderingTerm.desc(sortBy == SortAssetsBy.uploaded ? row.uploadedAt : row.createdAt)])
        ..limit(count, offset: offset);

      return query.map((row) => row.toDto()).get();
    }
  }
}

List<Bucket> _generateBuckets(int count) => count == 0 ? const [] : [Bucket(assetCount: count)];

List<OrderingTerm Function($RemoteAssetEntityTable)> _assetDateOrder(GroupAssetsBy groupBy, {bool ascending = false}) {
  OrderingTerm order(Expression<Object> exp) => ascending ? OrderingTerm.asc(exp) : OrderingTerm.desc(exp);
  return [
    if (groupBy != GroupAssetsBy.none) (row) => order(row.effectiveCreatedAt(groupBy)),
    (row) => order(row.createdAt),
  ];
}

extension on Expression<DateTime> {
  Expression<String> dateFmt(GroupAssetsBy groupBy, {bool toLocal = false}) {
    // DateTimes are stored in UTC, so we need to convert them to local time inside the query before formatting
    // to create the correct time bucket when toLocal is true
    // toLocal is false for remote assets where localDateTime is already in the correct timezone
    final localTimeExp = toLocal ? modify(const DateTimeModifier.localTime()) : this;
    return switch (groupBy) {
      GroupAssetsBy.day || GroupAssetsBy.auto => localTimeExp.date,
      GroupAssetsBy.month => localTimeExp.strftime("%Y-%m"),
      GroupAssetsBy.none => throw ArgumentError("GroupAssetsBy.none is not supported for date formatting"),
    };
  }
}

extension on $RemoteAssetEntityTable {
  Expression<String> effectiveCreatedAt(GroupAssetsBy groupBy, {SortAssetsBy sortBy = SortAssetsBy.taken}) {
    if (sortBy == SortAssetsBy.uploaded) {
      return uploadedAt.dateFmt(groupBy, toLocal: true);
    }

    return coalesce([localDateTime.dateFmt(groupBy), createdAt.dateFmt(groupBy, toLocal: true)]);
  }
}

extension on String {
  DateTime truncateDate(GroupAssetsBy groupBy) {
    final format = switch (groupBy) {
      GroupAssetsBy.day || GroupAssetsBy.auto => "y-M-d",
      GroupAssetsBy.month => "y-M",
      GroupAssetsBy.none => throw ArgumentError("GroupAssetsBy.none is not supported for date formatting"),
    };
    return DateFormat(format, 'en').parse(this);
  }
}
