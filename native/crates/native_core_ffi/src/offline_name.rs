//! immich-sync fork: the offline mirror's file naming, for Dart (C ABI), Swift (C ABI) and Kotlin (JNI).

use std::ffi::{CStr, CString, c_char};
use std::ptr;

#[cfg(target_os = "android")]
use jni::{
    EnvUnowned,
    errors::ThrowRuntimeExAndDefault,
    objects::{JClass, JString},
    sys::{jint, jlong, jstring},
};
use native_core::offline_name;

use super::guard;

/// The offline store's file name for `url`, or null when it has none (a malformed escape). Free it with
/// `native_core_free_string`.
///
/// # Safety
/// `url` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_offline_name(url: *const c_char) -> *mut c_char {
    guard(ptr::null_mut(), || {
        // SAFETY: the caller passes null or a valid C string.
        let Some(url) = (unsafe { text(url) }) else {
            return ptr::null_mut();
        };
        offline_name::file_name(url)
            .and_then(|name| CString::new(name).ok())
            .map_or(ptr::null_mut(), CString::into_raw)
    })
}

/// The bucket directory a stored name goes in, 0 to 255, or -1 for an invalid name.
///
/// # Safety
/// `name` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_offline_bucket(name: *const c_char) -> i32 {
    guard(-1, || {
        // SAFETY: the caller passes null or a valid C string.
        unsafe { text(name) }.map_or(-1, |name| i32::from(offline_name::bucket(name)))
    })
}

/// The version token a stored name ends in, or -1 when it has none.
///
/// # Safety
/// `name` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_offline_token(name: *const c_char) -> i64 {
    guard(-1, || {
        // SAFETY: the caller passes null or a valid C string.
        unsafe { text(name) }
            .and_then(offline_name::token)
            .map_or(-1, i64::from)
    })
}

/// The token of a stored video, from its whole name, or -1 for an invalid name.
///
/// # Safety
/// `name` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_offline_video_token(name: *const c_char) -> i64 {
    guard(-1, || {
        // SAFETY: the caller passes null or a valid C string.
        unsafe { text(name) }.map_or(-1, |name| i64::from(offline_name::video_token(name)))
    })
}

/// The 64-bit hash of a stored name, or 0 for an invalid name.
///
/// # Safety
/// `name` must be null or a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn native_core_offline_name_hash(name: *const c_char) -> u64 {
    guard(0, || {
        // SAFETY: the caller passes null or a valid C string.
        unsafe { text(name) }.map_or(0, offline_name::name_hash)
    })
}

/// # Safety
/// `value` must be null or a valid NUL-terminated string that outlives the result.
unsafe fn text<'a>(value: *const c_char) -> Option<&'a str> {
    if value.is_null() {
        return None;
    }
    // SAFETY: the caller guarantees a valid C string.
    unsafe { CStr::from_ptr(value) }.to_str().ok()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_alextran_immich_images_OfflineNaming_fileName<'caller>(
    mut env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    url: JString<'caller>,
) -> jstring {
    env.with_env(|env| -> jni::errors::Result<jstring> {
        let url = url.try_to_string(env)?;
        match offline_name::file_name(&url) {
            Some(name) => Ok(env.new_string(name)?.into_raw()),
            None => Ok(ptr::null_mut()),
        }
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_alextran_immich_images_OfflineNaming_bucket<'caller>(
    mut env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    name: JString<'caller>,
) -> jint {
    env.with_env(|env| -> jni::errors::Result<jint> {
        Ok(jint::from(offline_name::bucket(&name.try_to_string(env)?)))
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(target_os = "android")]
#[unsafe(no_mangle)]
pub extern "system" fn Java_app_alextran_immich_images_OfflineNaming_nameHash<'caller>(
    mut env: EnvUnowned<'caller>,
    _class: JClass<'caller>,
    name: JString<'caller>,
) -> jlong {
    env.with_env(|env| -> jni::errors::Result<jlong> {
        // The same bits as a signed long, which is what Kotlin keeps.
        Ok(offline_name::name_hash(&name.try_to_string(env)?) as jlong)
    })
    .resolve::<ThrowRuntimeExAndDefault>()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_through_the_c_abi() {
        let url = CString::new("https://e.com/api/assets/x/thumbnail?size=preview").unwrap();
        // SAFETY: a valid C string.
        let name = unsafe { native_core_offline_name(url.as_ptr()) };
        assert!(!name.is_null());
        // SAFETY: a C string from this library.
        let text = unsafe { CStr::from_ptr(name) }.to_str().unwrap().to_owned();
        // SAFETY: freed once.
        unsafe { crate::native_core_free_string(name) };
        assert_eq!(text, "assets_x_thumbnail_preview_811c9dc5");

        let name = CString::new(text).unwrap();
        // SAFETY: valid C strings.
        unsafe {
            assert_eq!(
                native_core_offline_bucket(name.as_ptr()),
                i32::from(offline_name::bucket("assets_x_thumbnail_preview_811c9dc5"))
            );
            assert_eq!(native_core_offline_token(name.as_ptr()), 0x811c_9dc5);
            assert_eq!(
                native_core_offline_video_token(name.as_ptr()),
                i64::from(offline_name::video_token(
                    "assets_x_thumbnail_preview_811c9dc5"
                ))
            );
            assert_eq!(
                native_core_offline_name_hash(name.as_ptr()),
                offline_name::name_hash("assets_x_thumbnail_preview_811c9dc5")
            );
        }
    }

    #[test]
    fn null_and_malformed_give_nothing() {
        let bad = CString::new("https://e.com/api/assets/%ZZ/thumbnail").unwrap();
        // SAFETY: null and a valid C string are both allowed.
        unsafe {
            assert!(native_core_offline_name(ptr::null()).is_null());
            assert!(native_core_offline_name(bad.as_ptr()).is_null());
            assert_eq!(native_core_offline_bucket(ptr::null()), -1);
            assert_eq!(native_core_offline_token(ptr::null()), -1);
            assert_eq!(native_core_offline_video_token(ptr::null()), -1);
            assert_eq!(native_core_offline_name_hash(ptr::null()), 0);
        }
    }
}
