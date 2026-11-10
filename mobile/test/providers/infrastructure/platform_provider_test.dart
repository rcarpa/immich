// immich-sync fork: passkeys are tied to apps Immich signs, so this build never offers them.
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';

void main() {
  test('the platform reports no passkeys, so none are offered', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(await container.read(passkeyHostApiProvider).isSupported(), isFalse);
  });
}
