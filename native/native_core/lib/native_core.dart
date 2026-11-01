import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'src/bindings.g.dart';

String version() {
  final ptr = native_core_version();
  try {
    return ptr.cast<Utf8>().toDartString();
  } finally {
    native_core_free_string(ptr);
  }
}

// immich-sync fork: the offline mirror's file naming, shared with the native image paths through this core.

/// The offline store's file name for [url], or null for a URL with a malformed escape.
String? offlineFileName(String url) => _withText(url, (text) {
  final name = native_core_offline_name(text);
  if (name == nullptr) {
    return null;
  }
  try {
    return name.cast<Utf8>().toDartString();
  } finally {
    native_core_free_string(name);
  }
});

/// The bucket directory, 0 to 255, a stored [name] goes in.
int offlineBucket(String name) => _withText(name, native_core_offline_bucket);

/// The version token a stored [name] ends in, or null when it has none.
int? offlineToken(String name) {
  final token = _withText(name, native_core_offline_token);
  return token < 0 ? null : token;
}

/// The token of a stored video, whose name carries no version: a hash of the whole [name].
int offlineVideoToken(String name) => _withText(name, native_core_offline_video_token);

/// A 64-bit hash of a stored [name], the same bits the native image paths index files by.
int offlineNameHash(String name) => _withText(name, native_core_offline_name_hash);

T _withText<T>(String value, T Function(Pointer<Char> text) body) {
  final text = value.toNativeUtf8();
  try {
    return body(text.cast());
  } finally {
    malloc.free(text);
  }
}
