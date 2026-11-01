import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

class AuthGuard extends AutoRouteGuard {
  final ApiService _apiService;
  // immich-sync fork: how session problems are reported instead of forcing a login.
  final void Function({required bool rejected})? onSessionIssue;
  final void Function()? onSessionValid;
  final _log = Logger("AuthGuard");
  bool _validateInFlight = false;
  // immich-sync fork: no AuthService, since local data is no longer cleared here (R2).
  AuthGuard(this._apiService, {this.onSessionIssue, this.onSessionValid});

  @override
  void onNavigation(NavigationResolver resolver, StackRouter router) {
    // Synchronously check for the access token. auto_route awaits async
    // guards, so we keep this function fully sync and validate the token in
    // the background — otherwise a slow validateAccessToken() request would
    // block the route transition for as long as the OS-level HTTP timeout.
    try {
      Store.get(StoreKey.accessToken);
    } on StoreKeyNotFoundException catch (_) {
      _log.warning('No access token in the store.');
      resolver.next(false);
      unawaited(router.replaceAll([const LoginRoute()]));
      return;
    }

    resolver.next(true);
    unawaited(_validateAccessTokenInBackground());
  }

  Future<void> _validateAccessTokenInBackground() async {
    if (_validateInFlight) {
      return;
    }
    final token = Store.tryGet(StoreKey.accessToken);
    if (token == null) {
      return;
    }
    _validateInFlight = true;
    try {
      final res = await _apiService.authenticationApi.validateAccessToken();
      if (res == null || res.authStatus != true) {
        // Token may have changed during validation (user logged out + logged in
        // again); only act if it still applies to the current session.
        if (Store.tryGet(StoreKey.accessToken) != token) {
          return;
        }
        _log.fine('User token is invalid.');
        _handleInvalidSession();
        return;
      }
      onSessionValid?.call();
    } on ApiException catch (e) {
      if (e.code != HttpStatus.unauthorized) {
        // immich-sync fork: transport failures come wrapped as ApiException(400) with an inner exception.
        if (e.innerException != null) {
          onSessionIssue?.call(rejected: false);
        }
        return;
      }
      if (Store.tryGet(StoreKey.accessToken) != token) {
        return;
      }
      _log.warning("Unauthorized access token.");
      _handleInvalidSession();
    } catch (e) {
      // immich-sync fork
      _log.warning('Error validating access token from server: $e');
      onSessionIssue?.call(rejected: false);
    } finally {
      _validateInFlight = false;
    }
  }

  /// immich-sync fork (R2): report a rejected token instead of opening the login screen and clearing the synced
  /// database, which would take the offline library with it.
  void _handleInvalidSession() => onSessionIssue?.call(rejected: true);
}
