/// immich-sync fork — the app's own name, in every language. Fifteen of upstream's translated strings name the product
/// — "Upload to Immich", "Immich uses notifications for background backup" — and they are translated into forty-nine
/// languages.
library;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/constants/constants.dart';

class BrandTranslationLoader extends AssetLoader {
  const BrandTranslationLoader(this._loader);

  final AssetLoader _loader;

  @override
  Future<Map<String, dynamic>?> load(String path, Locale locale) async {
    final translations = await _loader.load(path, locale);
    return translations == null ? null : _rename(translations);
  }

  /// Depth-first, because the catalogue nests.
  Map<String, dynamic> _rename(Map<String, dynamic> node) => {
    for (final entry in node.entries)
      entry.key: switch (entry.value) {
        final String text => text.replaceAll(kUpstreamName, kAppName),
        final Map<String, dynamic> nested => _rename(nested),
        final other => other,
      },
  };
}
