/// immich-sync fork — the app is renamed in translated strings, the server it talks to is not.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/utils/brand_translation_loader.dart';

class _FixedLoader extends AssetLoader {
  const _FixedLoader(this._translations);

  final Map<String, dynamic> _translations;

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async => _translations;
}

void main() {
  Future<Map<String, dynamic>?> load(Map<String, dynamic> translations) =>
      BrandTranslationLoader(_FixedLoader(translations)).load('', const Locale('en'));

  test('renames the app, at any depth', () async {
    final result = await load({
      'notification_enabled_list_tile_content': 'Immich uses notifications',
      'nested': {'inner': 'Open photos in Immich'},
      'count': 3,
    });
    expect(result, {
      'notification_enabled_list_tile_content': 'Mirrich uses notifications',
      'nested': {'inner': 'Open photos in Mirrich'},
      'count': 3,
    });
  });

  test('leaves the server its name', () async {
    final result = await load({'delete_dialog_alert_local': 'still be available on the Immich server'});
    expect(result, {'delete_dialog_alert_local': 'still be available on the Immich server'});
  });

  test('every server-naming key still exists upstream and still names Immich', () {
    // A rebase that renames or rewords one of these leaves an entry that protects nothing.
    final english = jsonDecode(File('../i18n/en.json').readAsStringSync()) as Map<String, dynamic>;
    for (final key in kServerNamingKeys) {
      Object? value = english;
      for (final part in key.split('.')) {
        value = (value as Map<String, dynamic>?)?[part];
      }
      expect(value, isA<String>().having((text) => text.contains('Immich'), 'names Immich', isTrue), reason: key);
    }
  });
}
