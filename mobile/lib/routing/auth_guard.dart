import 'dart:async';
import 'dart:io';

import 'package:auto_route/auto_route.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

class AuthGuard extends AutoRouteGuard {
  final ApiService _apiService;
  // immich-sync fork: unused on purpose. Upstream called
  // `_authService.clearLocalData()` from both failure paths below; this fork
  // reports the problem instead of destroying the offline library to recover from
  // it (FORK.md R2). Kept, with the constructor, so the shape a rebase brings back
  // still fits.
  // ignore: unused_field
  final AuthService _authService;
  // immich-sync fork: how an invalid session is surfaced instead of forcing a
  // login. Injected rather than read from a provider, to keep the upstream
  // shape of this class.
  final void Function({required bool rejected})? onSessionIssue;
  final void Function()? onSessionValid;
  final _log = Logger("AuthGuard");
  bool _validateInFlight = false;
  AuthGuard(this._apiService, this._authService, {this.onSessionIssue, this.onSessionValid});

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
        // immich-sync fork: the generated client wraps transport failures in
        // ApiException(400) with the original error as innerException, where a
        // genuine HTTP error response has none. That is the everyday no-signal
        // case, and it has to read as unreachable rather than expired (R4).
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
      // immich-sync fork: an unreachable server is the normal case for this
      // app, not an error worth acting on.
      _log.warning('Error validating access token from server: $e');
      onSessionIssue?.call(rejected: false);
    } finally {
      _validateInFlight = false;
    }
  }

  /// immich-sync fork, requirement R2.
  ///
  /// Upstream reacts to a rejected token by replacing the navigation stack with
  /// the login screen *and* calling [AuthService.clearLocalData], which drops
  /// every synced remote asset. Here that is the worst possible outcome: a token
  /// quietly expiring off-grid would destroy the whole offline library.
  ///
  /// So keep the token, keep the database, stay on the library, and note it on
  /// the offline copies screen.
  void _handleInvalidSession() => onSessionIssue?.call(rejected: true);
}
