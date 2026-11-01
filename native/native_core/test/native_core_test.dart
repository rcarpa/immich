import 'package:flutter_test/flutter_test.dart';
import 'package:native_core/native_core.dart';

void main() {
  test('loads the core and returns its version', () {
    expect(version(), isNotEmpty);
  });

  // immich-sync fork: the naming itself is tested in Rust (`offline_name.rs`); this checks the binding.
  test('names an offline file through the core', () {
    const name = 'assets_x_thumbnail_preview_811c9dc5';
    expect(offlineFileName('https://e.com/api/assets/x/thumbnail?size=preview'), name);
    expect(offlineFileName('https://e.com/api/assets/%ZZ/thumbnail'), isNull);
    expect(offlineBucket(name), inInclusiveRange(0, 255));
    expect(offlineToken(name), 0x811c9dc5);
    expect(offlineToken('people'), isNull);
  });
}
