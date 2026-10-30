/// immich-sync fork: replaces the app's name in every translated string. Strings that name the server keep "Immich" and
/// are listed by key in [kServerNamingKeys].
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/constants/constants.dart';

/// Keys whose "Immich" is the server, not the app. Dotted for nested keys.
@visibleForTesting
const kServerNamingKeys = {
  'delete_dialog_alert',
  'delete_dialog_alert_local',
  'delete_dialog_alert_local_ios',
  'delete_dialog_alert_local_non_backed_up',
  'empty_trash_confirmation',
  'ocr_body',
  'sync_upload_album_setting_subtitle',
  'upload_to_immich',
};

class BrandTranslationLoader extends AssetLoader {
  const BrandTranslationLoader(this._loader);

  final AssetLoader _loader;

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final translations = await _loader.load(path, locale);
    return translations == null ? null : _rename(translations, '');
  }

  /// Depth-first, because the catalogue nests.
  Map<String, dynamic> _rename(Map<String, dynamic> node, String prefix) => {
    for (final entry in node.entries)
      entry.key: switch (entry.value) {
        final String text when kServerNamingKeys.contains('$prefix${entry.key}') => text,
        final String text => text.replaceAll(kUpstreamName, kAppName),
        final Map<String, dynamic> nested => _rename(nested, '$prefix${entry.key}.'),
        final other => other,
      },
  };
}
